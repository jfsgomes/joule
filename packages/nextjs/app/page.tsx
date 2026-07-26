"use client";

import { useCallback, useState } from "react";
import type { NextPage } from "next";
import { BuyPanel } from "~~/components/joule/BuyPanel";
import { CollateralPanel } from "~~/components/joule/CollateralPanel";
import { Guide } from "~~/components/joule/Guide";
import { JobsPanel } from "~~/components/joule/JobsPanel";
import { MarketPanel } from "~~/components/joule/MarketPanel";
import { RedeemPanel } from "~~/components/joule/RedeemPanel";
import { StatusRail } from "~~/components/joule/StatusRail";
import { WalletPanel } from "~~/components/joule/WalletPanel";

/**
 * The demo, in the order the script runs it:
 *
 *   buy a Joule on the open market  ->  spend it on work  ->  watch it settle
 *
 * Panels are grouped by surface rather than by topic: cool panels report what
 * the chain says, warm panels are where you spend money. See globals.css.
 */
const Home: NextPage = () => {
  // Cheap cross-panel nudge. Every panel already polls, so this only shortens
  // the wait after an action rather than being load-bearing.
  const [, setRefreshKey] = useState(0);
  const refresh = useCallback(() => setRefreshKey(key => key + 1), []);

  return (
    <div className="jl-scan" style={{ minHeight: "100vh" }}>
      <div style={{ maxWidth: 1240, margin: "0 auto", padding: "0 24px 72px" }}>
        <StatusRail />

        <header style={{ padding: "40px 0 26px" }}>
          <h1
            style={{
              margin: 0,
              fontSize: "clamp(46px, 8vw, 82px)",
              lineHeight: 0.92,
              letterSpacing: "-0.025em",
              color: "var(--jl-bright)",
              fontWeight: 700,
              textWrap: "balance",
            }}
          >
            One unit of
            <br />
            an agent&apos;s <span style={{ color: "var(--jl-accent)" }}>work</span>.
          </h1>
          <p className="jl-prose" style={{ margin: "18px 0 0", maxWidth: "60ch", fontSize: 17, lineHeight: 1.6 }}>
            Collateral-backed, redeemable, and priced by a market rather than set by its issuer. Delivery burns the
            token; default slashes the agent&apos;s stake.
          </p>
        </header>

        <div
          style={{
            display: "flex",
            flexWrap: "wrap",
            gap: "10px 26px",
            alignItems: "center",
            padding: "0 0 20px",
            fontSize: "var(--jl-micro)",
            letterSpacing: "0.16em",
            textTransform: "uppercase",
            color: "var(--jl-dim)",
            fontWeight: 500,
          }}
        >
          <span>
            <i style={{ ...KEY_SWATCH, background: "var(--jl-panel-read)" }} />
            Cool — what the chain says
          </span>
          <span>
            <i style={{ ...KEY_SWATCH, background: "var(--jl-panel-act)" }} />
            Warm — what you can do
          </span>
        </div>

        <div style={{ display: "grid", gap: 18 }}>
          {/* The briefing goes first: six three-letter codes are efficient once
              you know the system and opaque before that. */}
          <Guide />

          <div className="jl-grid-2" style={{ display: "grid", gap: 18 }}>
            <MarketPanel />
            <WalletPanel />
          </div>

          <CollateralPanel />

          <div className="jl-grid-ops" style={{ display: "grid", gap: 18 }}>
            <BuyPanel onBought={refresh} />
            <RedeemPanel onRedeemed={refresh} />
          </div>

          <JobsPanel />
        </div>

        <footer
          style={{
            marginTop: 30,
            paddingTop: 18,
            borderTop: "1px solid var(--jl-rule-dim)",
            fontSize: "var(--jl-small)",
            letterSpacing: "0.14em",
            textTransform: "uppercase",
            color: "var(--jl-dim)",
            display: "flex",
            flexWrap: "wrap",
            gap: "12px 28px",
            fontWeight: 500,
          }}
        >
          <span>Priced by the Uniswap Trading API</span>
          <span>Settlement enforced onchain</span>
          <span>
            Built with{" "}
            <a href="https://scaffoldeth.io" target="_blank" rel="noreferrer" style={FOOT_LINK}>
              Scaffold-ETH 2
            </a>{" "}
            by{" "}
            <a href="https://buidlguidl.com" target="_blank" rel="noreferrer" style={FOOT_LINK}>
              BuidlGuidl
            </a>
          </span>
          <a
            href="https://github.com/jfsgomes/joule"
            target="_blank"
            rel="noreferrer"
            style={{ ...FOOT_LINK, marginLeft: "auto" }}
          >
            Source
          </a>
        </footer>
      </div>
    </div>
  );
};

const FOOT_LINK = {
  color: "var(--jl-data)",
  textDecoration: "none",
  borderBottom: "1px solid var(--jl-rule-dim)",
} as const;

const KEY_SWATCH = {
  display: "inline-block",
  width: 26,
  height: 14,
  marginRight: 9,
  border: "1px solid var(--jl-rule-dim)",
  verticalAlign: -2,
} as const;

export default Home;
