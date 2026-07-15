import type { Address, Hex } from "viem";

export type Variant = "native" | "erc20";

export interface AppConfig {
  networkName: string;
  chainId: number;
  rpcUrl: string;
  contractAddress: Address;
  variant: Variant;
  nativeSymbol: string;
  assetSymbol: string;
  assetDecimals: number;
  protocolName: string;
}

export interface DeploymentChoice {
  label: string;
  config: Partial<AppConfig> & Pick<AppConfig, "chainId" | "contractAddress" | "variant">;
  expected: {
    runtimeCodeHash?: Hex;
    asset?: Address;
    deploymentId?: Hex;
    verifierSetHash?: Hex;
    devCo?: Address;
    securityReserve?: Address;
    verifiers?: Address[];
    protocolName?: string;
  };
}

export interface DeploymentManifest {
  schemaVersion: 1;
  deployment: {
    network: string;
    chainId: number;
    variant: Variant;
    contractAddress: Address;
  };
  configuration: {
    protocolName: string;
    asset: Address;
    [key: string]: unknown;
  };
  [key: string]: unknown;
}

export interface BountyView {
  sponsor: Address;
  refundRecipient: Address;
  winner: Address;
  reward: bigint;
  verifierFee: bigint;
  fundedAmount: bigint;
  commitDeadline: bigint;
  claimDeadline: bigint;
  status: number;
  profileId: Hex;
  specificationHash: Hex;
  termsHash: Hex;
  resultDigest: Hex;
}

export interface SolverRecoveryPackage {
  schema: "proof-bounty-solver-recovery/v1";
  chainId: number;
  escrow: Address;
  deploymentId: Hex;
  claim: {
    bountyId: string;
    solver: Address;
    resultDigest: Hex;
    salt: Hex;
  };
  commitment: Hex;
}

export interface EthereumProvider {
  request(args: { method: string; params?: unknown[] | object }): Promise<unknown>;
  on?(event: string, listener: (...args: unknown[]) => void): void;
  removeListener?(event: string, listener: (...args: unknown[]) => void): void;
}

declare global {
  interface Window {
    ethereum?: EthereumProvider;
  }
}
