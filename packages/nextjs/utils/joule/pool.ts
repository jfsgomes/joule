import { type Address, type Hex, encodeAbiParameters, keccak256, zeroAddress } from "viem";

/**
 * The JOULE/USDC v4 pool, as the frontend needs to see it.
 *
 * These constants must match `packages/foundry/script/JouleAddresses.sol`. They
 * are duplicated rather than imported because the Solidity side is not a
 * TypeScript module, and a mismatch shows up immediately as a pool id that
 * resolves to nothing.
 */
export const POOL_FEE = 3000;
export const TICK_SPACING = 60;

/** Prices in USDC per whole Joule. The seed pins both ranges to the opening tick. */
export const SPOT_PRICE = 4.9;
export const SELL_HIGH = 6.0;
export const BID_LOW = 4.0;

/** Verified onchain in Milestone 0; see PLAN.md. */
export const STATE_VIEW: Address = "0xE1Dd9c3fA50EDB962E442f60DfBc432e24537E4C";

export const stateViewAbi = [
  {
    type: "function",
    name: "getSlot0",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [
      { name: "sqrtPriceX96", type: "uint160" },
      { name: "tick", type: "int24" },
      { name: "protocolFee", type: "uint24" },
      { name: "lpFee", type: "uint24" },
    ],
  },
  {
    type: "function",
    name: "getLiquidity",
    stateMutability: "view",
    inputs: [{ name: "poolId", type: "bytes32" }],
    outputs: [{ name: "liquidity", type: "uint128" }],
  },
] as const;

/**
 * PoolId is keccak256 of the ABI-encoded PoolKey.
 *
 * Token order is decided by address comparison, never by us — JouleToken is
 * created inside WorkEscrow's constructor, so which side of the pool it lands
 * on is not ours to choose. Get this backwards and the id resolves to a pool
 * that does not exist.
 */
export function computePoolId(joule: Address, usdc: Address): Hex {
  const [currency0, currency1] = joule.toLowerCase() < usdc.toLowerCase() ? [joule, usdc] : [usdc, joule];

  return keccak256(
    encodeAbiParameters(
      [{ type: "address" }, { type: "address" }, { type: "uint24" }, { type: "int24" }, { type: "address" }],
      [currency0, currency1, POOL_FEE, TICK_SPACING, zeroAddress],
    ),
  );
}

export const jouleIsToken0 = (joule: Address, usdc: Address) => joule.toLowerCase() < usdc.toLowerCase();

/**
 * USDC per whole Joule, from the pool's sqrt price.
 *
 * A Uniswap price is a ratio of RAW units, so the 18-vs-6 decimal gap has to
 * be reapplied by hand. And the ratio itself inverts with token order: when
 * JOULE is token1 the pool quotes Joules per USDC, and reading it the other
 * way gives a number roughly 1e-12 off — wrong in a way that still looks like
 * a plausible price.
 */
export function priceFromSqrtX96(sqrtPriceX96: bigint, isToken0: boolean): number {
  const sqrt = Number(sqrtPriceX96) / 2 ** 96;
  const raw = sqrt * sqrt; // raw token1 per raw token0
  const scale = 1e18 / 1e6; // Joule decimals over USDC decimals
  return isToken0 ? raw * scale : scale / raw;
}
