"use client";

import { useState } from "react";
import { useIsClient } from "usehooks-ts";
import { encodeAbiParameters, formatUnits, maxUint256 } from "viem";
import { useAccount } from "wagmi";
import { Panel } from "~~/components/joule/Panel";
import { useDeployedContractInfo, useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";
import { notification } from "~~/utils/scaffold-eth";

const ONE_JOULE = 10n ** 18n;

/**
 * Demo step 3: spend a Joule on actual work.
 *
 * `redeem` moves the Joule into escrow custody -- that transfer IS the lock, so
 * an approval is required first. The two-step is unavoidable and worth showing
 * honestly rather than hiding behind a single button that sometimes costs two
 * transactions.
 */
export const RedeemPanel = ({ onRedeemed }: { onRedeemed?: () => void }) => {
  const { address, isConnected } = useAccount();
  const connected = useIsClient() && isConnected;
  const [a, setA] = useState("2");
  const [b, setB] = useState("2");
  const [busy, setBusy] = useState(false);

  const { data: escrow } = useDeployedContractInfo({ contractName: "WorkEscrow" });

  const { data: balance, refetch: refetchBalance } = useScaffoldReadContract({
    contractName: "JouleToken",
    functionName: "balanceOf",
    args: [address],
    watch: true,
  });
  const { data: allowance, refetch: refetchAllowance } = useScaffoldReadContract({
    contractName: "JouleToken",
    functionName: "allowance",
    args: [address, escrow?.address],
  });
  const { data: faceValue } = useScaffoldReadContract({ contractName: "WorkEscrow", functionName: "faceValue" });
  const { data: penalty } = useScaffoldReadContract({ contractName: "WorkEscrow", functionName: "penalty" });
  const { data: deliveryBlocks } = useScaffoldReadContract({
    contractName: "WorkEscrow",
    functionName: "deliveryBlocks",
  });

  const { writeContractAsync: writeJoule } = useScaffoldWriteContract({ contractName: "JouleToken" });
  const { writeContractAsync: writeEscrow } = useScaffoldWriteContract({ contractName: "WorkEscrow" });

  const held = balance ?? 0n;
  const hasJoule = held >= ONE_JOULE;
  const needsApproval = (allowance ?? 0n) < ONE_JOULE;
  const refund = Number(formatUnits((faceValue ?? 0n) + (penalty ?? 0n), 6));

  const redeem = async () => {
    if (!escrow?.address) return;

    let operandA: bigint;
    let operandB: bigint;
    try {
      operandA = BigInt(a);
      operandB = BigInt(b);
    } catch {
      notification.error("Both operands must be whole numbers");
      return;
    }

    setBusy(true);
    try {
      if (needsApproval) {
        await writeJoule({ functionName: "approve", args: [escrow.address, maxUint256] });
        await refetchAllowance();
      }

      // Must match SumVerifier exactly: abi.encode(uint256 a, uint256 b). The
      // escrow stores only keccak256 of this and demands the same bytes back at
      // submitWork, so an encoding mismatch here is unrecoverable.
      const jobSpec = encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [operandA, operandB]);
      await writeEscrow({ functionName: "redeem", args: [jobSpec] });

      await Promise.all([refetchBalance(), refetchAllowance()]);
      onRedeemed?.();
    } catch (error) {
      // useScaffoldWriteContract already surfaces a parsed error toast.
      console.error(error);
    } finally {
      setBusy(false);
    }
  };

  return (
    <Panel
      kind="act"
      code="RDM"
      title="Commission work"
      note={deliveryBlocks ? `Window · ${deliveryBlocks} blocks` : undefined}
      hint="Spend one Joule to order a job. The agent must deliver inside the window or you can take its collateral instead."
    >
      <div style={{ display: "grid", gridTemplateColumns: "1fr 1fr", gap: 12 }}>
        <div>
          <label className="jl-k" htmlFor="jl-a" style={{ display: "block", marginBottom: 8 }}>
            Operand A
          </label>
          <input
            id="jl-a"
            className="jl-input"
            type="number"
            inputMode="numeric"
            value={a}
            onChange={e => setA(e.target.value)}
            disabled={busy}
          />
        </div>
        <div>
          <label className="jl-k" htmlFor="jl-b" style={{ display: "block", marginBottom: 8 }}>
            Operand B
          </label>
          <input
            id="jl-b"
            className="jl-input"
            type="number"
            inputMode="numeric"
            value={b}
            onChange={e => setB(e.target.value)}
            disabled={busy}
          />
        </div>
      </div>

      <div className="jl-quote">
        <div style={ROW}>
          <span className="jl-k">Job</span>
          <span className="jl-dim" style={{ fontSize: "var(--jl-small)" }}>
            sum({a || "?"}, {b || "?"})
          </span>
        </div>
        <div style={{ ...ROW, marginTop: 10 }}>
          <span className="jl-k">On default</span>
          <span className="jl-dim" style={{ fontSize: "var(--jl-small)" }}>
            {refund.toFixed(2)} USDC back to you
          </span>
        </div>
        <div style={{ ...ROW, marginTop: 10 }}>
          <span className="jl-k">You hold</span>
          <span className="jl-dim" style={{ fontSize: "var(--jl-small)" }}>
            {Number(formatUnits(held, 18)).toFixed(4)} Joules
          </span>
        </div>
      </div>

      <button className="jl-btn jl-btn-ice" type="button" onClick={redeem} disabled={!connected || busy || !hasJoule}>
        {!connected
          ? "Connect a wallet"
          : !hasJoule
            ? "You need a whole Joule"
            : busy
              ? "Working…"
              : needsApproval
                ? "Approve and redeem"
                : "Redeem"}
      </button>
    </Panel>
  );
};

const ROW = { display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 14 } as const;
