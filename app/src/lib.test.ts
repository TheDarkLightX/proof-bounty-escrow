import { describe, expect, it } from "vitest";
import {
  assertAttestationReady,
  computeSolverCommitment,
  dateTimeLocalToSeconds,
  explainBountyStatus,
  hashExactBytes,
  hashExactText,
  normalizeManifest,
  parseSolverRecoveryPackage,
  requireBytes32,
  requireNonzeroBytes32,
  requireSignature,
  suggestedVerifierFee,
} from "./lib";

describe("content hashing", () => {
  it("hashes exact UTF-8 bytes deterministically", () => {
    expect(hashExactText("hello")).toBe("0x1c8aff950685c2ed4bc3174f3472287b56d9517b9c948127319a09a7a36deac8");
    expect(hashExactBytes(new TextEncoder().encode("hello"))).toBe(hashExactText("hello"));
  });
});

describe("strict wire values", () => {
  it("accepts exact bytes32 and rejects ambiguous values", () => {
    expect(requireBytes32(`0x${"12".repeat(32)}`, "Hash")).toBe(`0x${"12".repeat(32)}`);
    expect(() => requireBytes32("ipfs://cid", "Hash")).toThrow(/32 bytes/);
    expect(() => requireNonzeroBytes32(`0x${"00".repeat(32)}`, "Hash")).toThrow(/cannot be zero/);
  });

  it("requires the signature format accepted by the escrow", () => {
    expect(requireSignature(`0x${"ab".repeat(65)}`, "Signature")).toHaveLength(132);
    expect(() => requireSignature(`0x${"ab".repeat(64)}`, "Signature")).toThrow(/65-byte/);
  });
});

describe("phase boundaries", () => {
  it("uses the contract's half-open intervals", () => {
    expect(explainBountyStatus(1, 10n, 20n, 9n)).toContain("commit");
    expect(explainBountyStatus(1, 10n, 20n, 10n)).toContain("claim");
    expect(explainBountyStatus(1, 10n, 20n, 20n)).toContain("refundable");
  });

  it("refuses attestation preparation outside the claim window or without the exact commitment", () => {
    const commitment = `0x${"12".repeat(32)}` as const;
    expect(() => assertAttestationReady(1, 10n, 20n, 9n, commitment, commitment)).toThrow(/still open/);
    expect(() => assertAttestationReady(1, 10n, 20n, 20n, commitment, commitment)).toThrow(/passed/);
    expect(() => assertAttestationReady(1, 10n, 20n, 10n, `0x${"34".repeat(32)}`, commitment)).toThrow(/not stored/);
    expect(() => assertAttestationReady(1, 10n, 20n, 10n, commitment, commitment)).not.toThrow();
  });
});

describe("solver commitment", () => {
  it("matches the Solidity abi.encode domain construction", () => {
    expect(computeSolverCommitment(
      `0x${"11".repeat(32)}`,
      7n,
      "0x0000000000000000000000000000000000001234",
      `0x${"22".repeat(32)}`,
      `0x${"33".repeat(32)}`,
    )).toBe("0xa037a14e13f9e85f5bfef1710328a07e197bb324d9340987cf57a269e680d91b");
  });

  it("strictly validates and deployment-binds solver recovery packages", () => {
    const deploymentId = `0x${"11".repeat(32)}` as const;
    const escrow = "0x0000000000000000000000000000000000001234" as const;
    const solver = "0x0000000000000000000000000000000000005678" as const;
    const resultDigest = `0x${"22".repeat(32)}` as const;
    const salt = `0x${"33".repeat(32)}` as const;
    const commitment = computeSolverCommitment(deploymentId, 7n, solver, resultDigest, salt);
    const recovery = {
      schema: "proof-bounty-solver-recovery/v1",
      chainId: 943,
      escrow,
      deploymentId,
      claim: { bountyId: "7", solver, resultDigest, salt },
      commitment,
    };
    expect(parseSolverRecoveryPackage(recovery, 943, escrow, deploymentId).claim.bountyId).toBe("7");
    expect(() => parseSolverRecoveryPackage({ ...recovery, extra: true }, 943, escrow, deploymentId)).toThrow(/fields/);
    expect(() => parseSolverRecoveryPackage({ ...recovery, chainId: 369 }, 943, escrow, deploymentId)).toThrow(/chain/);
    expect(() => parseSolverRecoveryPackage({ ...recovery, commitment: `0x${"44".repeat(32)}` }, 943, escrow, deploymentId)).toThrow(/commitment/);
    expect(() => parseSolverRecoveryPackage({ ...recovery, claim: { ...recovery.claim, bountyId: "07" } }, 943, escrow, deploymentId)).toThrow(/canonical/);
  });
});

describe("verifier-pool suggestion", () => {
  it("suggests 5%, rounded up, and clamps to the contract range", () => {
    expect(suggestedVerifierFee(10_000n, 50n, 10_000n)).toBe(500n);
    expect(suggestedVerifierFee(101n, 1n, 101n)).toBe(6n);
    expect(suggestedVerifierFee(100n, 10n, 100n)).toBe(10n);
    expect(suggestedVerifierFee(10_000n, 50n, 400n)).toBe(400n);
    expect(suggestedVerifierFee(2n, 2n, 2n)).toBe(2n);
  });
});

describe("deployment manifests", () => {
  it("normalizes the repository manifest format", () => {
    const [choice] = normalizeManifest({
      schemaVersion: 1,
      deployment: {
        network: "Test",
        chainId: 943,
        variant: "native",
        contractAddress: "0x0000000000000000000000000000000000000001",
        runtimeCodeHash: `0x${"11".repeat(32)}`,
      },
      configuration: {
        protocolName: "Proof Bounty",
        asset: "0x0000000000000000000000000000000000000000",
      },
    });
    expect(choice?.config.chainId).toBe(943);
    expect(choice?.config.variant).toBe("native");
    expect(choice?.expected.runtimeCodeHash).toBe(`0x${"11".repeat(32)}`);
    expect(choice?.expected.asset).toBe("0x0000000000000000000000000000000000000000");
  });
});

describe("date parsing", () => {
  it("converts a valid datetime to integer seconds", () => {
    expect(dateTimeLocalToSeconds("2030-01-01T00:00", "Deadline") > 0n).toBe(true);
  });
});
