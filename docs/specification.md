# Protocol specification

## 1. Scope and terminology

This document describes the implemented V1 Solidity contracts. “Must” describes behavior enforced by the current contracts. Recommendations for clients, verifiers, and operators are explicitly identified as off-chain requirements.

The protocol escrows payment for an objectively evaluable result. The contract does not evaluate the result itself. Instead, it freezes hashes identifying the evaluation profile, specification, and terms, then requires EIP-712 attestations from two members of an immutable three-address verifier set.

Roles are:

- **Sponsor:** creates and funds a bounty.
- **Refund recipient:** immutable address credited if an open bounty expires.
- **Solver:** records a commitment and may receive the reward.
- **Verifier:** one of three immutable addresses authorized to attest to an accepted result. Exactly two distinct verifier indices are required.
- **Relayer:** any account that submits a valid claim or triggers a refund. A relayer never becomes the payee merely by submitting the transaction.
- **DevCo:** immutable recipient of the successful-settlement development fee.
- **Security reserve:** immutable recipient of the successful-settlement reserve fee and verifier-division remainder.

## 2. Deployment configuration

Two concrete adapters exist:

- `ProofBountyEscrowNative(protocolName, devCo, securityReserve, verifiers)` uses native currency and exposes `asset == address(0)`.
- `ProofBountyEscrowERC20(protocolName, token, devCo, securityReserve, verifiers)` uses one immutable ERC-20 and exposes both `asset` and `token` as that address.

The constructor enforces:

- `protocolName` contains 1 through 64 bytes;
- DevCo and the security reserve are nonzero, distinct, and not the escrow itself;
- there are exactly three nonzero, distinct verifier addresses;
- verifier addresses are supplied in strictly increasing numeric-address order; and
- no verifier address equals the escrow, DevCo, or the security reserve; and
- every verifier address has zero code at the instant of construction.

Verifier acceptance is ECDSA-only. ERC-1271 validation is not implemented. The deployment-time
code check rejects an already-deployed contract but does not prove permanent EOA status: an address
can gain delegated or later-deployed code. Operations must use addresses whose ECDSA private keys
are securely and independently controlled.

The following values are immutable or constant:

- protocol version `"1"`;
- protocol ID `keccak256("proof-bounty-escrow/v1")`;
- asset, DevCo, security reserve, verifier addresses, verifier-set hash, and deployment ID;
- verifier count `3` and threshold `2`;
- fee rates; and
- maximum bounty duration of `366 days` from creation to claim deadline.

There is no administrative role and no upgrade path.

### 2.1 Domain separation

`deploymentId` is computed at construction from:

```text
keccak256(abi.encode(
  PROTOCOL_ID,
  keccak256(bytes(protocolName)),
  chainId,
  contractAddress,
  asset,
  devCo,
  securityReserve,
  verifierSetHash
))
```

`verifierSetHash` is `keccak256(abi.encode(verifiers, 2))`.

Verifier attestations use an EIP-712 domain with the configured protocol name, version `"1"`,
current chain ID, and verifying contract. The deployment ID is also included in both commitments
and attestations. Signatures and commitments therefore cannot be reused across different contract
addresses, assets, authority configurations, or chain IDs under the modeled EVM rules. A fork or
state clone that preserves both chain ID and deployment address is not separated by these fields;
verifiers must apply a finalized-chain policy.

## 3. Bounty creation

A `BountyRequest` contains:

```solidity
address refundRecipient;
uint256 reward;
uint256 verifierFee;
uint64 commitDeadline;
uint64 claimDeadline;
bytes32 profileId;
bytes32 specificationHash;
bytes32 termsHash;
```

Creation requires:

- nonzero refund recipient that is not the escrow itself;
- reward of at least two smallest asset units;
- `max(2, floor(reward * 50 / 10_000)) <= verifierFee <= reward`;
- nonzero profile, specification, and terms hashes;
- `commitDeadline > block.timestamp`;
- `claimDeadline > commitDeadline`; and
- `claimDeadline <= block.timestamp + 366 days`.

The sponsor is `msg.sender`. The contract assigns the next monotonically increasing bounty ID, starting at 1, and freezes the request values. There is no edit, extension, cancellation, top-up, or sponsor approval step after creation.

For reward `R` and sponsor-declared verifier pool `V`, funding is:

```text
devFee      = floor(R * 200 / 10_000)
verifierFee = V, where max(2, floor(R * 50 / 10_000)) <= V <= R
securityFee = floor(R *  50 / 10_000)
funded      = R + devFee + verifierFee + securityFee
```

The minimum nominal surcharge is 3%; actual surcharge is the fixed 2.5% plus the chosen pool as a
percentage of reward. The contract bounds but does not determine an economically adequate price.
Profiles should state expected verification effort and a recommended pool. Percentage-derived
components round down independently in the asset's smallest unit.

Native creation must send exactly `funded` as `msg.value`. Ordinary native transfers to `receive` or `fallback` revert. The ERC-20 adapter transfers exactly `funded` with `SafeERC20` and verifies that its balance increased by exactly that amount before recording the bounty.

## 4. Commit phase

While a bounty is `Open` and `block.timestamp < commitDeadline`, any account may call:

```solidity
commit(uint256 bountyId, bytes32 commitment)
```

The commitment must be nonzero. It is stored under `(bountyId, msg.sender)`. Each solver has an independent slot and may replace its commitment any number of times until the boundary. One solver's commitment does not block another solver.

The canonical commitment for a prospective claim is:

```text
keccak256(abi.encode(
  COMMITMENT_TYPEHASH,
  deploymentId,
  bountyId,
  solver,
  resultDigest,
  salt
))
```

where:

```text
COMMITMENT_TYPEHASH = keccak256(
  "SolverCommitment(bytes32 deploymentId,uint256 bountyId,address solver,bytes32 resultDigest,bytes32 salt)"
)
```

The contract exposes `computeCommitment` as a public cross-check, but privacy-conscious clients
must duplicate this small canonical encoding and hash it locally. Calling the view helper through
an RPC discloses the result digest and salt before reveal and lets a dishonest RPC return a false
commitment. Clients should use a cryptographically random, single-use salt and should not publish
the salt before claiming.

At `block.timestamp == commitDeadline`, new and replacement commitments are closed.

## 5. Claim phase

A claim is available only while the bounty is `Open` and:

```text
commitDeadline <= block.timestamp < claimDeadline
```

Anyone may submit:

```solidity
claim(Claim result, VerifierSignature[2] signatures)
```

The claim binds:

- bounty ID;
- nonzero solver address;
- nonzero result digest;
- nonzero salt; and
- exactly two verifier signatures.

An address in the immutable verifier set may not be the solver. The stored commitment for that bounty and solver must equal the canonical commitment recomputed from all claim fields.

The two verifier indices must be strictly increasing and both less than three. This simultaneously enforces distinct signers and canonical ordering. Each signature must recover to the verifier address at its supplied index.

### 5.1 Accepted-result attestation

The EIP-712 struct is:

```text
AcceptedResult(
  bytes32 deploymentId,
  uint256 bountyId,
  address solver,
  bytes32 commitment,
  bytes32 resultDigest,
  uint256 reward,
  uint256 verifierFee,
  bytes32 profileId,
  bytes32 specificationHash,
  bytes32 termsHash,
  bytes32 verifierSetHash,
  uint64 claimDeadline
)
```

The salt is bound transitively through `commitment`. The profile, specification, terms, verifier
set, deployment, solver, result, reward, verifier pool, bounty, and deadline are all signed.

The contract does not prove that a verifier actually ran an evaluator. A signature means only that the corresponding verifier key accepted this exact typed record. Verifier software must independently fetch the frozen content, reproduce the declared evaluator, verify the stored solver commitment, and enforce its signing policy.

### 5.2 Successful settlement

The first valid claim changes the bounty from `Open` to `Paid`, records the winner and result digest, and deletes the winning solver's commitment. Later claims and refunds revert because the bounty is terminal.

Settlement creates pull-payment credits:

- solver: full advertised reward;
- DevCo: `devFee`;
- each of the two actual signing verifiers: `floor(verifierFee / 2)`; and
- security reserve: `securityFee + verifierFee mod 2`.

No asset transfer occurs during claim. Losing solvers' commitments may remain in storage but have no effect after settlement.

## 6. Expiry and refund

At `block.timestamp >= claimDeadline`, anyone may call `refund(bountyId)` if the bounty is still `Open`.

The bounty becomes `Refunded`, and the immutable refund recipient receives a pull credit for the entire `fundedAmount`: reward plus every proposed fee. No party earns a fee on an expired bounty. Claim and refund windows are half-open and never overlap.

## 7. Withdrawal and accounting

An account with credit may call:

```solidity
withdraw(address destination, uint256 amount)
```

The caller chooses a nonzero destination other than the escrow itself and any positive amount no
greater than its credit. Effects are applied before the adapter sends assets, and the function is
non-reentrant. A failed transfer reverts the entire withdrawal, restoring the credit.

The ERC-20 adapter additionally checks exact decreases and increases in the escrow and destination
balances. This excludes fee-on-transfer and other non-exact behavior from the supported token
profile.

Global accounting is:

```text
accountedBalance = totalEscrowed + totalClaimable
isSolvent        = actualAssetBalance >= accountedBalance
surplus          = max(actualAssetBalance - accountedBalance, 0)
```

Withdrawals are observable through `Withdrawal` events. The contract deliberately keeps no
unbounded cumulative-withdrawal counter in the settlement path: such telemetry could eventually
overflow after enough independent funding cycles and must never become a liveness dependency.

Native currency forced into the contract and tokens transferred directly to it become surplus. V1 deliberately provides no sweep or rescue function, so surplus can be permanently stranded.

## 8. State machine

```text
None --create--> Open --first valid 2-of-3 claim--> Paid
                  |
                  `--expiry refund----------------> Refunded
```

`Paid` and `Refunded` are terminal. There is exactly one settlement path per bounty.

## 9. Opaque off-chain identifiers

`profileId`, `specificationHash`, `termsHash`, and `resultDigest` are nonzero `bytes32` values but
otherwise opaque to the contract. The checked-in package schemas prescribe a V1 client convention:
hash the exact referenced artifact bytes with Keccak-256 and place the resulting `bytes32` on chain.
The contract itself neither enforces that convention nor parses storage locations, URIs, schemas,
or evaluator runtimes.

A production client must define all of those off chain. At minimum, a bounty package should freeze:

- canonical byte serialization and hash algorithm;
- evaluator source and immutable version or content hash;
- input format, output format, and deterministic success predicate;
- resource bounds and environmental assumptions;
- how result bytes map to `resultDigest`;
- availability locations and mirrors; and
- verifier reproduction instructions.

An IPFS CID can be included in the hashed package, but the contract stores only the resulting `bytes32`. A CID or URL is not natively parsed.

## 10. Deliberate non-features

V1 does not implement:

- a protocol token or token sale;
- subjective arbitration or on-chain result evaluation;
- zero-knowledge proof verification;
- sponsor cancellation, approval, or deadline extension;
- owner, governance, pause, upgrade, or verifier rotation;
- milestone, partial, or multi-winner payments;
- solver identity, reputation, discovery, or messaging;
- cross-chain messaging, bridging, or shared liquidity;
- ERC-1271 verifier signatures;
- recovery of surplus or mistakenly sent assets; or
- an indexer, verifier daemon, or IPFS publishing pipeline.

These omissions reduce V1's authority and attack surface, but they also create operational limitations described in the threat model.
