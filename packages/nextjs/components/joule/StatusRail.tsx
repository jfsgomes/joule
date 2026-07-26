"use client";

import { useBlockNumber } from "wagmi";
import { RainbowKitCustomConnectButton } from "~~/components/scaffold-eth";
import { useDeployedContractInfo, useTargetNetwork } from "~~/hooks/scaffold-eth";

/**
 * The rail reports what the terminal is attached to.
 *
 * Block height is here because on a 12-second chain the waiting IS part of the
 * interface — a visibly advancing number is what tells an audience the page is
 * live rather than a screenshot, and it is the same clock the delivery window
 * is measured in.
 */
export const StatusRail = () => {
  const { targetNetwork } = useTargetNetwork();
  const { data: escrow } = useDeployedContractInfo({ contractName: "WorkEscrow" });
  const { data: block } = useBlockNumber({ watch: true });

  return (
    <div
      style={{
        display: "flex",
        flexWrap: "wrap",
        gap: "10px 32px",
        alignItems: "center",
        padding: "18px 0 16px",
        borderBottom: "1px solid var(--jl-rule-dim)",
        fontSize: "var(--jl-micro)",
        letterSpacing: "0.18em",
        textTransform: "uppercase",
        color: "var(--jl-dim)",
        fontWeight: 500,
      }}
    >
      <span style={{ color: "var(--jl-accent)", letterSpacing: "0.34em", fontWeight: 700, fontSize: 14 }}>JOULE</span>
      {escrow?.address ? (
        <a
          href={`https://sepolia.etherscan.io/address/${escrow.address}#code`}
          target="_blank"
          rel="noreferrer"
          style={{ color: "inherit", textDecoration: "none", borderBottom: "1px solid var(--jl-rule-dim)" }}
        >
          Escrow {escrow.address.slice(0, 6)}…{escrow.address.slice(-5)}
        </a>
      ) : null}
      <span>
        {targetNetwork.name} · {targetNetwork.id}
      </span>
      <span className="jl-live" style={{ color: "var(--jl-data)" }}>
        Block {block?.toString() ?? "—"}
      </span>
      <div style={{ marginLeft: "auto" }}>
        <RainbowKitCustomConnectButton />
      </div>
    </div>
  );
};
