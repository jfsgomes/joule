"use client";

import { useEffect, useState } from "react";
import { useIsClient } from "usehooks-ts";
import { type Hex, formatUnits, parseUnits } from "viem";
import { useAccount, useSignTypedData } from "wagmi";
import {
  useDeployedContractInfo,
  useScaffoldReadContract,
  useScaffoldWriteContract,
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

/** One tap should cover several demo buys without becoming a second chore. */
const FAUCET_AMOUNT = 100_000_000n; // 100 USDC

/**
 * Demo step 2: buy a Joule on the open market.
 *
 * THIS IS THE PRIZE INTEGRATION. Every part of the trade comes from the Uniswap
 * Trading API -- the price, the approval transaction, and the swap calldata. We
 * build none of it ourselves and we do not talk to the pool directly.
 *
 * That is also the safer choice, not just the required one: the API encodes for
 * the router that is actually deployed, which sidesteps the ABI drift between
 * `v4-periphery@main` and the live Universal Router documented in FEEDBACK.md.
 */
export const BuyPanel = ({ onBought }: { onBought?: () => void }) => {
  const { address, isConnected } = useAccount();
  // wagmi restores the session from storage only on the client, so `isConnected`
  // is false during SSR and may be true on the very first client render. Any
  // markup that branches on it hydrates mismatched. Gating on `useIsClient`
  // makes the server render and the first client render identical, then lets
  // the real state land on the next paint.
  const connected = useIsClient() && isConnected;
  const { targetNetwork } = useTargetNetwork();
  const transactor = useTransactor();
  const { signTypedDataAsync } = useSignTypedData();

  const { data: usdc } = useDeployedContractInfo({ contractName: "MockUSDC" });
  const { data: joule } = useDeployedContractInfo({ contractName: "JouleToken" });

  const [amount, setAmount] = useState("10");
  const [quote, setQuote] = useState<Quote | null>(null);
  const [quoting, setQuoting] = useState(false);
  const [quoteError, setQuoteError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [minting, setMinting] = useState(false);

  const { data: usdcBalance, refetch: refetchUsdcBalance } = useScaffoldReadContract({
    contractName: "MockUSDC",
    functionName: "balanceOf",
    args: [address],
    watch: true,
  });
  const { writeContractAsync: writeUsdc } = useScaffoldWriteContract({ contractName: "MockUSDC" });

  const usdcAddress = usdc?.address;
  const jouleAddress = joule?.address;
  const chainId = targetNetwork.id;

  const amountIn = parseAmount(amount);

  // Deliberately not wrapped in useCallback. The React Compiler cannot preserve
  // memoization across the derived `amountIn`, and a stable identity buys
  // nothing here -- the effect below depends on primitives, not on this.
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
    // Aborts the in-flight request when you keep typing. Without this a
    // superseded quote can still land and overwrite a newer one, and its
    // cancellation surfaces as a console error rather than being ignored.
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

  /**
   * MockUSDC is deliberately open-mint -- see its contract notes. That is only
   * acceptable because it is a disposable testnet token, and it is what lets the
   * demo be re-run without queueing at a faucet.
   */
  const mintTestUsdc = async () => {
    if (!address) return;
    setMinting(true);
    try {
      await writeUsdc({ functionName: "mint", args: [address, FAUCET_AMOUNT] });
      await refetchUsdcBalance();
    } catch (error) {
      // useScaffoldWriteContract already toasts a parsed error.
      console.error(error);
    } finally {
      setMinting(false);
    }
  };

  const buy = async () => {
    if (!address || !usdcAddress || amountIn <= 0n) return;
    setBusy(true);

    try {
      // 1. Let Permit2 move our USDC, if it cannot already. The API tells us
      //    whether this is needed and hands back the exact transaction.
      const approval = await checkApproval({
        walletAddress: address,
        token: usdcAddress,
        amount: amountIn,
        chainId,
      });

      if (approval) {
        await transactor({ to: approval.to, data: approval.data, value: 0n });
      }

      // 2. Re-quote after approval: permitData depends on the allowance state
      //    we just changed, so the quote from the typing debounce may be stale.
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
      const swap = await buildSwap({
        quote: fresh.raw,
        permitData: fresh.permitData,
        signature,
      });

      await transactor({
        to: swap.to,
        data: swap.data,
        value: swap.value ? BigInt(swap.value) : 0n,
      });

      onBought?.();
    } catch (error) {
      notification.error(describeQuoteError(error));
    } finally {
      setBusy(false);
    }
  };

  const out = quote ? Number(formatUnits(quote.amountOut, JOULE_DECIMALS)) : null;
  const unitPrice = quote && quote.amountOut > 0n ? Number(amount) / (out ?? 1) : null;

  const held = usdcBalance ?? 0n;
  // Caught here rather than left to revert inside the router, where the error is
  // several frames deep and says nothing about balance.
  const insufficient = amountIn > held;

  return (
    <div className="card bg-base-100 shadow-xl">
      <div className="card-body">
        <h2 className="card-title">Buy Joules</h2>
        <p className="text-sm opacity-70 -mt-2">
          Priced and routed by the Uniswap Trading API. This is price discovery for agent labour.
        </p>

        <label className="form-control w-full">
          <div className="label">
            <span className="label-text">You pay (USDC)</span>
          </div>
          <input
            type="number"
            min="0"
            step="0.01"
            className="input input-bordered w-full"
            value={amount}
            onChange={e => setAmount(e.target.value)}
            disabled={busy}
          />
        </label>

        <div className="flex items-center justify-between mt-1">
          <span className="text-xs opacity-70">Balance {Number(formatUnits(held, USDC_DECIMALS)).toFixed(2)} USDC</span>
          <button className="btn btn-ghost btn-xs" onClick={mintTestUsdc} disabled={!connected || minting}>
            {minting ? <span className="loading loading-spinner loading-xs" /> : null}
            Mint 100 test USDC
          </button>
        </div>

        <div className="bg-base-200 rounded-box p-4 mt-2 min-h-24 flex flex-col justify-center">
          {quoting ? (
            <span className="loading loading-dots loading-md self-center" />
          ) : quoteError ? (
            <p className="text-sm text-error m-0">{quoteError}</p>
          ) : quote ? (
            <>
              <div className="flex justify-between items-baseline">
                <span className="text-sm opacity-70">You receive</span>
                <span className="text-2xl font-bold">{out?.toFixed(4)} JOULE</span>
              </div>
              <div className="flex justify-between text-xs opacity-70 mt-2">
                <span>≈ {unitPrice?.toFixed(4)} USDC each</span>
                <span>
                  {quote.routeType ?? "route"}
                  {quote.priceImpactPct !== null ? ` · ${quote.priceImpactPct.toFixed(2)}% impact` : ""}
                </span>
              </div>
            </>
          ) : (
            <p className="text-sm opacity-60 m-0 text-center">Enter an amount to see a quote.</p>
          )}
        </div>

        <div className="card-actions mt-2">
          <button
            className="btn btn-primary w-full"
            onClick={buy}
            disabled={!connected || busy || !quote || amountIn <= 0n || insufficient}
          >
            {busy ? <span className="loading loading-spinner loading-sm" /> : null}
            {!connected ? "Connect a wallet" : insufficient ? "Not enough USDC" : busy ? "Buying…" : "Buy"}
          </button>
        </div>
      </div>
    </div>
  );
};

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
