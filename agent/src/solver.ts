import { decodeAbiParameters, encodeAbiParameters, type Hex } from "viem";

/**
 * The offchain mirror of `IVerifier`.
 *
 * The escrow delegates "is this result correct?" to a swappable verifier
 * contract; the agent delegates "what IS the result?" to a swappable solver.
 * Those two halves have to agree on an encoding, and nothing enforces that
 * agreement at compile time -- so a solver is written next to the verifier it
 * answers, and says so.
 *
 * `solve` returns null rather than throwing when it does not recognise a spec.
 * A job it cannot answer is not an error: it is a job for a different solver,
 * or one that belongs on the optimistic path where a human supplies the result.
 */
export type Solver = {
  readonly name: string;
  /** The verifier this solver answers. Documentation, not a runtime check. */
  readonly verifier: string;
  solve(jobSpec: Hex): SolvedJob | null;
};

export type SolvedJob = {
  /** ABI-encoded, ready to pass to `submitWork`. */
  result: Hex;
  /** Human-readable, for the demo log. */
  describe: string;
};

/** Matches SumVerifier: spec is abi.encode(uint256 a, uint256 b). */
const SPEC_PARAMS = [{ type: "uint256" }, { type: "uint256" }] as const;
const RESULT_PARAMS = [{ type: "uint256" }] as const;

/** SumVerifier caps operands so `a + b` cannot overflow a uint256. */
const MAX_OPERAND = (1n << 128n) - 1n;

export const sumSolver: Solver = {
  name: "sum",
  verifier: "SumVerifier",

  solve(jobSpec: Hex): SolvedJob | null {
    let a: bigint;
    let b: bigint;

    try {
      [a, b] = decodeAbiParameters(SPEC_PARAMS, jobSpec);
    } catch {
      // Not a two-uint256 spec. Someone else's job.
      return null;
    }

    // The escrow already rejected out-of-range operands at redeem time via
    // isValidSpec, so this should be unreachable. It is here because the agent
    // must not be the component that assumes the chain validated something:
    // submitting a result the verifier will reject silently drops the job onto
    // the optimistic path, where it costs the agent an acceptance window.
    if (a > MAX_OPERAND || b > MAX_OPERAND) return null;

    return {
      result: encodeAbiParameters(RESULT_PARAMS, [a + b]),
      describe: `${a} + ${b} = ${a + b}`,
    };
  },
};
