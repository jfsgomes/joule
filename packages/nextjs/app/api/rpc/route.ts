import { NextRequest, NextResponse } from "next/server";

/**
 * Server-side JSON-RPC proxy.
 *
 * The browser talks to this route; this route attaches the Alchemy key and
 * forwards upstream. `ALCHEMY_API_KEY` deliberately has no `NEXT_PUBLIC_`
 * prefix, so the key is never inlined into the client bundle and there is
 * nothing in the deployed site to extract.
 *
 * WHY NOT A DOMAIN ALLOWLIST
 * Alchemy can restrict an app by referrer, but the docs are explicit that
 * "a missing Origin header in the API request will cause the request to fail"
 * -- and `cast`, `forge` and the Node agent all send requests without one.
 * Restricting the single key this project uses everywhere would have broken
 * deploys and stopped the agent delivering. A proxy leaves those untouched.
 *
 * WHAT THIS DOES NOT SOLVE
 * The route is public, so anyone who finds it can still spend our quota
 * through our own origin. It is strictly better than a leaked key -- the
 * credential cannot be lifted and reused elsewhere, and the method allowlist
 * below bounds what an abuser can ask for -- but it is not a rate limiter.
 * Add one before this is anything other than a testnet demo.
 *
 * IPFS CAVEAT
 * Same as the Uniswap proxy: `next.config.ts` sets `output: "export"` when
 * NEXT_PUBLIC_IPFS_BUILD=true, and a static export has no server. An
 * IPFS-hosted build has to point NEXT_PUBLIC_RPC_PROXY at a hosted origin.
 */

const UPSTREAM = "https://eth-sepolia.g.alchemy.com/v2";
const TIMEOUT_MS = 15_000;

/**
 * Log queries go to a different key, and the reason is not obvious.
 *
 * Alchemy's FREE tier refuses any `eth_getLogs` spanning more than 10 blocks.
 * The job ledger reads from the escrow's deploy block — thousands of blocks —
 * so a free key cannot serve it at all. Scaffold-ETH's shared default key sits
 * on a paid plan and has no such cap.
 *
 * So: the private key handles the chatty traffic, where its own rate limit is
 * the thing that matters, and log queries fall back to the shared key, which is
 * the only one that can answer them. Log queries are rare, so leaning on a
 * shared key for them costs little.
 *
 * Set ALCHEMY_ARCHIVE_API_KEY to a paid key of your own and this split
 * disappears — both paths use it.
 */
const LOG_METHODS = new Set(["eth_getLogs", "eth_getFilterLogs"]);

/** Scaffold-ETH's public default. Not a secret; it ships in every SE-2 build. */
const SHARED_FALLBACK_KEY = "IZYEU2cWBgnFmgiTAgpWD";

/**
 * Exactly what the app calls, and nothing else.
 *
 * `eth_sendRawTransaction` has to be here or no one can buy or redeem. It is
 * not a hole: the transaction is already signed by the user's wallet, so this
 * route can only relay what someone else authorised.
 */
const ALLOWED = new Set([
  // chain / head
  "eth_chainId",
  "net_version",
  "eth_blockNumber",
  "eth_getBlockByNumber",
  "eth_getBlockByHash",
  // reads
  "eth_call",
  "eth_getLogs",
  "eth_getBalance",
  "eth_getCode",
  "eth_getTransactionCount",
  "eth_getStorageAt",
  // fees and simulation
  "eth_estimateGas",
  "eth_gasPrice",
  "eth_feeHistory",
  "eth_maxPriorityFeePerGas",
  // writes and their receipts
  "eth_sendRawTransaction",
  "eth_getTransactionByHash",
  "eth_getTransactionReceipt",
  // filters, in case a transport prefers them to polling
  "eth_newFilter",
  "eth_newBlockFilter",
  "eth_getFilterChanges",
  "eth_getFilterLogs",
  "eth_uninstallFilter",
]);

/** A batch is one round trip; this bounds how much work one request can ask for. */
const MAX_BATCH = 30;

type RpcCall = { method?: unknown; id?: unknown };

function rejected(id: unknown, message: string) {
  return { jsonrpc: "2.0", id: id ?? null, error: { code: -32601, message } };
}

export async function POST(request: NextRequest) {
  const apiKey = process.env.ALCHEMY_API_KEY;
  if (!apiKey) {
    return NextResponse.json(
      {
        error: "ALCHEMY_API_KEY is not configured",
        hint: "Set it in packages/nextjs/.env.local (no NEXT_PUBLIC_ prefix), and in Vercel via `vercel env add ALCHEMY_API_KEY`.",
      },
      { status: 500 },
    );
  }

  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json({ error: "Body must be JSON-RPC" }, { status: 400 });
  }

  const calls: RpcCall[] = Array.isArray(body) ? body : [body as RpcCall];

  if (calls.length === 0 || calls.length > MAX_BATCH) {
    return NextResponse.json({ error: `Batch must be 1..${MAX_BATCH} calls` }, { status: 400 });
  }

  const blocked = calls.find(call => typeof call?.method !== "string" || !ALLOWED.has(call.method as string));
  if (blocked) {
    // Answered in JSON-RPC shape rather than as an HTTP error, so viem surfaces
    // it as a method problem instead of a transport failure.
    const message = `Method not allowed: ${String(blocked.method)}`;
    const payload = Array.isArray(body) ? calls.map(call => rejected(call.id, message)) : rejected(blocked.id, message);
    return NextResponse.json(payload, { status: 200 });
  }

  // One key per request, chosen by the batch: if anything in it is a log query,
  // the whole batch needs the archive-capable key.
  const needsArchive = calls.some(call => LOG_METHODS.has(call.method as string));
  const key = needsArchive ? (process.env.ALCHEMY_ARCHIVE_API_KEY ?? SHARED_FALLBACK_KEY) : apiKey;

  try {
    const upstream = await fetch(`${UPSTREAM}/${key}`, {
      method: "POST",
      headers: { "content-type": "application/json" },
      body: JSON.stringify(body),
      signal: AbortSignal.timeout(TIMEOUT_MS),
      cache: "no-store",
    });

    return new NextResponse(await upstream.text(), {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  } catch (error) {
    const timedOut = error instanceof Error && error.name === "TimeoutError";
    return NextResponse.json({ error: timedOut ? "RPC timed out" : "RPC request failed" }, { status: 504 });
  }
}
