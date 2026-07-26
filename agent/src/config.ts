import "dotenv/config";
import { type Address, type Hex, isAddress } from "viem";
import { anvil, sepolia } from "viem/chains";

export type Config = {
  rpcUrl: string;
  escrow: Address;
  privateKey: Hex;
  /** How far back to scan for jobs missed while the agent was down. */
  lookbackBlocks: bigint;
  /** Largest block span a single getLogs request may cover. */
  logWindowBlocks: bigint;
  pollingIntervalMs: number;
};

class ConfigError extends Error {}

const required = (name: string): string => {
  const value = process.env[name];
  if (!value) {
    throw new ConfigError(
      `${name} is not set. Copy agent/.env.example to agent/.env and fill it in.`,
    );
  }
  return value;
};

export function loadConfig(): Config {
  const escrow = required("ESCROW_ADDRESS");
  if (!isAddress(escrow)) throw new ConfigError(`ESCROW_ADDRESS is not an address: ${escrow}`);

  const privateKey = required("AGENT_PRIVATE_KEY");
  if (!/^0x[0-9a-fA-F]{64}$/.test(privateKey)) {
    // Never echo the value -- this runs in a terminal that may be on a projector.
    throw new ConfigError("AGENT_PRIVATE_KEY must be a 0x-prefixed 32-byte hex string.");
  }

  return {
    rpcUrl: required("RPC_URL"),
    escrow,
    privateKey: privateKey as Hex,
    // Only jobs still INSIDE their delivery window are actionable -- anything
    // older has already passed its deadline and `submitWork` would revert. The
    // window is 10 blocks, so 30 is generous slack for a slow restart and
    // nothing beyond that is worth fetching. The old default of 5000 was
    // arbitrary, and on providers that cap getLogs ranges it was also fatal.
    lookbackBlocks: BigInt(process.env.LOOKBACK_BLOCKS ?? "30"),
    // Alchemy's free tier refuses eth_getLogs spanning more than 10 blocks.
    // Scanning in windows keeps the agent portable across providers.
    logWindowBlocks: BigInt(process.env.LOG_WINDOW_BLOCKS ?? "10"),
    pollingIntervalMs: Number(process.env.POLLING_INTERVAL_MS ?? "4000"),
  };
}

/**
 * Chains are resolved from the id the RPC reports, not from config, so a
 * mismatched CHAIN_ID cannot exist to be wrong. Unknown ids get a minimal
 * synthetic chain -- viem needs one to sign, but nothing here depends on the
 * metadata.
 */
export function resolveChain(chainId: number) {
  if (chainId === sepolia.id) return sepolia;
  if (chainId === anvil.id) return anvil;

  return {
    id: chainId,
    name: `chain-${chainId}`,
    nativeCurrency: { name: "Ether", symbol: "ETH", decimals: 18 },
    rpcUrls: { default: { http: [] } },
  } as const;
}
