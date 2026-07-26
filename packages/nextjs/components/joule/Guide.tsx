"use client";

import { useIsClient } from "usehooks-ts";
import { useAccount } from "wagmi";
import { Panel } from "~~/components/joule/Panel";
import { useDeployedContractInfo, useScaffoldEventHistory, useScaffoldReadContract } from "~~/hooks/scaffold-eth";

const ONE_JOULE = 10n ** 18n;

/** Codes whose panels report rather than ask. Mirrors the panel surfaces. */
const READ_PANELS = new Set(["MKT", "CLR", "LDG"]);

type Step = {
  /** The panel's code. Leads the row so it can be matched to a panel by eye. */
  code: string;
  title: string;
  what: string;
  /** Present on panels you act in. Read panels report; they do not ask. */
  action?: string;
  /** Only meaningful for act steps — read panels are never "done". */
  done?: boolean;
};

/**
 * A live checklist, not a tutorial.
 *
 * Six panels with three-letter codes are efficient once you know the system
 * and opaque before that. Every panel gets a row here, in the order it appears
 * on the page, led by its code so the two can be matched by eye.
 *
 * Read panels describe what you can learn from them and carry no action. Act
 * panels carry an instruction and a completion state, and the "do this next"
 * pointer walks only through those — you cannot finish looking at a price, so
 * pretending MKT is a task to tick off would make the checklist lie.
 */
export const Guide = () => {
  const { address, isConnected } = useAccount();
  const connected = useIsClient() && isConnected;

  const { data: escrow } = useDeployedContractInfo({ contractName: "WorkEscrow" });

  const { data: usdc } = useScaffoldReadContract({
    contractName: "MockUSDC",
    functionName: "balanceOf",
    args: [address],
    watch: true,
  });
  const { data: joules } = useScaffoldReadContract({
    contractName: "JouleToken",
    functionName: "balanceOf",
    args: [address],
    watch: true,
  });
  const { data: owed } = useScaffoldReadContract({
    contractName: "WorkEscrow",
    functionName: "owed",
    args: [address],
    watch: true,
  });

  // Only this wallet's jobs — the ledger shows everyone's, but the briefing is
  // about what YOU have done.
  const { data: myJobs } = useScaffoldEventHistory({
    contractName: "WorkEscrow",
    eventName: "Redeemed",
    fromBlock: BigInt(escrow?.deployedOnBlock ?? 0),
    filters: { redeemer: address },
    watch: true,
  });

  const hasUsdc = (usdc ?? 0n) > 0n;
  const hasJoule = (joules ?? 0n) >= ONE_JOULE;
  const hasCommissioned = (myJobs?.length ?? 0) > 0;
  const hasPayout = (owed ?? 0n) > 0n;

  // Page order, so scanning the list and scanning the page agree.
  const steps: Step[] = [
    {
      code: "MKT",
      title: "What the work is worth",
      what: "The live price of one Joule, and the shape of the pool behind it. Quoted by a Uniswap v4 market — the issuer never sets this number.",
    },
    {
      code: "WLT",
      title: "What you hold",
      what: "Your balances, and the faucet for the stand-in dollar. Real USDC is scarce on a testnet, so this one is freely mintable.",
      action: "Press Mint 100 test USDC.",
      done: hasUsdc,
    },
    {
      code: "CLR",
      title: "Why it is worth anything",
      what: "The agent's locked collateral. Every Joule in circulation is backed by it, and a default pays the holder out of it. This is the guarantee.",
    },
    {
      code: "BUY",
      title: "Buy a Joule",
      what: "The quote, the approval and the swap calldata all come from the Uniswap Trading API. We build none of it and never touch the pool directly.",
      action: "Enter an amount and press Buy.",
      done: hasJoule || hasCommissioned,
    },
    {
      code: "RDM",
      title: "Spend it on work",
      what: "Your Joule moves into escrow custody and the agent gets a fixed window to deliver. That custody is the lock — no flag on the token is needed.",
      action: "Pick two numbers and press Redeem.",
      done: hasCommissioned,
    },
    {
      code: "LDG",
      title: "Watch what happens",
      what: "Settled means the agent delivered and a contract checked the answer. Slashed means it did not, and the holder took its collateral instead — that is what makes the promise credible.",
    },
  ];

  const currentCode = connected ? steps.find(step => step.action && !step.done)?.code : undefined;

  return (
    <Panel
      kind="read"
      code="OPS"
      title="What to do"
      note={connected ? undefined : "Not connected"}
      hint="One row per panel below, in the order they appear. Amber rows are things you do; cyan rows are things you read."
    >
      {!connected ? (
        <p
          className="jl-prose"
          style={{ margin: "0 0 16px", fontSize: 16, color: "var(--jl-accent)", fontWeight: 700 }}
        >
          Connect a wallet on Sepolia to begin. Everything here is live on a public testnet — real transactions, no real
          money.
        </p>
      ) : null}

      <ol
        style={{
          listStyle: "none",
          margin: 0,
          padding: 0,
          display: "grid",
          gap: 1,
          background: "var(--jl-rule-dim)",
          border: "1px solid var(--jl-rule-dim)",
        }}
      >
        {steps.map(step => {
          const isRead = READ_PANELS.has(step.code);
          const isCurrent = step.code === currentCode;
          const chip = isRead ? "var(--jl-data)" : "var(--jl-accent)";

          return (
            <li
              key={step.code}
              style={{
                background: isCurrent ? "var(--jl-raise-act)" : "var(--jl-raise-read)",
                padding: "14px 18px",
                display: "flex",
                gap: 16,
                alignItems: "flex-start",
                opacity: step.done && !isCurrent ? 0.6 : 1,
                borderLeft: `3px solid ${isCurrent ? "var(--jl-accent)" : "transparent"}`,
              }}
            >
              <span
                style={{
                  background: chip,
                  color: "var(--jl-void)",
                  fontSize: 11.5,
                  letterSpacing: "0.24em",
                  fontWeight: 700,
                  padding: "4px 9px 3px",
                  flexShrink: 0,
                }}
              >
                {step.code}
              </span>

              <div style={{ flex: 1, minWidth: 0 }}>
                <div
                  style={{
                    fontSize: 15,
                    fontWeight: 700,
                    letterSpacing: "0.06em",
                    color: isCurrent ? "var(--jl-bright)" : "var(--jl-text)",
                  }}
                >
                  {step.title}
                  {step.done ? <span style={{ color: "var(--jl-data)", marginLeft: 10 }}>✓ done</span> : null}
                </div>

                {isCurrent ? (
                  <div style={{ marginTop: 6, color: "var(--jl-accent)", fontSize: 14, fontWeight: 700 }}>
                    → {step.action}
                  </div>
                ) : null}

                <p className="jl-prose" style={{ margin: "6px 0 0", fontSize: 14 }}>
                  {step.what}
                </p>
              </div>
            </li>
          );
        })}
      </ol>

      {hasPayout ? (
        <p style={{ margin: "16px 0 0", color: "var(--jl-alarm)", fontSize: 15, fontWeight: 700 }}>
          An agent defaulted on one of your jobs. CLR is holding your payout — press Withdraw there.
        </p>
      ) : null}
    </Panel>
  );
};
