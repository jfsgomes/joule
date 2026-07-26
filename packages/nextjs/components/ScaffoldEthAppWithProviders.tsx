"use client";

import { RainbowKitProvider, darkTheme } from "@rainbow-me/rainbowkit";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { AppProgressBar as ProgressBar } from "next-nprogress-bar";
import { Toaster } from "react-hot-toast";
import { WagmiProvider } from "wagmi";
import { BlockieAvatar } from "~~/components/scaffold-eth";
import { wagmiConfig } from "~~/services/web3/wagmiConfig";

/**
 * Scaffold-ETH's Header and Footer are deliberately not rendered. The page
 * supplies its own status rail and footer, and the stock chrome carries a
 * theme switcher the terminal has no use for — it is single-theme by design.
 *
 * Attribution is NOT dropped along with the chrome: the page footer credits
 * Scaffold-ETH 2 and BuidlGuidl with links. Restyling someone's starter kit is
 * not a reason to stop naming it.
 *
 * The components are left in the tree rather than deleted, so `/debug` and
 * `/blockexplorer` keep working as the fallback demo surface PLAN.md calls for.
 */
const ScaffoldEthApp = ({ children }: { children: React.ReactNode }) => {
  return (
    <>
      <div className="flex flex-col min-h-screen">
        <main className="relative flex flex-col flex-1">{children}</main>
      </div>
      <Toaster />
    </>
  );
};

export const queryClient = new QueryClient({
  defaultOptions: {
    queries: {
      refetchOnWindowFocus: false,
    },
  },
});

export const ScaffoldEthAppWithProviders = ({ children }: { children: React.ReactNode }) => {
  return (
    <WagmiProvider config={wagmiConfig}>
      <QueryClientProvider client={queryClient}>
        {/* Always dark, and tuned to the terminal palette. There is no theme
            toggle to read, so nothing here depends on next-themes resolving
            after mount -- which also removes a hydration branch. */}
        <RainbowKitProvider
          avatar={BlockieAvatar}
          theme={darkTheme({
            accentColor: "#ffc247",
            accentColorForeground: "#04060b",
            borderRadius: "none",
            fontStack: "system",
          })}
        >
          <ProgressBar height="3px" color="#ffc247" />
          <ScaffoldEthApp>{children}</ScaffoldEthApp>
        </RainbowKitProvider>
      </QueryClientProvider>
    </WagmiProvider>
  );
};
