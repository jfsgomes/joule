import { spawnSync } from "child_process";
import { config } from "dotenv";
import { existsSync, readFileSync, readdirSync } from "fs";
import { dirname, join } from "path";
import { fileURLToPath } from "url";

const __dirname = dirname(fileURLToPath(import.meta.url));
const FOUNDRY = join(__dirname, "..");
config({ path: join(FOUNDRY, ".env") });

/**
 * Verifies this project's contracts on Etherscan.
 *
 * SE-2 ships `script/VerifyAll.s.sol`, which does not work here for two reasons:
 *
 *   1. It reads `broadcast/Deploy.s.sol/<chainId>/run-latest.json` -- a hardcoded
 *      script name. Ours is DeployWorkEscrow.s.sol, so it finds nothing and
 *      exits successfully, which is worse than failing.
 *   2. It only handles top-level CREATE transactions. JouleToken is deployed
 *      inside WorkEscrow's constructor and has no transaction of its own, so it
 *      would be skipped -- the same blind spot that kept it out of
 *      deployedContracts.ts until scripts-js/generateTsAbis.js was taught about
 *      `deployments/<chainId>.nested.json`. This reads that same manifest.
 *
 * Constructor arguments are recovered by subtracting the compiled creation
 * bytecode from the deployment transaction's input, rather than re-encoding
 * them from the broadcast's `arguments` strings. That avoids having to map
 * Solidity types back onto ABI encoders, and it is exactly the bytes the chain
 * saw.
 *
 *   yarn verify:sepolia            # or: node scripts-js/verifyContracts.js sepolia
 */

const network = process.argv[2] ?? "sepolia";
const CHAIN_IDS = { sepolia: 11155111, mainnet: 1 };
const chainId = CHAIN_IDS[network];

if (!chainId) {
  console.error(`Unknown network '${network}'. Known: ${Object.keys(CHAIN_IDS).join(", ")}`);
  process.exit(1);
}
if (!process.env.ETHERSCAN_API_KEY) {
  console.error("ETHERSCAN_API_KEY is not set in packages/foundry/.env");
  process.exit(1);
}

/** Finds the compiled artifact for a contract, wherever forge put it. */
function findArtifact(name) {
  const out = join(FOUNDRY, "out");
  for (const dir of readdirSync(out)) {
    const candidate = join(out, dir, `${name}.json`);
    if (existsSync(candidate)) return JSON.parse(readFileSync(candidate, "utf8"));
  }
  return null;
}

/** Source path as `path/to/File.sol:ContractName`, which forge wants. */
function sourcePath(artifact, name) {
  const target = artifact?.metadata?.settings?.compilationTarget ?? {};
  const file = Object.keys(target).find(f => target[f] === name);
  return file ? `${file}:${name}` : null;
}

const targets = [];

// Contracts with a deployment transaction of their own.
const broadcastDir = join(FOUNDRY, "broadcast");
for (const script of existsSync(broadcastDir) ? readdirSync(broadcastDir) : []) {
  const runFile = join(broadcastDir, script, String(chainId), "run-latest.json");
  if (!existsSync(runFile)) continue;
  const run = JSON.parse(readFileSync(runFile, "utf8"));
  for (const tx of run.transactions ?? []) {
    if (tx.transactionType !== "CREATE" && tx.transactionType !== "CREATE2") continue;
    if (!tx.contractName || !tx.contractAddress) continue;

    const artifact = findArtifact(tx.contractName);
    const creation = artifact?.bytecode?.object ?? "";
    const input = tx.transaction?.input ?? tx.transaction?.data ?? "";
    // Whatever trails the creation bytecode IS the encoded constructor args.
    const args = input.startsWith(creation) && creation.length > 2 ? "0x" + input.slice(creation.length) : "";

    targets.push({ name: tx.contractName, address: tx.contractAddress, args, artifact });
  }
}

// Contracts deployed inside another contract's constructor.
const nestedFile = join(FOUNDRY, "deployments", `${chainId}.nested.json`);
if (existsSync(nestedFile)) {
  for (const [name, address] of Object.entries(JSON.parse(readFileSync(nestedFile, "utf8")))) {
    if (targets.some(t => t.address.toLowerCase() === String(address).toLowerCase())) continue;
    targets.push({ name, address, args: "", artifact: findArtifact(name) });
  }
}

if (targets.length === 0) {
  console.error(`No deployments found for chain ${chainId}. Deploy first.`);
  process.exit(1);
}

let failed = 0;
for (const target of targets) {
  const path = sourcePath(target.artifact, target.name);
  if (!path) {
    console.error(`  ${target.name}: could not locate source path; run 'yarn compile' first`);
    failed++;
    continue;
  }

  // "0x" means the input matched the creation bytecode exactly, i.e. no args.
  const hasArgs = Boolean(target.args) && target.args !== "0x";

  const argv = ["verify-contract", target.address, path, "--chain", network, "--watch"];
  if (hasArgs) argv.push("--constructor-args", target.args);

  console.log(`\n=== ${target.name} @ ${target.address}${hasArgs ? " (with constructor args)" : ""} ===`);
  const result = spawnSync("forge", argv, { cwd: FOUNDRY, stdio: "inherit", env: process.env });
  if (result.status !== 0) failed++;
}

console.log(`\n${targets.length - failed}/${targets.length} verified.`);
process.exit(failed === 0 ? 0 : 1);
