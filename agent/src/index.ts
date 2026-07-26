import { createPublicClient, createWalletClient, http, type Address, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";

import { loadConfig, resolveChain } from "./config.js";
import { escrowAbi, Status, statusName } from "./escrow.js";
import { sumSolver, type Solver } from "./solver.js";

const SOLVERS: readonly Solver[] = [sumSolver];

const log = (message: string) => console.log(`${new Date().toISOString()}  ${message}`);

/**
 * Joule's demo delivery agent.
 *
 * Watches `Redeemed`, computes the answer, calls `submitWork`. With SumVerifier
 * that settles the job inside the same transaction -- no acceptance window, no
 * counterparty, no delay.
 *
 * THIS PROCESS IS MEANT TO BE KILLED. Demo step 4 is stopping it, redeeming a
 * Joule, and letting the delivery window lapse so `claimTimeout` pays the
 * holder `faceValue + penalty` out of the agent's collateral. So there is no
 * auto-restart, no daemonisation, and no swallowing of fatal errors: when this
 * dies it must stay dead and say why.
 */
async function main() {
  const config = loadConfig();

  const transport = http(config.rpcUrl);
  const probe = createPublicClient({ transport });
  const chainId = await probe.getChainId();
  const chain = resolveChain(chainId);

  const account = privateKeyToAccount(config.privateKey);
  const publicClient = createPublicClient({ chain, transport });
  const walletClient = createWalletClient({ account, chain, transport });

  await preflight(publicClient, config.escrow, account.address, chainId, chain.name);

  // Jobs seen this run. The onchain status check in `deliver` is the real
  // guard; this only stops us re-simulating a job the watcher and the
  // catch-up scan both surfaced.
  const seen = new Set<string>();

  // submitWork calls are serialised. Two concurrent writeContract calls would
  // fetch the same nonce and one would be dropped -- and a dropped delivery on
  // a 10-block window is a slash, not a retry.
  let queue: Promise<void> = Promise.resolve();
  const enqueue = (task: () => Promise<void>) => {
    queue = queue.then(task).catch((error) => {
      // A job that cannot be delivered must not take the agent down with it.
      log(`  ! ${describeError(error)}`);
    });
  };

  const handle = (jobId: bigint, jobSpec: Hex, redeemer: Address, deadline: bigint) => {
    const key = jobId.toString();
    if (seen.has(key)) return;
    seen.add(key);

    log(`job ${jobId} redeemed by ${redeemer}, deadline block ${deadline}`);
    enqueue(() => deliver(publicClient, walletClient, config.escrow, jobId, jobSpec));
  };

  // Catch up before watching, so a restart mid-demo does not silently ignore a
  // job that is still inside its delivery window.
  const head = await publicClient.getBlockNumber();
  const fromBlock = head > config.lookbackBlocks ? head - config.lookbackBlocks : 0n;
  log(`scanning blocks ${fromBlock}..${head} for jobs missed while offline`);

  // Fetched in windows rather than one span: providers cap the range a single
  // eth_getLogs may cover (Alchemy's free tier allows 10 blocks), and a refusal
  // here would abort startup before the watcher is ever armed.
  let found = 0;
  for (let start = fromBlock; start <= head; start += config.logWindowBlocks) {
    const end = start + config.logWindowBlocks - 1n;
    const past = await publicClient.getContractEvents({
      address: config.escrow,
      abi: escrowAbi,
      eventName: "Redeemed",
      fromBlock: start,
      toBlock: end > head ? head : end,
    });
    for (const event of past) {
      const { jobId, jobSpec, redeemer, deliveryDeadline } = event.args;
      if (jobId === undefined || jobSpec === undefined) continue;
      found++;
      handle(jobId, jobSpec, redeemer as Address, deliveryDeadline ?? 0n);
    }
  }
  log(`caught up (${found} recent redemption${found === 1 ? "" : "s"})`);

  const unwatch = publicClient.watchContractEvent({
    address: config.escrow,
    abi: escrowAbi,
    eventName: "Redeemed",
    // Polling rather than filters: public RPCs frequently drop eth_newFilter
    // subscriptions without telling you, and a silently dead watcher looks
    // exactly like an idle agent.
    poll: true,
    pollingInterval: config.pollingIntervalMs,
    onLogs: (logs) => {
      for (const event of logs) {
        const { jobId, jobSpec, redeemer, deliveryDeadline } = event.args;
        if (jobId === undefined || jobSpec === undefined) continue;
        handle(jobId, jobSpec, redeemer as Address, deliveryDeadline ?? 0n);
      }
    },
    onError: (error) => log(`  ! watcher: ${describeError(error)}`),
  });

  log(`watching for redemptions -- ctrl-c to stop (that is demo step 4)`);

  for (const signal of ["SIGINT", "SIGTERM"] as const) {
    process.once(signal, () => {
      unwatch();
      log(`stopped on ${signal}. Open jobs will now run out their delivery window.`);
      process.exit(0);
    });
  }
}

/**
 * Refuses to start unless this key really is the escrow's agent.
 *
 * `submitWork` is `onlyAgent`, so the wrong key produces a correct-looking
 * process that logs every redemption and delivers none of them -- discovered
 * only when the first job times out. Better to fail in the first second.
 */
async function preflight(
  publicClient: ReturnType<typeof createPublicClient>,
  escrow: Address,
  signer: Address,
  chainId: number,
  chainName: string,
) {
  const code = await publicClient.getBytecode({ address: escrow });
  if (!code || code === "0x") {
    throw new Error(`No contract at ${escrow} on ${chainName} (${chainId}). Wrong RPC_URL or ESCROW_ADDRESS?`);
  }

  const onchainAgent = (await publicClient.readContract({
    address: escrow,
    abi: escrowAbi,
    functionName: "agent",
  })) as Address;

  if (onchainAgent.toLowerCase() !== signer.toLowerCase()) {
    throw new Error(
      `AGENT_PRIVATE_KEY is ${signer} but the escrow's agent is ${onchainAgent}. ` +
        `submitWork is onlyAgent, so every delivery would revert.`,
    );
  }

  const deliveryBlocks = await publicClient.readContract({
    address: escrow,
    abi: escrowAbi,
    functionName: "deliveryBlocks",
  });

  log(`escrow ${escrow} on ${chainName} (${chainId})`);
  log(`agent  ${signer}  --  delivery window ${deliveryBlocks} blocks`);
}

async function deliver(
  publicClient: ReturnType<typeof createPublicClient>,
  walletClient: ReturnType<typeof createWalletClient>,
  escrow: Address,
  jobId: bigint,
  jobSpec: Hex,
) {
  // Re-read status rather than trusting the event: the catch-up scan replays
  // history, so most of what it finds is already settled.
  const [, deliveryDeadline, , status] = (await publicClient.readContract({
    address: escrow,
    abi: escrowAbi,
    functionName: "jobs",
    args: [jobId],
  })) as [Address, bigint, bigint, number];

  if (status !== Status.Open) {
    log(`  job ${jobId} is ${statusName(status)}, nothing to do`);
    return;
  }

  const block = await publicClient.getBlockNumber();
  if (block > deliveryDeadline) {
    log(`  job ${jobId} missed its window (block ${block} > ${deliveryDeadline}) -- it can be slashed`);
    return;
  }

  const solver = SOLVERS.map((s) => ({ s, solved: s.solve(jobSpec) })).find((x) => x.solved !== null);
  if (!solver?.solved) {
    // Nothing to submit. Submitting garbage would stop the timeout clock and
    // shove the job onto the optimistic path, which is worse for everyone than
    // letting a job the agent genuinely cannot do simply lapse.
    log(`  job ${jobId}: no solver recognises this spec, leaving it open`);
    return;
  }

  log(`  job ${jobId}: ${solver.s.name} solver says ${solver.solved.describe}`);

  // Simulate first so a predictable failure reports the escrow's own custom
  // error instead of an out-of-gas guess.
  const { request } = await publicClient.simulateContract({
    account: walletClient.account,
    address: escrow,
    abi: escrowAbi,
    functionName: "submitWork",
    args: [jobId, jobSpec, solver.solved.result],
  });

  const hash = await walletClient.writeContract(request);
  log(`  job ${jobId}: submitWork sent, ${hash}`);

  const receipt = await publicClient.waitForTransactionReceipt({ hash });
  log(
    `  job ${jobId}: ${receipt.status === "success" ? "settled" : "REVERTED"} in block ${receipt.blockNumber} ` +
      `(gas ${receipt.gasUsed})`,
  );
}

function describeError(error: unknown): string {
  if (error && typeof error === "object" && "shortMessage" in error) {
    return String((error as { shortMessage: unknown }).shortMessage);
  }
  return error instanceof Error ? error.message : String(error);
}

main().catch((error) => {
  console.error(`\n${describeError(error)}\n`);
  process.exit(1);
});
