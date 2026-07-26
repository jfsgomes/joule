import type { Address, Hex } from "viem";

/**
 * Client for the Uniswap Trading API, via our own `/api/uniswap/*` proxy.
 *
 * Nothing here talks to Uniswap directly: the API key is server-side only, so
 * every call goes through the route handler that attaches it. See
 * `app/api/uniswap/[...path]/route.ts`.
 *
 * The three-step shape is the API's, not ours:
 *
 *   check_approval -> does this wallet need to let Permit2 move its tokens?
 *   quote          -> what will this trade do, and does it need a signature?
 *   swap           -> give me the calldata to send
 *
 * We deliberately hand `quote` back to `/swap` verbatim rather than
 * reconstructing it. The quote is the API's own object, it is signed over by
 * whatever routing decisions it made, and rebuilding it client-side would be a
 * second source of truth that can silently disagree.
 */

const BASE = "/api/uniswap";

export type ApprovalTx = {
  to: Address;
  from: Address;
  data: Hex;
  value?: string;
  chainId: number;
};

export type SwapTx = {
  to: Address;
  from: Address;
  data: Hex;
  value?: string;
  chainId: number;
};

/** EIP-712 payload the API asks us to sign so Permit2 can move funds. */
export type PermitData = {
  domain: Record<string, unknown>;
  types: Record<string, { name: string; type: string }[]>;
  values: Record<string, unknown>;
};

export type Quote = {
  /** Pass back to `/swap` untouched. */
  raw: unknown;
  amountIn: bigint;
  amountOut: bigint;
  priceImpactPct: number | null;
  routeType: string | null;
  permitData: PermitData | null;
};

/**
 * Thrown for any non-2xx upstream response, carrying the status so callers can
 * distinguish "no route" from "rate limited" from "our key is broken".
 */
export class TradingApiError extends Error {
  constructor(
    readonly status: number,
    readonly errorCode: string | null,
    message: string,
  ) {
    super(message);
    this.name = "TradingApiError";
  }

  /**
   * The pool is not routable. On Sepolia the overwhelmingly likely cause is a
   * pool with no ACTIVE liquidity at the current tick -- see FEEDBACK.md. The
   * same 404 is also returned for an unknown token, so the message says both.
   */
  get isNoRoute() {
    return this.status === 404 || this.errorCode === "ResourceNotFound";
  }

  get isRateLimited() {
    return this.status === 429;
  }
}

async function post<T>(endpoint: string, body: unknown, signal?: AbortSignal): Promise<T> {
  let response: Response;
  try {
    response = await fetch(`${BASE}/${endpoint}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal,
    });
  } catch (error) {
    // A rejected fetch is a TypeError with a message like "NetworkError when
    // attempting to fetch resource" -- no status, no URL, and indistinguishable
    // from an application bug in the console. Name what we were doing.
    if (error instanceof DOMException && error.name === "AbortError") throw error;
    throw new TradingApiError(0, "NetworkError", `Could not reach ${BASE}/${endpoint} — is the dev server running?`);
  }

  const text = await response.text();
  let parsed: any;
  try {
    parsed = text ? JSON.parse(text) : {};
  } catch {
    parsed = { detail: text };
  }

  if (!response.ok) {
    const code = parsed?.errorCode ?? null;
    const detail = parsed?.detail ?? parsed?.error ?? response.statusText;
    throw new TradingApiError(response.status, code, detail);
  }
  return parsed as T;
}

export async function checkApproval(params: {
  walletAddress: Address;
  token: Address;
  amount: bigint;
  chainId: number;
}): Promise<ApprovalTx | null> {
  const response = await post<{ approval: ApprovalTx | null }>("check_approval", {
    walletAddress: params.walletAddress,
    token: params.token,
    amount: params.amount.toString(),
    chainId: params.chainId,
  });
  return response.approval ?? null;
}

export async function getQuote(
  params: {
    tokenIn: Address;
    tokenOut: Address;
    amountIn: bigint;
    swapper: Address;
    chainId: number;
  },
  signal?: AbortSignal,
): Promise<Quote> {
  const response = await post<any>(
    "quote",
    {
      type: "EXACT_INPUT",
      amount: params.amountIn.toString(),
      tokenIn: params.tokenIn,
      tokenOut: params.tokenOut,
      tokenInChainId: params.chainId,
      tokenOutChainId: params.chainId,
      swapper: params.swapper,
      // Our pool is vanilla v4 with no hook. Naming the protocol keeps the router
      // from wandering off through v2/v3 pairs that do not exist on Sepolia.
      protocols: ["V4"],
    },
    signal,
  );

  const quote = response?.quote ?? {};

  return {
    raw: quote,
    amountIn: BigInt(quote?.input?.amount ?? params.amountIn),
    amountOut: BigInt(quote?.output?.amount ?? 0),
    priceImpactPct: typeof quote?.priceImpact === "number" ? quote.priceImpact : null,
    routeType: quote?.route?.[0]?.[0]?.type ?? null,
    permitData: response?.permitData ?? null,
  };
}

export async function buildSwap(params: {
  quote: unknown;
  permitData?: PermitData | null;
  signature?: Hex;
}): Promise<SwapTx> {
  const body: Record<string, unknown> = { quote: params.quote };
  if (params.permitData && params.signature) {
    body.permitData = params.permitData;
    body.signature = params.signature;
  }

  const response = await post<{ swap: SwapTx }>("swap", body);
  if (!response?.swap?.to || !response?.swap?.data) {
    throw new TradingApiError(500, null, "Trading API returned no swap calldata");
  }
  return response.swap;
}

/**
 * EIP-712 requires a primary type; the API sends `types` without naming one.
 *
 * The primary type is the only struct no other struct refers to. Deriving it
 * beats hardcoding `PermitSingle`, which is merely what the API happens to send
 * today for a single-token permit and would break silently on a batch permit.
 */
export function derivePrimaryType(types: PermitData["types"]): string {
  const referenced = new Set<string>();
  for (const fields of Object.values(types)) {
    for (const field of fields) {
      referenced.add(field.type.replace(/\[\]$/, ""));
    }
  }
  const candidates = Object.keys(types).filter(name => name !== "EIP712Domain" && !referenced.has(name));
  if (candidates.length !== 1) {
    throw new Error(`Could not determine EIP-712 primary type (candidates: ${candidates.join(", ") || "none"})`);
  }
  return candidates[0];
}
