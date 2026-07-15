import {
  encodeAbiParameters,
  getAddress,
  isAddress,
  isHex,
  keccak256,
  parseAbiParameters,
  stringToHex,
  type Address,
  type Hex,
} from "viem";
import type { AppConfig, DeploymentChoice, DeploymentManifest } from "./types";

export const ZERO_ADDRESS = "0x0000000000000000000000000000000000000000" as Address;
export const ZERO_HASH = `0x${"0".repeat(64)}` as Hex;
export const BYTES32_PATTERN = /^0x[0-9a-fA-F]{64}$/;
export const SIGNATURE_PATTERN = /^0x[0-9a-fA-F]{130}$/;
export const COMMITMENT_TYPEHASH = keccak256(
  stringToHex("SolverCommitment(bytes32 deploymentId,uint256 bountyId,address solver,bytes32 resultDigest,bytes32 salt)"),
);
const commitmentParameters = parseAbiParameters("bytes32, bytes32, uint256, address, bytes32, bytes32");

export function requireAddress(value: string, label: string): Address {
  if (!isAddress(value, { strict: false })) throw new Error(`${label} is not a valid EVM address.`);
  return getAddress(value);
}

export function requireBytes32(value: string, label: string): Hex {
  if (!BYTES32_PATTERN.test(value)) throw new Error(`${label} must be exactly 32 bytes (0x + 64 hex characters).`);
  return value.toLowerCase() as Hex;
}

export function requireNonzeroBytes32(value: string, label: string): Hex {
  const parsed = requireBytes32(value, label);
  if (parsed === ZERO_HASH) throw new Error(`${label} cannot be zero.`);
  return parsed;
}

export function requireSignature(value: string, label: string): Hex {
  if (!SIGNATURE_PATTERN.test(value)) {
    throw new Error(`${label} must be a 65-byte ECDSA signature (0x + 130 hex characters).`);
  }
  return value as Hex;
}

export function requirePositiveInteger(value: string, label: string): bigint {
  if (!/^[0-9]+$/.test(value)) throw new Error(`${label} must be a positive integer.`);
  const parsed = BigInt(value);
  if (parsed <= 0n) throw new Error(`${label} must be greater than zero.`);
  return parsed;
}

export function hashExactText(value: string): Hex {
  return keccak256(stringToHex(value));
}

export function hashExactBytes(value: Uint8Array): Hex {
  return keccak256(`0x${Array.from(value, (byte) => byte.toString(16).padStart(2, "0")).join("")}`);
}

export function randomSalt(): Hex {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return `0x${Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("")}`;
}

export function suggestedVerifierFee(reward: bigint, minimum: bigint, maximum: bigint): bigint {
  const fivePercentRoundedUp = (reward * 500n + 9_999n) / 10_000n;
  if (fivePercentRoundedUp < minimum) return minimum;
  if (fivePercentRoundedUp > maximum) return maximum;
  return fivePercentRoundedUp;
}

export function computeSolverCommitment(
  deploymentId: Hex,
  bountyId: bigint,
  solver: Address,
  resultDigest: Hex,
  salt: Hex,
): Hex {
  return keccak256(
    encodeAbiParameters(commitmentParameters, [COMMITMENT_TYPEHASH, deploymentId, bountyId, solver, resultDigest, salt]),
  );
}

export function assertAttestationReady(
  status: number,
  commitDeadline: bigint,
  claimDeadline: bigint,
  blockTimestamp: bigint,
  storedCommitment: Hex,
  expectedCommitment: Hex,
): void {
  if (status !== 1) throw new Error("Bounty is not open.");
  if (blockTimestamp < commitDeadline) throw new Error("Commit phase is still open. Result data must remain private.");
  if (blockTimestamp >= claimDeadline) throw new Error("Claim deadline has passed.");
  if (storedCommitment === ZERO_HASH || storedCommitment.toLowerCase() !== expectedCommitment.toLowerCase()) {
    throw new Error("The exact solver commitment is not stored on-chain.");
  }
}

export function dateTimeLocalToSeconds(value: string, label: string): bigint {
  const milliseconds = Date.parse(value);
  if (!Number.isFinite(milliseconds)) throw new Error(`${label} is not a valid date and time.`);
  return BigInt(Math.floor(milliseconds / 1000));
}

export function secondsToDateTimeLocal(seconds: number): string {
  const date = new Date(seconds * 1000);
  const local = new Date(date.getTime() - date.getTimezoneOffset() * 60_000);
  return local.toISOString().slice(0, 16);
}

export function formatTimestamp(seconds: bigint): string {
  if (seconds === 0n) return "—";
  return new Date(Number(seconds) * 1000).toLocaleString();
}

export function shortHex(value: string, left = 8, right = 6): string {
  if (value.length <= left + right + 1) return value;
  return `${value.slice(0, left)}…${value.slice(-right)}`;
}

export function explainBountyStatus(status: number, commitDeadline: bigint, claimDeadline: bigint, now: bigint): string {
  if (status === 0) return "Not found";
  if (status === 2) return "Paid";
  if (status === 3) return "Refunded";
  if (status !== 1) return `Unknown (${status})`;
  if (now < commitDeadline) return "Open · commit phase";
  if (now < claimDeadline) return "Open · claim phase";
  return "Open · refundable";
}

export function normalizeManifest(raw: unknown): DeploymentChoice[] {
  const candidates: unknown[] = [];
  if (Array.isArray(raw)) candidates.push(...raw);
  else if (isRecord(raw) && Array.isArray(raw.deployments)) candidates.push(...raw.deployments);
  else candidates.push(raw);

  return candidates.map((candidate, index) => {
    if (!isRecord(candidate) || !isRecord(candidate.deployment)) {
      throw new Error(`Deployment entry ${index + 1} is missing a deployment object.`);
    }
    const deployment = candidate.deployment;
    const configuration = isRecord(candidate.configuration) ? candidate.configuration : {};
    const chainId = Number(deployment.chainId);
    if (!Number.isSafeInteger(chainId) || chainId <= 0) throw new Error(`Deployment entry ${index + 1} has an invalid chainId.`);
    const variant = deployment.variant;
    if (variant !== "native" && variant !== "erc20") throw new Error(`Deployment entry ${index + 1} has an invalid variant.`);
    const contractAddress = requireAddress(String(deployment.contractAddress ?? ""), "Contract address");
    const networkName = String(deployment.network ?? `Chain ${chainId}`);
    const protocolName = typeof configuration.protocolName === "string" ? configuration.protocolName : "";
    const verifiers = Array.isArray(configuration.verifiers)
      ? configuration.verifiers.map((value, verifierIndex) => requireAddress(String(value), `Verifier ${verifierIndex}`))
      : undefined;
    return {
      label: `${networkName} · ${variant} · ${shortHex(contractAddress)}`,
      config: { chainId, contractAddress, variant, networkName, protocolName },
      expected: {
        runtimeCodeHash: optionalHash(deployment.runtimeCodeHash, "Runtime code hash"),
        asset: optionalAddress(configuration.asset, "Asset"),
        deploymentId: optionalHash(configuration.deploymentId, "Deployment ID"),
        verifierSetHash: optionalHash(configuration.verifierSetHash, "Verifier set hash"),
        devCo: optionalAddress(configuration.devCo, "Developer recipient"),
        securityReserve: optionalAddress(configuration.securityReserve, "Security reserve"),
        verifiers,
        protocolName: protocolName || undefined,
      },
    };
  });
}

function optionalAddress(value: unknown, label: string): Address | undefined {
  return value === undefined ? undefined : requireAddress(String(value), label);
}

function optionalHash(value: unknown, label: string): Hex | undefined {
  return value === undefined ? undefined : requireBytes32(String(value), label);
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isHexValue(value: unknown): value is Hex {
  return typeof value === "string" && isHex(value);
}

export function safeJson(value: unknown): string {
  return JSON.stringify(
    value,
    (_key, item: unknown) => (typeof item === "bigint" ? item.toString() : item),
    2,
  );
}

export function downloadJson(filename: string, value: unknown): void {
  const blob = new Blob([safeJson(value)], { type: "application/json" });
  const url = URL.createObjectURL(blob);
  const anchor = document.createElement("a");
  anchor.href = url;
  anchor.download = filename;
  anchor.rel = "noreferrer";
  anchor.click();
  URL.revokeObjectURL(url);
}

export function copyConfig(config: AppConfig, patch: Partial<AppConfig>): AppConfig {
  return { ...config, ...patch };
}

export type { DeploymentManifest };
