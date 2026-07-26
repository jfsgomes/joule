"use client";

import { formatUnits } from "viem";
import { useAccount } from "wagmi";
import { Panel } from "~~/components/joule/Panel";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

const usdc = (value: bigint | undefined) => Number(formatUnits(value ?? 0n, 6)).toFixed(2);

/**
 * The agent's balance sheet, which is the whole reason a Joule is worth
 * anything. Collateral is the guarantee — not the sale price, and not the
 * market price, neither of which the contracts ever read.
 */
export const CollateralPanel = () => {
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
    <Panel
      kind="read"
      code="CLR"
      title="Agent collateral"
      note={`Default pays ${usdc(faceValue)} + ${usdc(penalty)} USDC`}
      hint="Why a Joule is worth anything. Every one in circulation is backed by locked USDC, and a default pays the holder out of it."
    >
      <div className="jl-tiles" style={{ gridTemplateColumns: "repeat(auto-fit, minmax(200px, 1fr))" }}>
        <div className="jl-tile">
          <div className="jl-k">Locked</div>
          <div className="jl-tile-v">{usdc(collateral)}</div>
          <div className="jl-tile-s">USDC backing outstanding Joules</div>
        </div>
        <div className="jl-tile">
          <div className="jl-k">Outstanding</div>
          <div className="jl-tile-v">{(outstanding ?? 0n).toString()}</div>
          <div className="jl-tile-s">Joules in circulation</div>
        </div>
        <div className="jl-tile">
          <div className="jl-k">Unlocked</div>
          <div className="jl-tile-v">{usdc(free)}</div>
          <div className="jl-tile-s">Released by delivering</div>
        </div>
      </div>

      {hasPayout ? (
        <div
          style={{
            marginTop: 16,
            border: "2px solid var(--jl-alarm)",
            padding: "14px 16px",
            display: "flex",
            alignItems: "center",
            gap: 16,
            flexWrap: "wrap",
          }}
        >
          <span style={{ color: "var(--jl-alarm)", fontWeight: 700, letterSpacing: "0.12em" }}>
            AN AGENT DEFAULTED — {usdc(owed)} USDC IS YOURS
          </span>
          <button
            className="jl-btn"
            style={{ margin: 0, marginLeft: "auto", width: "auto", padding: "12px 22px" }}
            type="button"
            onClick={() => writeContractAsync({ functionName: "withdraw" })}
          >
            Withdraw
          </button>
        </div>
      ) : null}
    </Panel>
  );
};
