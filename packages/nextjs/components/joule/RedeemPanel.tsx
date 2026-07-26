"use client";

import { useState } from "react";
import { useIsClient } from "usehooks-ts";
import { encodeAbiParameters, formatUnits, maxUint256 } from "viem";
import { useAccount } from "wagmi";
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
  // See BuyPanel: branching on wagmi's connection state during SSR hydrates
  // mismatched, because the session is only restored on the client.
  const connected = useIsClient() && isConnected;
  const [a, setA] = useState("2");
  const [b, setB] = useState("2");
  const [busy, setBusy] = useState(false);

  const { data: escrow } = useDeployedContractInfo({ contractName: "WorkEscrow" });

  const { data: balance, refetch: refetchBalance } = useScaffoldReadContract({
    contractName: "JouleToken",
    functionName: "balanceOf",
    args: [address],
  });

  const { data: allowance, refetch: refetchAllowance } = useScaffoldReadContract({
    contractName: "JouleToken",
    functionName: "allowance",
    args: [address, escrow?.address],
  });

  const { writeContractAsync: writeJoule } = useScaffoldWriteContract({ contractName: "JouleToken" });
  const { writeContractAsync: writeEscrow } = useScaffoldWriteContract({ contractName: "WorkEscrow" });

  const held = balance ?? 0n;
  const approved = allowance ?? 0n;
  const hasJoule = held >= ONE_JOULE;
  const needsApproval = approved < ONE_JOULE;

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

      // Must match SumVerifier exactly: abi.encode(uint256 a, uint256 b).
      // The escrow stores only keccak256 of this and demands the same bytes
      // back at submitWork, so an encoding mismatch here is unrecoverable.
      const jobSpec = encodeAbiParameters([{ type: "uint256" }, { type: "uint256" }], [operandA, operandB]);

      await writeEscrow({ functionName: "redeem", args: [jobSpec] });

      await Promise.all([refetchBalance(), refetchAllowance()]);
      onRedeemed?.();
    } catch (error) {
      // useScaffoldWriteContract already surfaces a parsed error toast; this
      // only catches what escapes it.
      console.error(error);
    } finally {
      setBusy(false);
    }
  };

  return (
    <div className="card bg-base-100 shadow-xl">
      <div className="card-body">
        <h2 className="card-title">Redeem for work</h2>
        <p className="text-sm opacity-70 -mt-2">
          Spend one Joule to commission a job. The agent has a fixed window to deliver, or you can claim its collateral.
        </p>

        <div className="flex gap-3">
          <label className="form-control w-full">
            <div className="label">
              <span className="label-text">a</span>
            </div>
            <input
              type="number"
              className="input input-bordered w-full"
              value={a}
              onChange={e => setA(e.target.value)}
              disabled={busy}
            />
          </label>
          <label className="form-control w-full">
            <div className="label">
              <span className="label-text">b</span>
            </div>
            <input
              type="number"
              className="input input-bordered w-full"
              value={b}
              onChange={e => setB(e.target.value)}
              disabled={busy}
            />
          </label>
        </div>

        <div className="text-sm opacity-70 mt-1">
          Job:{" "}
          <span className="font-mono">
            sum({a || "?"}, {b || "?"})
          </span>{" "}
          · you hold <span className="font-mono">{Number(formatUnits(held, 18)).toFixed(4)}</span> JOULE
        </div>

        <div className="card-actions mt-2">
          <button className="btn btn-secondary w-full" onClick={redeem} disabled={!connected || busy || !hasJoule}>
            {busy ? <span className="loading loading-spinner loading-sm" /> : null}
            {!connected
              ? "Connect a wallet"
              : !hasJoule
                ? "You need a whole Joule"
                : needsApproval
                  ? "Approve and redeem"
                  : "Redeem"}
          </button>
        </div>
      </div>
    </div>
  );
};
