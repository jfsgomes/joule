"use client";

import { useIsClient } from "usehooks-ts";
import { type Hex, decodeAbiParameters } from "viem";
import { useAccount, useBlockNumber } from "wagmi";
import { Panel } from "~~/components/joule/Panel";
import {
  useDeployedContractInfo,
  useScaffoldEventHistory,
  useScaffoldReadContract,
  useScaffoldWriteContract,
} from "~~/hooks/scaffold-eth";

/** Mirrors WorkEscrow.Status. */
const STATUS = ["None", "Open", "Submitted", "Disputed", "Settled", "Slashed"] as const;

const TAG_COLOR: Record<string, string> = {
  Open: "var(--jl-accent)",
  Submitted: "var(--jl-data)",
  Disputed: "var(--jl-alarm)",
  Settled: "var(--jl-data)",
  Slashed: "var(--jl-alarm)",
};

/**
 * Live view of every job, and the place demo step 4 happens.
 *
 * Statuses are read from the chain per job rather than derived from events.
 * Events tell you a job was opened; only `jobs(id)` tells you what became of
 * it, and settlement can happen in a transaction this UI never saw.
 */
export const JobsPanel = () => {
  const { data: escrow } = useDeployedContractInfo({ contractName: "WorkEscrow" });

  const { data: events, isLoading } = useScaffoldEventHistory({
    contractName: "WorkEscrow",
    eventName: "Redeemed",
    fromBlock: BigInt(escrow?.deployedOnBlock ?? 0),
    watch: true,
  });

  const jobs = (events ?? [])
    .map(event => ({
      jobId: event.args.jobId as bigint,
      redeemer: event.args.redeemer as string,
      jobSpec: event.args.jobSpec as Hex,
    }))
    .filter(job => job.jobId !== undefined)
    .sort((x, y) => Number(y.jobId - x.jobId));

  return (
    <Panel
      kind="read"
      code="LDG"
      title="Job ledger"
      note="Live from chain"
      hint="Every job and what became of it. Settled means the agent delivered and a contract checked the answer; slashed means it did not, and the holder took its collateral."
    >
      {isLoading ? (
        <p className="jl-dim" style={{ margin: "24px 0", textAlign: "center" }}>
          Reading the chain…
        </p>
      ) : jobs.length === 0 ? (
        <p className="jl-prose" style={{ margin: "24px 0", textAlign: "center" }}>
          No jobs yet. Redeem a Joule to commission one.
        </p>
      ) : (
        <div style={{ overflowX: "auto" }}>
          <table className="jl-table">
            <thead>
              <tr>
                <th>ID</th>
                <th>Job</th>
                <th>Redeemer</th>
                <th>Outcome</th>
                <th style={{ textAlign: "right" }}>Deadline</th>
              </tr>
            </thead>
            <tbody>
              {jobs.map(job => (
                <JobRow key={job.jobId.toString()} {...job} />
              ))}
            </tbody>
          </table>
        </div>
      )}
    </Panel>
  );
};

const JobRow = ({ jobId, redeemer, jobSpec }: { jobId: bigint; redeemer: string; jobSpec: Hex }) => {
  const { address } = useAccount();
  // `address` is restored on the client only, so the label below would differ
  // between the server and first client render.
  const isClient = useIsClient();
  const { data: block } = useBlockNumber({ watch: true });

  const { data: job } = useScaffoldReadContract({
    contractName: "WorkEscrow",
    functionName: "jobs",
    args: [jobId],
    watch: true,
  });

  const { writeContractAsync } = useScaffoldWriteContract({ contractName: "WorkEscrow" });

  const deliveryDeadline = job?.[1] ?? 0n;
  const status = STATUS[Number(job?.[3] ?? 0)] ?? "None";
  const blocksLeft = block && deliveryDeadline > 0n ? Number(deliveryDeadline - block) : null;
  const claimable = status === "Open" && blocksLeft !== null && blocksLeft < 0;
  const mine = isClient && address?.toLowerCase() === redeemer.toLowerCase();

  return (
    <tr>
      <td className="jl-dim">{jobId.toString().padStart(2, "0")}</td>
      <td>{describeSpec(jobSpec)}</td>
      <td className="jl-dim">
        {redeemer.slice(0, 6)}…{redeemer.slice(-4)}
        {mine ? " (you)" : ""}
      </td>
      <td>
        <span className="jl-tag" style={{ color: TAG_COLOR[status] ?? "var(--jl-dim)" }}>
          {status}
        </span>
      </td>
      <td style={{ textAlign: "right" }}>
        {status === "Open" ? (
          claimable ? (
            <button
              className="jl-btn"
              style={{ margin: 0, width: "auto", padding: "9px 16px", fontSize: 12, display: "inline-block" }}
              type="button"
              onClick={() => writeContractAsync({ functionName: "claimTimeout", args: [jobId] })}
            >
              {mine ? "Claim refund" : "Claim for redeemer"}
            </button>
          ) : (
            <span className="jl-dim" style={{ fontSize: "var(--jl-small)" }}>
              {blocksLeft ?? "…"} blocks left
            </span>
          )
        ) : (
          <span style={{ color: "var(--jl-rule-dim)" }}>—</span>
        )}
      </td>
    </tr>
  );
};

/** SumVerifier specs are abi.encode(uint256 a, uint256 b). */
function describeSpec(jobSpec: Hex): string {
  try {
    const [a, b] = decodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], jobSpec);
    return `sum(${a}, ${b})`;
  } catch {
    return "unrecognised spec";
  }
}
