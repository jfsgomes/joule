import { NextRequest, NextResponse } from "next/server";

/**
 * Server-side proxy for the Uniswap Trading API.
 *
 * The browser calls this route; this route adds the `x-api-key` header and
 * forwards upstream. The key never reaches the client.
 *
 * WHY A PROXY AT ALL
 * `UNISWAP_API_KEY` deliberately has no `NEXT_PUBLIC_` prefix. That prefix
 * inlines a value into the browser bundle at build time, and both this repo and
 * the deployed site are public -- the key would be readable by anyone, and
 * permanently baked into any IPFS build we pinned.
 *
 * IPFS CAVEAT
 * `next.config.ts` sets `output: "export"` when NEXT_PUBLIC_IPFS_BUILD=true, and
 * a static export has no server: it supports GET route handlers only, rendered
 * once at build time. This route cannot exist in that build. An IPFS-hosted
 * frontend therefore has to call the Vercel-hosted proxy by absolute URL --
 * a centralised dependency in an otherwise decentralised deploy. Decide that
 * deliberately before the IPFS step rather than discovering it then.
 */

const UPSTREAM = "https://trade-api.gateway.uniswap.org/v1";

/**
 * Only the endpoints this app actually uses.
 *
 * A blanket catch-all would turn this route into a public gateway to our
 * rate-limited key: the site is public, so anyone could point their own client
 * at it. The allowlist does not stop that, but it does bound what an abuser can
 * do to the endpoints we already expose.
 */
const ALLOWED_POST = new Set(["quote", "swap", "order", "check_approval"]);
const ALLOWED_GET = new Set(["swaps"]);

/** Upstream is quick; do not let a hung request pin a serverless invocation. */
const TIMEOUT_MS = 10_000;

type RouteContext = { params: Promise<{ path: string[] }> };

function resolveEndpoint(segments: string[], allowed: Set<string>): string | null {
  // Single segment only -- no traversal, no nested paths.
  if (segments.length !== 1) return null;
  const endpoint = segments[0];
  return allowed.has(endpoint) ? endpoint : null;
}

async function forward(request: NextRequest, endpoint: string, method: "GET" | "POST") {
  const apiKey = process.env.UNISWAP_API_KEY;

  if (!apiKey || apiKey.startsWith("REPLACE_ME")) {
    return NextResponse.json(
      {
        error: "UNISWAP_API_KEY is not configured",
        hint: "Set it in packages/nextjs/.env.local (no NEXT_PUBLIC_ prefix), and in Vercel via `vercel env add UNISWAP_API_KEY`.",
      },
      { status: 500 },
    );
  }

  const url = new URL(`${UPSTREAM}/${endpoint}`);
  // Forward query params for GET endpoints such as /swaps?txHash=...
  request.nextUrl.searchParams.forEach((value, key) => url.searchParams.append(key, value));

  // Headers are constructed here rather than forwarded from the client, so a
  // caller cannot inject their own auth or smuggle headers upstream.
  const headers: Record<string, string> = {
    "x-api-key": apiKey,
    accept: "application/json",
  };
  if (method === "POST") headers["content-type"] = "application/json";

  // UniswapX native-ETH support is opt-in via this header; pass it through when
  // the client asks for it, since it changes routing rather than auth.
  if (request.headers.get("x-erc20eth-enabled") === "true") {
    headers["x-erc20eth-enabled"] = "true";
  }

  const body = method === "POST" ? await request.text() : undefined;

  try {
    const upstream = await fetch(url, {
      method,
      headers,
      body,
      signal: AbortSignal.timeout(TIMEOUT_MS),
      cache: "no-store",
    });

    const text = await upstream.text();

    // Pass the upstream status through untouched. 401 means our key is bad,
    // 429 means we hit the 3 req/s default limit -- the client needs to be able
    // to tell those apart and back off accordingly.
    return new NextResponse(text, {
      status: upstream.status,
      headers: { "content-type": upstream.headers.get("content-type") ?? "application/json" },
    });
  } catch (error) {
    const timedOut = error instanceof Error && error.name === "TimeoutError";
    return NextResponse.json(
      { error: timedOut ? "Uniswap API timed out" : "Uniswap API request failed" },
      { status: 504 },
    );
  }
}

export async function POST(request: NextRequest, context: RouteContext) {
  const { path } = await context.params;
  const endpoint = resolveEndpoint(path, ALLOWED_POST);

  if (!endpoint) {
    return NextResponse.json({ error: "Unknown endpoint", allowed: [...ALLOWED_POST] }, { status: 404 });
  }

  return forward(request, endpoint, "POST");
}

export async function GET(request: NextRequest, context: RouteContext) {
  const { path } = await context.params;
  const endpoint = resolveEndpoint(path, ALLOWED_GET);

  if (!endpoint) {
    return NextResponse.json({ error: "Unknown endpoint", allowed: [...ALLOWED_GET] }, { status: 404 });
  }

  return forward(request, endpoint, "GET");
}
