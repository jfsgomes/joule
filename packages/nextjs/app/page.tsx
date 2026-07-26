"use client";

import { useCallback, useState } from "react";
import type { NextPage } from "next";
import { BuyPanel } from "~~/components/joule/BuyPanel";
import { EscrowStats } from "~~/components/joule/EscrowStats";
import { JobsPanel } from "~~/components/joule/JobsPanel";
import { RedeemPanel } from "~~/components/joule/RedeemPanel";

/**
 * The demo, in the order the script runs it:
 *
 *   buy a Joule on the open market  ->  spend it on work  ->  watch it settle
 *
 * Milestone 7 is the design pass; this is deliberately plain.
 */
const Home: NextPage = () => {
  // Cheap cross-panel nudge: buying changes the balance Redeem reads, and
  // redeeming adds a row to Jobs. Both already poll, so this only shortens the
  // wait rather than being load-bearing.
  const [, setRefreshKey] = useState(0);
  const refresh = useCallback(() => setRefreshKey(key => key + 1), []);

  return (
    <div className="flex flex-col grow w-full px-4 sm:px-8 py-8 gap-6 max-w-6xl mx-auto">
      <header>
        <h1 className="text-4xl font-bold m-0">Joule</h1>
        <p className="opacity-70 mt-1 mb-0">
          A Joule is one unit of an agent&apos;s work — collateral-backed, redeemable, and priced by a market rather
          than set by its issuer.
        </p>
      </header>

      <EscrowStats />

      <div className="grid gap-6 lg:grid-cols-2">
        <BuyPanel onBought={refresh} />
        <RedeemPanel onRedeemed={refresh} />
      </div>

      <JobsPanel />

      <footer className="text-xs opacity-50 text-center pb-4">
        Buy priced and routed by the Uniswap Trading API · settlement enforced onchain by WorkEscrow
      </footer>
    </div>
  );
};

export default Home;
