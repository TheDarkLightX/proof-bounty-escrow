# Keyless ZK settlement design

> **Status: normative design and proof-obligation draft; not implemented.** This document is the
> target for a new contract, model, circuit/guest program, and audit. The current V1 contract still
> settles with two signatures from three fixed addresses. It must not be represented as ZK-verified
> or as the final PulseTensor verifier architecture.

## 1. Decision

Objective jobs should settle from a machine-verifiable proof, not from permanent secret signing
keys. The immutable objects should be public code and cryptographic commitments:

- the proof-system verifier bytecode and runtime code hash;
- the evaluator program image, circuit, or verification-key hash;
- the exact public-input encoding and semantic version;
- the specification, terms, and result digests; and
- the job economics and deadlines.

No secret key should have authority to declare an objective result correct. A new evaluator or
proof-system version receives a new public identifier and, where required, a new escrow deployment.
It does not silently replace the verifier for an active job.

The V1 fixed 2-of-3 design is a bounded attestation fallback. Immutability removed an owner and
key-rotation backdoor, but it also made compromise and unavailability permanent: two compromised
keys can authorize a false result, two unavailable keys can prevent every valid result, and one
compromised key permanently reduces the threshold. Redeployment is its only recovery mechanism.
That is unsuitable as the long-lived trust root of a high-assurance marketplace.

## 2. What a ZK proof does and does not prove

A sound proof can establish that a precisely identified evaluator accepted committed inputs under
a precisely identified machine model. It does not establish that:

- the encoded specification matches a sponsor's unstated intent;
- an oracle or source datum was truthful;
- an IPFS artifact remains retrievable;
- the selected circuit or guest program is bug-free;
- the proof system, trusted setup, compiler, or EVM verifier has no soundness defect; or
- the settlement asset, chain, or frontend is safe.

The assurance claim is therefore conditional and exact: **if** the frozen evaluator relation is
the intended relation, its implementation refines that relation, the proof system is sound, the
on-chain verifier executes the specified semantics, and the chain and asset assumptions hold, a
reward cannot settle without a witness satisfying that relation.

This is materially stronger than “two addresses signed,” while still naming the trusted computing
base. A proof of the wrong program remains a valid proof of the wrong thing.

## 3. Preferred architecture: one immutable universal verifier

The preferred deployment uses an audited universal zkVM verifier whose on-chain bytecode is fixed.
Each bounty freezes an `evaluatorImageId` for the deterministic guest program. This permits many
evaluator programs without giving an administrator authority to replace the verifier or program
for an active bounty.

If the selected proof system instead requires circuit-specific verifier bytecode, deploy a separate
escrow version or immutable adapter for each reviewed circuit family. Do not use an upgradeable
proxy or mutable address registry in the value-authorization path. A release catalog may recommend
new versions, but it is discovery metadata rather than authority over old jobs.

An adapter boundary is acceptable only if the escrow freezes all of the following at construction:

```text
proofSystemId
proofVerifier address
proofVerifier runtime code hash
publicInputEncodingId
maximumProofBytes
maximumJournalBytes
```

The adapter call must be read-only, gas-bounded, return one canonical success value, reject malformed
or trailing data, and fail closed on revert, timeout, empty return data, or code-hash mismatch. It
must never receive asset approval, call back into settlement, use `delegatecall`, or mutate escrow
state.

## 4. Bounty and claim state

A proof-backed bounty freezes at least:

```text
deploymentId
bountyId
sponsor
refundRecipient
asset
reward
developerFee
securityFee
commitDeadline
settlementDeadline
evaluatorImageId
evaluatorProfileHash
specificationHash
termsHash
availabilityPolicyHash
```

A solver first submits the existing domain-separated commitment:

```text
commitment = keccak256(abi.encode(
    COMMITMENT_TYPEHASH,
    deploymentId,
    bountyId,
    solver,
    resultDigest,
    salt
))
```

After the commit phase closes and before the settlement deadline, anyone may relay the solver's
claim and proof. The contract recomputes the commitment, constructs the canonical journal from
frozen on-chain state, verifies the proof, moves the bounty to its terminal state, and creates pull
credits. No relayer can redirect the solver reward.

The interface should recommend a chain-specific finality margin before the hard settlement
deadline. A later design may add a separate proof-registration/finalization phase, but it must not
claim that a grace period repairs a claim which was never finalized before a reorganization.

## 5. Canonical public statement

The guest program commits a fixed-width journal. Version 1 should be one canonical ABI encoding,
not JSON, packed encoding, or implementation-defined serialization:

```text
statementHash = keccak256(abi.encode(
    ZK_ACCEPTED_RESULT_TYPEHASH,
    proofSystemId,
    publicInputEncodingId,
    block.chainid,
    escrow,
    deploymentId,
    bountyId,
    solver,
    commitment,
    resultDigest,
    evaluatorImageId,
    evaluatorProfileHash,
    specificationHash,
    termsHash,
    availabilityPolicyHash,
    reward,
    developerFee,
    securityFee,
    commitDeadline,
    settlementDeadline
))
```

The exact field order, widths, domain string, and type hash must be published as test vectors. The
on-chain contract independently constructs the expected statement hash from storage and claim
data; it never trusts a caller-supplied journal. Omitting any identity, economic field, or deadline
creates a replay or substitution surface.

The proof's only accepted semantic result is a canonical `ACCEPT` value bound into the journal.
Diagnostics and evaluator output may be content-addressed separately, but ambiguous truthy values,
strings, or exit-code conventions cannot authorize settlement.

## 6. Evaluator relation

For public artifacts, the deterministic guest relation is:

1. verify the evaluator profile bytes hash to `evaluatorProfileHash`;
2. verify specification and terms bytes hash to their frozen digests;
3. verify result bytes hash to `resultDigest`;
4. parse all artifacts with strict schemas, byte/depth/count limits, and no ignored trailing data;
5. execute the frozen evaluator semantics with network, clock, ambient randomness, and mutable host
   state disabled unless explicitly modeled as public input;
6. require the evaluator's canonical decision to equal `ACCEPT`; and
7. commit the exact statement hash and decision to the proof journal.

Large artifacts may be supplied as Merkleized witness data, but the relation must bind the root,
chunking rules, tree shape, padding, hash function, and maximum size. “The prover supplied some
file with this name” is not a relation.

For a theorem artifact, the guest should run a small pinned proof checker or kernel over the exact
theorem statement and proof object. ZK then proves execution of that checker. The checker and its
parser remain part of the trusted computing base and require their own correctness argument.

## 7. Contract settlement rules

The new value-moving contract should preserve the already-modeled escrow properties and replace
signature authorization with proof authorization:

- all liabilities are prefunded in one declared asset;
- the solver commitment must exist and match the revealed digest and salt;
- claim and refund windows are disjoint and half-open;
- the proof verifier is called before terminal state or credit creation;
- one bounty reaches at most one terminal state;
- the full advertised reward is credited to the committed solver;
- fixed developer and security fees are credited exactly once only after a valid proof;
- an expired unpaid bounty refunds its complete funded amount;
- withdrawals remain pull-based and non-reentrant; and
- a verifier failure has the same effect as an invalid proof: no state or liability change.

There is no verifier committee fee in the keyless objective path. Proof generation has real compute
cost, so the sponsor either prices that cost into the worker reward or prefunds an explicit prover
subsidy `P`. With reward `R`, developer fee `D`, security fee `S`, availability budget `A`, and
prover subsidy `P`, funding is:

```text
F = R + D + S + A + P
```

Every term is denominated in the settlement asset. If that asset is PLS, external purchasing power
still floats; the proof system does not create dollars.

## 8. IPFS and availability

ZK proves a relation over bytes or commitments; it does not make those bytes discoverable or
persistent. Public jobs should publish the profile, specification, terms, and post-commit result as
content-addressed artifacts. The browser or evaluator fetches them, enforces size limits, and
recomputes the frozen Keccak digests.

The settlement relation may require an `availabilityPolicyHash` and machine-checkable receipts,
but a provider signature is not indefinite storage. The first marketplace release should use
multiple independent pins and retrieval monitoring. Stronger proof-of-retrievability or storage
deal mechanisms are a separate relation and economic system.

Do not publish an unrevealed result, salt, solver recovery package, or decryption key to public
IPFS. A ZK proof can preserve witness privacy, but public settlement metadata, result commitments,
timing, addresses, and value remain observable.

## 9. Correctness and refinement obligations

Implementation starts only after these obligations have exact quantifiers, assumptions, and
counterexamples:

1. **Conservation:** actual supported-asset balance is at least escrowed obligations plus credits.
2. **Prefunding:** creation is the only transition that increases total protocol liabilities
   without consuming existing escrow.
3. **Single terminal transition:** paid and refunded states are mutually exclusive and final.
4. **Commitment binding:** a paid claim corresponds to the committed solver, bounty, result digest,
   and salt in the same deployment.
5. **Statement completeness:** changing any frozen identity, artifact digest, economic value, or
   deadline changes the expected statement hash.
6. **Cross-domain replay resistance:** a proof for another chain, escrow, deployment, bounty,
   solver, program, or encoding is rejected.
7. **Proof gate:** every transition to `Paid` has a successful verifier execution for the exact
   on-chain statement; verifier failure leaves storage and liabilities unchanged.
8. **Verifier isolation:** the adapter cannot mutate escrow state, reenter settlement, spend the
   asset, or change its reviewed code identity.
9. **Guest soundness:** an accepted journal is emitted only after every hash, parser, evaluator,
   and canonical `ACCEPT` check succeeds.
10. **Guest refinement:** the guest program's implemented evaluator refines the separately stated
    mathematical relation for all admitted inputs.
11. **Encoding agreement:** Solidity, guest code, SDK, and test-vector encoders produce identical
    statement bytes and hashes.
12. **Resource boundedness:** proof, journal, artifact, parsing, guest cycles, verifier gas, and
    external-call gas are bounded before expensive work.
13. **Deadline partition:** commit, settlement, and refund predicates are disjoint at every boundary.
14. **Availability honesty:** settlement claims only the exact bounded availability predicate that
    was checked, never perpetual delivery.
15. **No hidden authority:** no owner, proxy admin, signer committee, mutable verifier registry, or
    emergency caller can authorize a result.

The reference transition system should be specified independently, with conservation and
authorization theorems proved in a proof assistant. The Solidity implementation, guest program,
and encoding library then receive differential vectors generated from that specification. Bounded
model checking, invariant fuzzing, mutation testing, symbolic execution, circuit/guest adversarial
tests, and EVM integration tests must target each obligation. These are complementary evidence;
none silently substitutes for proof-system review or an external audit.

## 10. Build sequence

1. Freeze one narrow evaluator relation with bounded public fixtures and hostile counterexamples.
2. Specify the state machine, journal encoding, and the 15 obligations above before Solidity.
3. Benchmark at least two proof backends on the actual relation: proving time/memory, proof bytes,
   verifier gas, trusted setup, audit maturity, recursion needs, licensing, and PulseChain EVM
   compatibility.
4. Implement the evaluator twice: an obviously correct reference and a bounded guest/circuit.
5. Prove or mechanically check refinement for the parser and core relation where feasible; run
   differential and mutation campaigns everywhere else.
6. Implement a new native-PLS escrow against the immutable public verifier. Do not modify V1 in
   place or inherit its secret-key authorization path.
7. Add exact end-to-end vectors: artifact bytes -> result digest -> commitment -> proof -> journal
   -> simulated settlement -> withdrawal/refund.
8. Obtain independent review of the relation, guest/circuit, proof integration, Solidity, build,
   and deployment evidence.
9. Run a capped testnet pilot, then a capped native-PLS deployment. Add other assets or evaluator
   relations only as separately reviewed releases.

The first implementation target should be a small proof or model-checking task whose acceptance
kernel is already deterministic and easy to state. General arbitrary computation is not the first
correctness claim.

## 11. Research foundations

The design follows the proof-carrying-code principle that a producer supplies evidence checked by
a small consumer policy ([Necula, 1997](https://doi.org/10.1145/263699.263712)). Succinct
verification can move expensive execution off chain while keeping a small verification step
([Pinocchio](https://doi.org/10.1109/SP.2013.47)). Smart-contract implementation and proof-system
semantics still require explicit refinement and execution models; tools such as
[VeriSolid](https://arxiv.org/abs/1901.01292) and
[KEVM](https://doi.org/10.1109/CSF.2018.00022) illustrate complementary approaches rather than an
automatic guarantee.

