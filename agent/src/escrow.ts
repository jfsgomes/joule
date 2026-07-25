/**
 * The slice of WorkEscrow the agent actually touches.
 *
 * Deliberately hand-written rather than imported from the compiled artifacts or
 * from `deployedContracts.ts`. Both alternatives couple the agent to a build
 * step it does not otherwise need: `packages/foundry/out/` is gitignored, so a
 * fresh clone would have to run `forge build` before the agent could start, and
 * `deployedContracts.ts` imports a Next.js path alias that does not resolve
 * outside that workspace.
 *
 * The cost is drift if the contract changes. That is paid for by the preflight
 * check in index.ts, which refuses to start unless the deployed escrow answers
 * `agent()` with our own address -- a call that would itself fail on a stale ABI.
 */
export const escrowAbi = [
  {
    type: "event",
    name: "Redeemed",
    inputs: [
      { name: "jobId", type: "uint256", indexed: true },
      { name: "redeemer", type: "address", indexed: true },
      { name: "jobSpec", type: "bytes", indexed: false },
      { name: "deliveryDeadline", type: "uint256", indexed: false },
    ],
  },
  {
    type: "function",
    name: "submitWork",
    stateMutability: "nonpayable",
    inputs: [
      { name: "jobId", type: "uint256" },
      { name: "jobSpec", type: "bytes" },
      { name: "result", type: "bytes" },
    ],
    outputs: [],
  },
  {
    type: "function",
    name: "jobs",
    stateMutability: "view",
    inputs: [{ name: "jobId", type: "uint256" }],
    outputs: [
      { name: "redeemer", type: "address" },
      { name: "deliveryDeadline", type: "uint64" },
      { name: "acceptDeadline", type: "uint64" },
      { name: "status", type: "uint8" },
    ],
  },
  {
    type: "function",
    name: "agent",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "address" }],
  },
  {
    type: "function",
    name: "deliveryBlocks",
    stateMutability: "view",
    inputs: [],
    outputs: [{ name: "", type: "uint256" }],
  },
] as const;

/** Mirrors WorkEscrow.Status. `None` is 0 because jobIds start at 1. */
export const Status = {
  None: 0,
  Open: 1,
  Submitted: 2,
  Disputed: 3,
  Settled: 4,
  Slashed: 5,
} as const;

export const statusName = (value: number): string =>
  Object.entries(Status).find(([, v]) => v === value)?.[0] ?? `unknown(${value})`;
