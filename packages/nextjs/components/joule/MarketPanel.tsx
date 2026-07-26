"use client";

import { useReadContract } from "wagmi";
import { Panel } from "~~/components/joule/Panel";
import { useDeployedContractInfo, useTargetNetwork } from "~~/hooks/scaffold-eth";
import {
  BID_LOW,
  SELL_HIGH,
  SPOT_PRICE,
  STATE_VIEW,
  computePoolId,
  jouleIsToken0,
  priceFromSqrtX96,
  stateViewAbi,
} from "~~/utils/joule/pool";

/**
 * What the market currently thinks an agent's work is worth.
 *
 * The depth profile is the pool's real shape rather than a price history: with
 * a young pool a two-point line says nothing, whereas the shape says the thing
 * that actually matters — a bid holding only USDC below spot, a sell wall
 * holding only Joules above it, meeting exactly at the opening tick. That
 * meeting point is load-bearing: leave a gap there and the pool reports zero
 * liquidity and routers refuse to quote it. See FEEDBACK.md.
 */
export const MarketPanel = () => {
  const { targetNetwork } = useTargetNetwork();
  const { data: joule } = useDeployedContractInfo({ contractName: "JouleToken" });
  const { data: usdc } = useDeployedContractInfo({ contractName: "MockUSDC" });

  const ready = Boolean(joule?.address && usdc?.address);
  const poolId = ready ? computePoolId(joule!.address, usdc!.address) : undefined;
  const isToken0 = ready ? jouleIsToken0(joule!.address, usdc!.address) : true;

  const { data: slot0 } = useReadContract({
    address: STATE_VIEW,
    abi: stateViewAbi,
    functionName: "getSlot0",
    args: poolId ? [poolId] : undefined,
    chainId: targetNetwork.id,
    query: { enabled: Boolean(poolId), refetchInterval: 6_000 },
  });

  const { data: liquidity } = useReadContract({
    address: STATE_VIEW,
    abi: stateViewAbi,
    functionName: "getLiquidity",
    args: poolId ? [poolId] : undefined,
    chainId: targetNetwork.id,
    query: { enabled: Boolean(poolId), refetchInterval: 6_000 },
  });

  const price = slot0 ? priceFromSqrtX96(slot0[0], isToken0) : null;
  const drift = price !== null ? ((price - SPOT_PRICE) / SPOT_PRICE) * 100 : null;

  // Position the spot marker on the seeded band. Clamped so an excursion past
  // the wall pins the marker at the edge rather than drawing off-canvas.
  const span = SELL_HIGH - BID_LOW;
  const t = price === null ? 0.5 : Math.min(0.98, Math.max(0.02, (price - BID_LOW) / span));
  const x = 40 + t * 560;

  return (
    <Panel
      kind="read"
      code="MKT"
      title="Market"
      note={`Uniswap v4 · ${POOL_FEE_PCT.toFixed(2)}%`}
      hint="What the market currently pays for one unit of this agent's work. The issuer never sets this number."
    >
      <div className="jl-big">{price === null ? "—" : price.toFixed(4)}</div>
      <div className="jl-unit">
        USDC per Joule
        {drift !== null ? (
          <>
            {" · "}
            <span style={{ color: "var(--jl-accent)", fontWeight: 700 }}>
              {drift >= 0 ? "▲" : "▼"} {Math.abs(drift).toFixed(2)}% since open
            </span>
          </>
        ) : null}
      </div>

      <div style={{ marginTop: 20 }}>
        <svg
          viewBox="0 0 640 210"
          style={{ display: "block", width: "100%", height: "auto" }}
          role="img"
          aria-label={`Liquidity depth around spot. Bid holds USDC below ${SPOT_PRICE}, sell wall holds Joules above it.`}
        >
          <g stroke="var(--jl-rule-dim)" strokeWidth="1">
            <line x1="0" y1="46" x2="640" y2="46" />
            <line x1="0" y1="92" x2="640" y2="92" />
            <line x1="0" y1="138" x2="640" y2="138" />
          </g>

          {/* bid: USDC only, below spot */}
          <path
            d="M40,172 L40,142 L120,142 L120,128 L200,128 L200,114 L280,114 L280,100 L316,100 L316,172 Z"
            fill="var(--jl-data)"
            fillOpacity="0.22"
            stroke="var(--jl-data)"
            strokeWidth="2.5"
          />
          {/* sell wall: Joules only, above spot */}
          <path
            d="M324,172 L324,60 L400,60 L400,70 L480,70 L480,86 L560,86 L560,102 L600,102 L600,172 Z"
            fill="var(--jl-accent)"
            fillOpacity="0.24"
            stroke="var(--jl-accent)"
            strokeWidth="2.5"
          />

          <line x1={x} y1="28" x2={x} y2="180" stroke="var(--jl-bright)" strokeWidth="2" strokeDasharray="5 5" />
          <circle cx={x} cy="60" r="6" fill="var(--jl-bright)" />
          <text
            x={x > 460 ? x - 12 : x + 12}
            y="26"
            textAnchor={x > 460 ? "end" : "start"}
            style={{ fontSize: 14, fill: "var(--jl-bright)", fontWeight: 700, letterSpacing: "0.1em" }}
          >
            {price === null ? "SPOT" : `SPOT ${price.toFixed(4)}`}
          </text>
          <text x="40" y="200" style={AXIS}>
            {BID_LOW.toFixed(2)} BID
          </text>
          <text x="540" y="200" style={AXIS}>
            {SELL_HIGH.toFixed(2)} ASK
          </text>
        </svg>
      </div>

      <div
        style={{
          display: "flex",
          gap: 22,
          marginTop: 14,
          flexWrap: "wrap",
          fontSize: "var(--jl-small)",
          letterSpacing: "0.12em",
          textTransform: "uppercase",
          color: "var(--jl-dim)",
          fontWeight: 500,
        }}
      >
        <span>
          <i style={{ ...SWATCH, background: "var(--jl-data)" }} />
          Bid · USDC only
        </span>
        <span>
          <i style={{ ...SWATCH, background: "var(--jl-accent)" }} />
          Sell wall · Joules only
        </span>
        <span style={{ marginLeft: "auto" }}>
          Active liquidity {liquidity === undefined ? "—" : liquidity > 0n ? "live" : "NONE"}
        </span>
      </div>
    </Panel>
  );
};

const POOL_FEE_PCT = 0.3;

const AXIS = {
  fontSize: 13,
  fill: "var(--jl-dim)",
  textTransform: "uppercase",
  letterSpacing: "0.14em",
  fontWeight: 500,
} as const;

const SWATCH = {
  display: "inline-block",
  width: 13,
  height: 13,
  marginRight: 8,
  verticalAlign: -2,
} as const;
