# Evaluation Market V2 design target

> **Status: research specification; not implemented.** The deployed-code candidate in this
> repository is the immutable V1 escrow. V1 is an open prize race settled by two signatures from
> a fixed three-address verifier set. Nothing in this document changes V1 bytecode, funding, or
> guarantees. A V2 release requires a separate specification, threat model, model, implementation,
> audit, and deployment ID.

For objective jobs, the preferred V2 settlement path is the separate
[keyless ZK design](zk-settlement-v2.md). Permanent signer committees remain only a weaker fallback
for relations that cannot yet be proved succinctly; they are not the target trust root.

## 1. Why V2 exists

V1 deliberately makes one narrow value movement safe: a sponsor prefunds a prize, the first solver
with a commitment and two approving attestations can receive it, and otherwise the complete deposit
is refundable after the deadline. It is not yet a labor marketplace, a proof system, or a complete
evaluation network.

In particular, V1 pays only the two signers included in the winning **ACCEPT** claim. An evaluator
who reproduces a result and rejects it, an honest third evaluator whose signature is not relayed, or
an evaluator reviewing a losing claim earns nothing. That creates an approval and selection bias:
review work is costly, but the only on-chain payment path rewards a particular accepted outcome.
Routing policy can reduce duplicated work, but cannot remove the mechanism-level incentive.

For the attested fallback, V2 should separate three questions that V1 combines:

1. Was assigned evaluation work completed under the declared evaluator profile?
2. Did that evaluation produce `ACCEPT`, `REJECT`, or a supported inconclusive result?
3. Does the resulting decision authorize the worker reward?

Payment for a valid decision receipt should not depend on the answer to question 2. Payment of the
worker reward still must depend on the job's declared acceptance rule.

## 2. Design boundaries

V2 should preserve these boundaries:

- There is no protocol token, emission, yield, or endogenous dollar source.
- Every escrow liability and credit is an integer amount of one declared asset. An ERC-20
  deployment is safe only to the extent that the token itself remains inside the supported
  exact-transfer behavior profile; native PLS avoids token-contract and issuer risk.
- Arbitrary off-chain semantic truth cannot be guaranteed by Solidity or a majority signature.
  The protocol can guarantee conservation, authorization, deadlines, and the binding between an
  outcome and declared evidence. Stronger result correctness requires a deterministic evaluator,
  an on-chain predicate, or a sound proof system.
- V2 must not be presented as an upgrade to an existing immutable V1 address. It is a new protocol
  and deployment.
- Profit, asset price, demand, evaluator honesty, artifact persistence, and legal or tax treatment
  are outside a mathematical safety proof.

## 3. Two explicit work modes

Trying to make one settlement rule serve both contests and commissioned work hides important risk.
V2 should make the mode immutable per job.

### 3.1 `OPEN_PRIZE`

Multiple workers may compete and the first result satisfying the declared acceptance policy earns
the reward. Losing workers are not compensated by the escrow. The interface must say this before a
worker commits. Review should be assigned only after a candidate becomes eligible, so the sponsor
does not unintentionally fund unbounded duplicate evaluation.

### 3.2 `ASSIGNED_JOB`

The sponsor posts terms, a worker accepts an exclusive assignment, and only that worker can submit
for the agreed interval. Optional milestones are separate escrows with separate acceptance rules;
one milestone must not make later unfunded work appear guaranteed. Assignment eliminates the hidden
cost of an open race and is the appropriate default for bespoke development.

Multi-winner grants, proportional collaboration, auctions, and reputation-weighted procurement are
future modes, not implicit behavior of either mode above.

## 4. Keyless objective settlement and attested fallback

When a deterministic evaluator can be represented by a reviewed circuit, on-chain predicate, or
zkVM guest, a valid proof should authorize the reward directly. No secret verifier key decides the
outcome. Each bounty freezes the public verifier code identity, evaluator image/circuit ID, public
input encoding, and exact relation. The proof journal binds all job, solver, artifact, economic,
and deadline fields. The normative statement and proof obligations are in the
[keyless ZK settlement design](zk-settlement-v2.md).

A committee is used only for an explicitly lower-assurance job that lacks a proof-backed relation.
Its UI, schema, and fees must say `ATTESTED`, not `PROVED`. Long-lived deployments must not depend on
non-rotatable secret keys; an attested V2 design needs epoch-scoped committees and an authority and
migration model whose powers are explicit. This is a fallback research problem, not inherited V1
behavior.

## 5. Prefunded committee and quotes

Before a job becomes active, candidate evaluators should publish signed, expiring availability
quotes. A quote binds at least:

```text
chain ID, V2 deployment ID, evaluator address, evaluator profile ID,
asset, fee, maximum artifact/input size, response deadline, quote nonce, expiry
```

Activation assigns a bounded committee and locks the exact fees for that committee. A sponsor
cannot advertise work first and later discover that no evaluator will review it, and an evaluator
cannot retroactively change its price. Committee selection may be sponsor-curated for an initial
pilot; randomized or stake/reputation-assisted selection is later research and does not by itself
make Sybil identities independent.

The assigned identities or a commitment to their deterministic selection, committee size, quorum,
and decision rule are part of the immutable job terms. A committee must never be inferred only from
the signatures eventually relayed, because that makes payment selection manipulable.

## 6. Decision receipts and reviewer payment

Each assigned evaluator first commits to a decision, then reveals a signed receipt. Commit/reveal
reduces copying and majority herding, although it cannot prevent out-of-band coordination. A receipt
binds:

```text
job ID, submission ID, worker, result digest, artifact root,
evaluator profile ID and executable image digest,
committee ID and evaluator slot, quote ID,
decision (ACCEPT / REJECT / INCONCLUSIVE), reason code,
evidence or execution-receipt digest, observed final block hash,
decision-commitment salt, receipt deadline
```

The receipt fee is earned when a receipt is timely, authorized, internally consistent, and meets
the mechanically checkable evidence requirements of its profile. It is paid for a valid decision
receipt whether the decision is `ACCEPT` or `REJECT`. An `INCONCLUSIVE` receipt may earn a smaller
declared amount or no amount, but that rule must be fixed in the quote. No unassigned reviewer can
create a protocol liability.

This fixes V1's direct approve-to-get-paid bias; it does not prove that a reviewer ran the evaluator
or reported honestly. Evidence requirements, independent execution, and narrowly provable
penalties supply the remaining controls.

Recommended settlement buckets are:

- the worker reward, paid only when the job's acceptance predicate is met;
- one locked receipt fee per assigned committee slot;
- an explicitly declared coordination/service fee;
- a separately declared security-reserve fee; and
- refundable unused or unearned amounts.

On rejection, valid evaluators are still paid and the worker reward is returned to the frozen
refund recipient. On committee timeout, responsive evaluators receive only the fees justified by
valid receipts, unearned evaluator fees and the reward are refunded, and liveness penalties may be
applied only if they were bonded and objectively specified in advance.

## 7. Funding and sustainable operation

All V2 payments must be prefunded. For reward `R`, assigned evaluator receipt fees `q[i]`, service
fee `D`, reserve fee `S`, and any explicit availability/delivery budget `A`, required funding is:

```text
F = R + sum(q[i]) + D + S + A
```

No term creates dollars. If the asset is PLS, all five terms are PLS and their external purchasing
power floats. Dollar-denominated operating expenses can be met only if someone supplies a
dollar-redeemable asset that is safe for the deployment, or a recipient sells received assets to
an external buyer. Price conversion, liquidity, slippage, custody, and taxes are outside the
escrow.

Creator funding can combine transparent, sponsor-funded mechanisms without promising investment
return:

- a success fee on accepted worker reward volume;
- a small coordination fee earned for completed, valid review rounds, including honest rejection;
- evaluator-profile publication or hosted execution fees paid under separate service terms;
- community grants and protocol-maintenance bounties; and
- voluntary donations to a segregated operating treasury.

The V1 immutable 2% DevCo fee remains only a success fee. If operating need is `C` units of the
same asset, ignoring per-bounty flooring, it requires `50 * C` units of accepted reward volume.
That is a break-even revenue identity, not a demand forecast or profit promise. V2 fee values should
be chosen through measured pilots: expected evaluation cost, incident reserve, conversion costs,
and demand elasticity are empirical inputs, not constants a proof can establish.

## 8. Verification assurance tiers

Every job declares one tier; the UI must not describe a lower tier as a proof.

| Tier | Acceptance evidence | What can be guaranteed |
| --- | --- | --- |
| 0: attested | Authorized signed decisions and bound digests | Who attested to which bytes and terms |
| 1: reproducible | Deterministic evaluator receipt under a content-addressed execution profile | Reproduction under the declared machine model |
| 2: proof-backed | On-chain predicate or sound proof verified by frozen verifier code/key | Satisfaction of the encoded relation, subject to proof-system assumptions |
| 3: subjective | Human/domain review with structured reasons | Process and attribution, not semantic truth |

A reproducible profile needs more than a repository URL. It binds the OCI image digest, target
architecture, kernel or virtual-machine assumptions, read-only inputs, environment variables,
clock and randomness policy, network policy, syscall/device policy, resource limits, entry point,
expected output schema, and canonical receipt encoding. A nondeterministic evaluator must expose
that limitation and cannot support byte-for-byte consensus without an additional rule.

Tier 2 must identify the exact circuit/relation, public-input encoding, verification key or verifier
bytecode, trusted-setup assumptions, and proof-system version. A mathematically valid proof of the
wrong relation is not useful assurance.

## 9. Artifact availability and fair delivery

An accepted digest is not delivery. A worker could reveal bytes to evaluators while the sponsor
cannot retrieve them. V2 therefore binds an artifact root and an availability predicate into the
job and every decision receipt.

For public work, a profile can require retrieval from multiple content-addressed stores for a
minimum interval and include signed availability receipts. Persistence beyond that interval still
depends on storage providers and funding.

For confidential work, the artifact can be uploaded encrypted to the sponsor and evaluators. The
receipt binds the ciphertext root; a key-release or verifiable-encryption step is coupled to
settlement. Perfect fair exchange is not obtained merely by adding encryption: key release,
censorship, data availability, and chain reorganization assumptions must be explicit. The safe
fallback is a bounded timeout that refunds according to predeclared delivery state, not a claim
that either party can always force simultaneous exchange.

## 10. Rubber-stamping, bonds, and slashing limits

Outcome-neutral receipt fees remove the most direct reason to approve everything. Additional
controls should include deterministic evidence schemas, commit/reveal decisions, independent
reproduction, public equivocation proofs, committee diversity constraints, and observable response
history.

Bonds may be slashed only for objectively proven protocol faults such as signing two conflicting
receipts for the same slot, using an expired or different profile, or revealing a decision that does
not match its commitment. Mere disagreement, a failed subjective prediction, or a later-discovered
evaluator bug is not an objective slashing condition. Broad discretionary slashing recreates a
trusted court and can punish honest minority reviewers. Reputation is useful routing information,
not mathematical collateral, and must be designed against cheap identity replacement.

## 11. Value-safety invariants and proof obligations

The implementation is not ready until its executable model and contract tests refine the same
state machine. At minimum, the proof boundary should include:

1. **Conservation:** on-chain asset balance is always at least total locked obligations plus
   withdrawable credits, under the declared asset assumptions.
2. **Prefunding:** no job, committee assignment, milestone, or receipt can create an unfunded
   liability.
3. **At-most-once reward:** a job or milestone reward is credited at most once.
4. **Bounded reviewer liability:** at most the frozen quoted fee for each assigned committee slot
   can be credited, and unassigned identities receive zero.
5. **Outcome-neutral receipt payment:** for otherwise identical valid receipts, fee eligibility is
   independent of `ACCEPT` versus `REJECT`.
6. **Authorization binding:** every signature/proof binds chain ID, contract, deployment ID, job,
   mode, submission, artifact, profile, committee and slot, quote, economics, decision, and deadline.
7. **Committee immutability:** relaying a different subset cannot change assigned payees or the
   decision rule.
8. **Mode separation:** an `OPEN_PRIZE` transition cannot acquire assignment rights and an
   `ASSIGNED_JOB` transition cannot be won by an unassigned worker.
9. **Deadline monotonicity:** no accepted transition can revive expired rights; refunds and receipt
   windows have an explicit, non-overlapping boundary.
10. **Availability gating:** reward settlement implies the exact declared availability predicate
    was satisfied, without claiming persistence beyond that predicate.
11. **Pull-payment safety:** external transfer failure cannot corrupt another participant's credit;
    withdrawal reentrancy cannot increase total credit.
12. **No hidden authority:** every emergency, cancellation, selection, upgrade, and pause power is
    either absent or modeled as an explicit trusted role with bounded effects.

Model checks, fuzzing, mutation testing, and static analysis are evidence, not a proof that all
requirements are correct. Any theorem must name token behavior, cryptographic unforgeability,
proof-system soundness, chain finality, data availability, and liveness assumptions. An independent
audit and capped adversarial pilot remain required before material value is exposed.

## 12. Staged build plan

1. **Observe V1:** launch only with explicit caps, native asset preference, finality-aware indexing,
   and published metrics for accepted/expired volume, reviewer effort, response time, and disputes.
2. **Run evaluators off chain:** freeze one narrow objective relation and test its deterministic
   reference evaluator, guest/circuit, content encodings, and availability policy without moving
   production value. Test committee receipts only as a separately labeled fallback.
3. **Freeze semantics:** publish canonical encodings, schemas, state machine, adversary model, and
   counterexamples; resolve ambiguous deadlines and delivery states before Solidity.
4. **Prove and refine:** model conservation and authorization, implement the smallest contract that
   refines the model, and require differential, invariant, mutation, and adversarial tests for every
   value transition.
5. **Audit and capped pilot:** use independent reviewers, a public bug bounty, low per-job and total
   exposure caps, and a precommitted shutdown policy for the pilot deployment.
6. **Add one keyless proof tier:** deploy one separately audited proof-backed relation before
   generalizing committee machinery. Do not generalize assurance claims from one verified profile
   to arbitrary jobs.
7. **Re-estimate economics:** publish asset-unit revenue, actual reviewer cost, failure rates, and
   treasury runway by asset. Change fees only in a separately identified V2 deployment or through
   powers that were explicitly modeled and disclosed.

This order keeps the next research claim falsifiable: first prove that value cannot move outside
the frozen rules, then measure whether the service those rules implement is wanted and sustainably
funded.
