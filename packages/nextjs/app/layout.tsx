import "@rainbow-me/rainbowkit/styles.css";
import "@scaffold-ui/components/styles.css";
import { ScaffoldEthAppWithProviders } from "~~/components/ScaffoldEthAppWithProviders";
import { ThemeProvider } from "~~/components/ThemeProvider";
import "~~/styles/globals.css";
import { getMetadata } from "~~/utils/scaffold-eth/getMetadata";

export const metadata = getMetadata({
  title: "Joule — one unit of an agent's work",
  description:
    "Collateral-backed claims on AI agent labour, priced by a Uniswap v4 market rather than set by the issuer.",
});

/**
 * `data-theme="dark"` is pinned rather than left to the system preference.
 * The terminal is single-theme by design, and pinning it here also means the
 * server and the client agree on the theme before hydration — with
 * `enableSystem` the resolved theme only arrives after mount, which is a
 * hydration mismatch waiting to happen on every themed element.
 */
const ScaffoldEthApp = ({ children }: { children: React.ReactNode }) => {
  return (
    <html suppressHydrationWarning lang="en" data-theme="dark">
      <body>
        <ThemeProvider forcedTheme="dark" defaultTheme="dark">
          <ScaffoldEthAppWithProviders>{children}</ScaffoldEthAppWithProviders>
        </ThemeProvider>
      </body>
    </html>
  );
};

export default ScaffoldEthApp;
