"use client";

import { formatUnits } from "viem";
import { useAccount } from "wagmi";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

const usdc = (value: bigint | undefined) => `${Number(formatUnits(value ?? 0n, 6)).toFixed(2)}`;

/**
 * The agent's balance sheet, which is the whole reason a Joule is worth
 * anything. Collateral is the guarantee -- not the sale price, and not the
 * market price, neither of which the contracts ever read.
 */
export const EscrowStats = () => {
  const { address } = useAccount();

  const { data: collateral } = useScaffoldReadContract({
    contractName: "WorkEscrow",
    functionName: "collateral",
    watch: true,
  });
  const { data: outstanding } = useScaffoldReadContract({
    contractName: "WorkEscrow",
    functionName: "outstanding",
    watch: true,
  });
  const { data: free } = useScaffoldReadContract({
    contractName: "WorkEscrow",
    functionName: "freeCollateral",
    watch: true,
  });
  const { data: faceValue } = useScaffoldReadContract({ contractName: "WorkEscrow", functionName: "faceValue" });
  const { data: penalty } = useScaffoldReadContract({ contractName: "WorkEscrow", functionName: "penalty" });
  const { data: owed } = useScaffoldReadContract({
    contractName: "WorkEscrow",
    functionName: "owed",
    args: [address],
    watch: true,
  });

  const { writeContractAsync } = useScaffoldWriteContract({ contractName: "WorkEscrow" });
  const hasPayout = (owed ?? 0n) > 0n;

  return (
    <div className="card bg-base-100 shadow-xl">
      <div className="card-body">
        <h2 className="card-title">Agent collateral</h2>
        <p className="text-sm opacity-70 -mt-2">
          Every outstanding Joule is backed by locked USDC. Default on one and the holder is paid {usdc(faceValue)} +{" "}
          {usdc(penalty)} USDC out of this.
        </p>

        <div className="stats stats-vertical sm:stats-horizontal bg-base-200 mt-2">
          <div className="stat">
            <div className="stat-title">Collateral</div>
            <div className="stat-value text-2xl">{usdc(collateral)}</div>
            <div className="stat-desc">USDC locked in escrow</div>
          </div>
          <div className="stat">
            <div className="stat-title">Outstanding</div>
            <div className="stat-value text-2xl">{(outstanding ?? 0n).toString()}</div>
            <div className="stat-desc">Joules in circulation</div>
          </div>
          <div className="stat">
            <div className="stat-title">Unlocked</div>
            <div className="stat-value text-2xl">{usdc(free)}</div>
            <div className="stat-desc">Withdrawable by the agent</div>
          </div>
        </div>

        {hasPayout ? (
          <div className="alert alert-success mt-3">
            <span>
              You are owed <span className="font-bold">{usdc(owed)} USDC</span> from a defaulted job.
            </span>
            <button className="btn btn-sm" onClick={() => writeContractAsync({ functionName: "withdraw" })}>
              Withdraw
            </button>
          </div>
        ) : null}
      </div>
    </div>
  );
};
