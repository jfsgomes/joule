"use client";

import { Address } from "@scaffold-ui/components";
import { type Hex, decodeAbiParameters } from "viem";
import { useAccount, useBlockNumber } from "wagmi";
import {
  useDeployedContractInfo,
  useScaffoldEventHistory,
  useScaffoldReadContract,
  useScaffoldWriteContract,
} from "~~/hooks/scaffold-eth";

/** Mirrors WorkEscrow.Status. */
const STATUS = ["None", "Open", "Submitted", "Disputed", "Settled", "Slashed"] as const;

const BADGE: Record<string, string> = {
  Open: "badge-warning",
  Submitted: "badge-info",
  Disputed: "badge-error",
  Settled: "badge-success",
  Slashed: "badge-error",
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
    <div className="card bg-base-100 shadow-xl">
      <div className="card-body">
        <h2 className="card-title">Jobs</h2>
        <p className="text-sm opacity-70 -mt-2">
          Every redemption, and what became of it. With the demo agent running, a job settles within a block or two.
        </p>

        {isLoading ? (
          <div className="flex justify-center py-8">
            <span className="loading loading-dots loading-lg" />
          </div>
        ) : jobs.length === 0 ? (
          <p className="text-sm opacity-60 py-6 text-center m-0">No jobs yet. Redeem a Joule to commission one.</p>
        ) : (
          <div className="overflow-x-auto">
            <table className="table table-sm">
              <thead>
                <tr>
                  <th>#</th>
                  <th>Job</th>
                  <th>Redeemer</th>
                  <th>Status</th>
                  <th className="text-right">Deadline</th>
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
      </div>
    </div>
  );
};

const JobRow = ({ jobId, redeemer, jobSpec }: { jobId: bigint; redeemer: string; jobSpec: Hex }) => {
  const { address } = useAccount();
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
  const expired = blocksLeft !== null && blocksLeft < 0;
  const claimable = status === "Open" && expired;

  return (
    <tr>
      <td className="font-mono">{jobId.toString()}</td>
      <td className="font-mono text-xs">{describeSpec(jobSpec)}</td>
      <td>
        <Address address={redeemer as `0x${string}`} size="xs" onlyEnsOrAddress />
      </td>
      <td>
        <span className={`badge badge-sm ${BADGE[status] ?? "badge-ghost"}`}>{status}</span>
      </td>
      <td className="text-right">
        {status === "Open" ? (
          claimable ? (
            <button
              className="btn btn-xs btn-error"
              onClick={() => writeContractAsync({ functionName: "claimTimeout", args: [jobId] })}
            >
              Claim {address?.toLowerCase() === redeemer.toLowerCase() ? "refund" : "for redeemer"}
            </button>
          ) : (
            <span className="text-xs opacity-70">{blocksLeft ?? "…"} blocks left</span>
          )
        ) : (
          <span className="text-xs opacity-40">—</span>
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
