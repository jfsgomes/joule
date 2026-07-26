"use client";

import { useState } from "react";
import { useIsClient } from "usehooks-ts";
import { formatUnits } from "viem";
import { useAccount } from "wagmi";
import { Panel } from "~~/components/joule/Panel";
import { useScaffoldReadContract, useScaffoldWriteContract } from "~~/hooks/scaffold-eth";

/** One tap should cover several demo buys without becoming a second chore. */
const FAUCET_AMOUNT = 100_000_000n; // 100 USDC

/**
 * Balances and the testnet faucet, on their own.
 *
 * These used to live inside the buy panel, where a bare "Mint 100 test USDC"
 * button sat under a price input and read as part of the trade. Separating
 * them makes both things legible: this is what you hold, and this is how you
 * get more of the stand-in dollar. Nothing here spends real value, but it is
 * still an ACT surface — it opens a wallet.
 */
export const WalletPanel = () => {
  const { address, isConnected } = useAccount();
  const connected = useIsClient() && isConnected;
  const [minting, setMinting] = useState(false);

  const { data: usdcBalance, refetch: refetchUsdc } = useScaffoldReadContract({
    contractName: "MockUSDC",
    functionName: "balanceOf",
    args: [address],
    watch: true,
  });

  const { data: jouleBalance } = useScaffoldReadContract({
    contractName: "JouleToken",
    functionName: "balanceOf",
    args: [address],
    watch: true,
  });

  const { writeContractAsync } = useScaffoldWriteContract({ contractName: "MockUSDC" });

  /**
   * MockUSDC is deliberately open-mint — see its contract notes. That is only
   * acceptable because it is a disposable testnet token, and it is what lets
   * the demo be re-run without queueing at a faucet.
   */
  const mint = async () => {
    if (!address) return;
    setMinting(true);
    try {
      await writeContractAsync({ functionName: "mint", args: [address, FAUCET_AMOUNT] });
      await refetchUsdc();
    } catch (error) {
      // useScaffoldWriteContract already surfaces a parsed error toast.
      console.error(error);
    } finally {
      setMinting(false);
    }
  };

  return (
    <Panel
      kind="act"
      code="WLT"
      title="Your wallet"
      note="Testnet"
      hint="What you hold. Start here — you need the stand-in dollar before you can buy anything."
    >
      <div className="jl-tiles" style={{ gridTemplateColumns: "1fr 1fr" }}>
        <div className="jl-tile">
          <div className="jl-k">USDC</div>
          <div className="jl-tile-v">{Number(formatUnits(usdcBalance ?? 0n, 6)).toFixed(2)}</div>
        </div>
        <div className="jl-tile">
          <div className="jl-k">Joules</div>
          <div className="jl-tile-v">{Number(formatUnits(jouleBalance ?? 0n, 18)).toFixed(4)}</div>
        </div>
      </div>

      <div style={{ marginTop: 18, borderTop: "1px solid var(--jl-rule-dim)", paddingTop: 16 }}>
        <p className="jl-prose" style={{ margin: 0, fontSize: 15 }}>
          This USDC is a stand-in for the real thing and can be minted freely. You need it to buy.
        </p>
        <button className="jl-btn jl-btn-ghost" type="button" onClick={mint} disabled={!connected || minting}>
          {minting ? "Minting…" : "Mint 100 test USDC"}
        </button>
      </div>
    </Panel>
  );
};
