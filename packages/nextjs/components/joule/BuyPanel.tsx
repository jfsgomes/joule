"use client";

import { useEffect, useState } from "react";
import { useIsClient } from "usehooks-ts";
import { type Hex, formatUnits, parseUnits } from "viem";
import { useAccount, useSignTypedData } from "wagmi";
import { Panel } from "~~/components/joule/Panel";
import {
  useDeployedContractInfo,
  useScaffoldReadContract,
  useTargetNetwork,
  useTransactor,
} from "~~/hooks/scaffold-eth";
import {
  type Quote,
  TradingApiError,
  buildSwap,
  checkApproval,
  derivePrimaryType,
  getQuote,
} from "~~/utils/joule/tradingApi";
import { notification } from "~~/utils/scaffold-eth";

const USDC_DECIMALS = 6;
const JOULE_DECIMALS = 18;
const QUOTE_DEBOUNCE_MS = 400;

/**
 * Demo step 2: buy a Joule on the open market.
 *
 * THIS IS THE PRIZE INTEGRATION. Every part of the trade comes from the Uniswap
 * Trading API -- the price, the approval transaction, and the swap calldata. We
 * build none of it ourselves and we never touch the pool directly.
 *
 * That is also the safer choice, not just the required one: the API encodes for
 * the router that is actually deployed, which sidesteps the ABI drift between
 * `v4-periphery@main` and the live Universal Router documented in FEEDBACK.md.
 */
export const BuyPanel = ({ onBought }: { onBought?: () => void }) => {
  const { address, isConnected } = useAccount();
  const connected = useIsClient() && isConnected;
  const { targetNetwork } = useTargetNetwork();
  const transactor = useTransactor();
  const { signTypedDataAsync } = useSignTypedData();

  const { data: usdc } = useDeployedContractInfo({ contractName: "MockUSDC" });
  const { data: joule } = useDeployedContractInfo({ contractName: "JouleToken" });

  const { data: usdcBalance } = useScaffoldReadContract({
    contractName: "MockUSDC",
    functionName: "balanceOf",
    args: [address],
    watch: true,
  });

  const [amount, setAmount] = useState("10");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoting, setQuoting] = useState(false);
  const [quoteError, setQuoteError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  const usdcAddress = usdc?.address;
  const jouleAddress = joule?.address;
  const chainId = targetNetwork.id;
  const amountIn = parseAmount(amount);

  // Deliberately not memoized: the React Compiler cannot preserve memoization
  // across the derived `amountIn`, and the effect below depends on primitives.
  const requestQuote = async () => {
    if (!usdcAddress || !jouleAddress || !address || amountIn <= 0n) return null;
    return getQuote({ tokenIn: usdcAddress, tokenOut: jouleAddress, amountIn, swapper: address, chainId });
  };

  // Indicative quote as you type. The quote actually executed is re-fetched at
  // buy time, because an approval transaction in between can change permitData.
  useEffect(() => {
    if (!address || !usdcAddress || !jouleAddress || amountIn <= 0n) {
      setQuote(null);
      setQuoteError(null);
      return;
    }
    let cancelled = false;
    const controller = new AbortController();
    setQuoting(true);

    const timer = setTimeout(async () => {
      try {
        const next = await getQuote(
          { tokenIn: usdcAddress, tokenOut: jouleAddress, amountIn, swapper: address, chainId },
          controller.signal,
        );
        if (!cancelled) {
          setQuote(next);
          setQuoteError(null);
        }
      } catch (error) {
        if (cancelled || controller.signal.aborted) return;
        setQuote(null);
        setQuoteError(describeQuoteError(error));
      } finally {
        if (!cancelled) setQuoting(false);
      }
    }, QUOTE_DEBOUNCE_MS);

    return () => {
      cancelled = true;
      controller.abort();
      clearTimeout(timer);
    };
  }, [address, usdcAddress, jouleAddress, amountIn, chainId]);

  const buy = async () => {
    if (!address || !usdcAddress || amountIn <= 0n) return;
    setBusy(true);

    try {
      // 1. Let Permit2 move our USDC, if it cannot already. The API tells us
      //    whether this is needed and hands back the exact transaction.
      const approval = await checkApproval({ walletAddress: address, token: usdcAddress, amount: amountIn, chainId });
      if (approval) {
        await transactor({ to: approval.to, data: approval.data, value: 0n });
      }

      // 2. Re-quote after approval: permitData depends on the allowance state
      //    we just changed, so the debounced quote may be stale.
      const fresh = await requestQuote();
      if (!fresh) throw new Error("Could not price this trade");

      // 3. Sign the Permit2 payload if the API asked for one.
      let signature: Hex | undefined;
      if (fresh.permitData) {
        // viem derives EIP712Domain from `domain`; passing it in `types` too is
        // rejected as a duplicate definition.
        const types = Object.fromEntries(
          Object.entries(fresh.permitData.types).filter(([name]) => name !== "EIP712Domain"),
        );
        signature = await signTypedDataAsync({
          domain: fresh.permitData.domain as any,
          types: types as any,
          primaryType: derivePrimaryType(fresh.permitData.types),
          message: fresh.permitData.values as any,
        });
      }

      // 4. The API builds the calldata; we only send it.
      const swap = await buildSwap({ quote: fresh.raw, permitData: fresh.permitData, signature });
      await transactor({ to: swap.to, data: swap.data, value: swap.value ? BigInt(swap.value) : 0n });

      onBought?.();
    } catch (error) {
      notification.error(describeQuoteError(error));
    } finally {
      setBusy(false);
    }
  };

  const out = quote ? Number(formatUnits(quote.amountOut, JOULE_DECIMALS)) : null;
  const unitPrice = out && out > 0 ? Number(amount) / out : null;
  const held = usdcBalance ?? 0n;
  // Caught here rather than left to revert inside the router, where the error
  // is several frames deep and says nothing about balance.
  const insufficient = amountIn > held;

  return (
    <Panel
      kind="act"
      code="BUY"
      title="Acquire"
      note="Uniswap Trading API"
      hint="Buy Joules on the open market. The quote, the approval and the swap calldata all come from Uniswap — we build none of it."
    >
      <label className="jl-k" htmlFor="jl-pay" style={{ display: "block", marginBottom: 8 }}>
        You pay · USDC
      </label>
      <input
        id="jl-pay"
        className="jl-input"
        type="number"
        min="0"
        step="0.01"
        inputMode="decimal"
        value={amount}
        onChange={e => setAmount(e.target.value)}
        disabled={busy}
      />

      <div className="jl-quote" style={{ minHeight: 96 }}>
        {quoting ? (
          <span className="jl-dim">Pricing…</span>
        ) : quoteError ? (
          <span style={{ color: "var(--jl-alarm)", fontSize: "var(--jl-small)" }}>{quoteError}</span>
        ) : quote ? (
          <>
            <div style={ROW}>
              <span className="jl-k">You receive</span>
              <span
                style={{
                  fontSize: 30,
                  color: "var(--jl-data)",
                  fontWeight: 700,
                  fontVariantNumeric: "tabular-nums",
                  lineHeight: 1,
                }}
              >
                {out?.toFixed(4)}
              </span>
            </div>
            <div style={{ ...ROW, marginTop: 10 }}>
              <span className="jl-dim" style={{ fontSize: "var(--jl-small)" }}>
                {unitPrice?.toFixed(4)} each
              </span>
              <span className="jl-dim" style={{ fontSize: "var(--jl-small)" }}>
                {quote.routeType ?? "route"}
                {quote.priceImpactPct !== null ? ` · ${quote.priceImpactPct.toFixed(2)}% impact` : ""}
              </span>
            </div>
          </>
        ) : (
          <span className="jl-dim" style={{ fontSize: "var(--jl-small)" }}>
            Enter an amount to see a quote.
          </span>
        )}
      </div>

      <button
        className="jl-btn"
        type="button"
        onClick={buy}
        disabled={!connected || busy || !quote || amountIn <= 0n || insufficient}
      >
        {!connected ? "Connect a wallet" : insufficient ? "Not enough USDC" : busy ? "Buying…" : "Buy"}
      </button>
    </Panel>
  );
};

const ROW = { display: "flex", justifyContent: "space-between", alignItems: "baseline", gap: 14 } as const;

function parseAmount(value: string): bigint {
  try {
    return parseUnits(value || "0", USDC_DECIMALS);
  } catch {
    return 0n;
  }
}

function describeQuoteError(error: unknown): string {
  if (error instanceof TradingApiError) {
    if (error.isNoRoute) {
      // The exact failure this project hit on Sepolia. Naming the likely cause
      // beats "no quotes available", which is indistinguishable from a typo in
      // a token address.
      return "No route. The pool may have no active liquidity at the current tick, or the token is not indexed yet.";
    }
    if (error.isRateLimited) return "Uniswap API rate limit hit — wait a moment and try again.";
    return `Uniswap API: ${error.message}`;
  }
  if (error instanceof Error) return error.message;
  return String(error);
}
