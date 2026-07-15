import { describe, expect, it } from "vitest";
import { hashTypedData } from "viem";
import { acceptedResultTypes, escrowAbi } from "./abi";

interface AbiItem {
  name?: string;
  inputs?: readonly { name: string; type: string; components?: readonly { name: string; type: string }[] }[];
  outputs?: readonly { name: string; type: string; components?: readonly { name: string; type: string }[] }[];
}

function functionItem(name: string): AbiItem {
  const item = (escrowAbi as readonly AbiItem[]).find((candidate) => candidate.name === name);
  if (!item) throw new Error(`Missing ABI function ${name}`);
  return item;
}

describe("absolute verifier-pool ABI", () => {
  it("binds the exact BountyRequest tuple order", () => {
    const request = functionItem("createBounty").inputs?.[0]?.components;
    expect(request?.map((field) => `${field.type} ${field.name}`)).toEqual([
      "address refundRecipient",
      "uint256 reward",
      "uint256 verifierFee",
      "uint64 commitDeadline",
      "uint64 claimDeadline",
      "bytes32 profileId",
      "bytes32 specificationHash",
      "bytes32 termsHash",
    ]);
  });

  it("decodes verifierFee immediately after reward in Bounty", () => {
    const bounty = functionItem("getBounty").outputs?.[0]?.components;
    expect(bounty?.map((field) => field.name).slice(0, 7)).toEqual([
      "sponsor",
      "refundRecipient",
      "winner",
      "reward",
      "verifierFee",
      "fundedAmount",
      "commitDeadline",
    ]);
  });

  it("uses the exact funding helpers and verifier-signed economics order", () => {
    expect(functionItem("requiredFunding").inputs?.map((field) => field.name)).toEqual(["reward", "verifierFee"]);
    expect(functionItem("minimumVerifierFee").inputs?.[0]?.name).toBe("reward");
    expect(functionItem("maximumVerifierFee").inputs?.[0]?.name).toBe("reward");
    expect(acceptedResultTypes.AcceptedResult.map((field) => field.name)).toEqual([
      "deploymentId",
      "bountyId",
      "solver",
      "commitment",
      "resultDigest",
      "reward",
      "verifierFee",
      "profileId",
      "specificationHash",
      "termsHash",
      "verifierSetHash",
      "claimDeadline",
    ]);
  });

  it("matches an independently cast-derived AcceptedResult digest vector", () => {
    const digest = hashTypedData({
      domain: {
        name: "Proof Bounties",
        version: "1",
        chainId: 943,
        verifyingContract: "0x000000000000000000000000000000000000beef",
      },
      types: acceptedResultTypes,
      primaryType: "AcceptedResult",
      message: {
        deploymentId: `0x${"11".repeat(32)}`,
        bountyId: 7n,
        solver: "0x0000000000000000000000000000000000001234",
        commitment: `0x${"22".repeat(32)}`,
        resultDigest: `0x${"33".repeat(32)}`,
        reward: 1_000_000n,
        verifierFee: 50_000n,
        profileId: `0x${"44".repeat(32)}`,
        specificationHash: `0x${"55".repeat(32)}`,
        termsHash: `0x${"66".repeat(32)}`,
        verifierSetHash: `0x${"77".repeat(32)}`,
        claimDeadline: 2_000_000_000n,
      },
    });
    expect(digest).toBe("0x719c144c2af2972c2f7610692b77b186dce075a490220012de2944fe648232db");
  });
});
