# Threat model

## 1. Security objective

For each correctly funded bounty, the contract should do exactly one of two things:

1. credit the full advertised reward and frozen successful-settlement fees after a solver's committed result receives valid signatures from two distinct configured verifiers during the claim window; or
2. credit the entire funded amount to the frozen refund recipient after expiry.

At all times, recorded escrow and withdrawal liabilities should remain backed by the configured asset under the supported asset assumptions.

This objective is narrower than “the best answer wins” or “the work is correct.” Correct evaluation is an off-chain verifier responsibility.

## 2. Assets and trust boundaries

Assets requiring protection are:

- sponsor deposits;
- solver, verifier, DevCo, reserve, and refund-recipient credits;
- the integrity of frozen bounty identifiers and deadlines;
- verifier private keys and signing policy;
- the canonical off-chain specification, terms, evaluator, and result data; and
- chain, RPC, explorer, indexer, and frontend configuration used to construct transactions.

The contract is the authority for funding, phase boundaries, commitment equality, ECDSA signer membership, first settlement, credits, and withdrawals. It is not the authority for result correctness, content availability, human identity, reputation, or legal performance.

## 3. Required assumptions

### 3.1 Verifier assumption

At least two of the three configured verifier keys must follow a sound, reproducible evaluation policy. Two compromised or colluding verifiers can authorize an attacker's committed result during the claim window. One compromised verifier cannot meet the threshold alone.

Availability is separate from integrity. If fewer than two verifiers sign, no solver can be paid, but the full funded amount becomes refundable at the deadline.

Verifier compensation is separate from integrity. The sponsor declares a pool from the greater of
two smallest units or 0.5% of reward through 100% of reward, and the two signers explicitly sign
that pool and split it. The lower bound is a syntax/economic floor, not evidence that the work is
adequately priced. Even a large honest fee does not remove the much larger collusion incentive to
authorize an affiliate's claim.

The contract uses ECDSA recovery, not ERC-1271. Verifier addresses should be dedicated EOA-style
signing identities with independently protected keys. The constructor rejects verifier addresses
that already have code, but that deployment-time check cannot prevent later code deployment or
delegation at the same address. The verifier set can never be rotated.

### 3.2 Evaluation assumption

The frozen profile, specification, and terms hashes must resolve to a complete, unambiguous, available evaluation package. If the package is subjective, unavailable, nondeterministic, or underspecified, on-chain integrity cannot repair it. The protocol has no dispute or appeal path.

### 3.3 Asset assumption

The native adapter assumes ordinary EVM native-currency semantics.

The ERC-20 adapter supports only a vetted exact-transfer token whose `balanceOf`, `transfer`, and `transferFrom` behavior remains honest and stable. Fee-on-transfer, rebasing, elastic-supply, callback-bearing, blacklistable, pausable, deceptive, or upgrade-mutated behavior is outside the supported profile. Exact balance-delta checks reject many incompatible transfers, but they cannot make an adversarial token trustworthy.

### 3.4 Chain assumption

The selected chain must execute the deployed bytecode according to the targeted EVM semantics and provide adequate finality, liveness, and timestamp behavior. Users and indexers must account for reorgs, sequencer outages, and chain-specific finality. A transaction observed only in a pending or unsafe block is not a final settlement.

## 4. Adversaries

The model considers:

- a malicious or careless sponsor;
- competing malicious solvers and transaction observers;
- one or more malicious or compromised verifiers;
- a malicious relayer;
- malicious withdrawal destinations;
- an incompatible or adversarial ERC-20;
- frontend, gateway, RPC, indexer, or explorer compromise;
- ordinary chain reordering, reorg, censorship, and timestamp variance; and
- accidental key loss, wrong configuration, and mistaken direct transfers.

The model does not assume the deployment transaction, compiler, dependencies, or operator workstation are trustworthy without independent verification.

## 5. Threat analysis

| Threat | Implemented control | Residual risk / required operation |
| --- | --- | --- |
| Sponsor refuses to pay after receiving work | Full funding is locked at creation; sponsor has no approval or cancellation power. | A weak specification can still produce disagreement or unusable work. |
| Solver submits without prior commitment | Claim recomputes a deployment-, bounty-, solver-, result-, and salt-bound commitment. | Verifiers must still check the actual result package. |
| Another account copies a revealed claim | The commitment and attestations bind the payout solver; anyone may relay but cannot redirect the reward. | Public result material may still be copied or used elsewhere. |
| One solver blocks other solvers | Commitments are stored independently per solver and are replaceable before the deadline. | First valid claim wins; there is no ranking among multiple accepted results. |
| Signature replay across bounty, deployment, asset, or chain | EIP-712 domain separation plus deployment ID and frozen bounty fields, reward, and verifier pool are signed. | Clients must sign the exact typed data and reject `personal_sign` substitutions. |
| Duplicate verifier satisfies threshold | Exactly two indices are required in strictly increasing order. | Two genuinely distinct compromised keys remain sufficient. |
| Verifier self-awards a bounty | Any configured verifier address is prohibited as solver. | DevCo, reserve, sponsor, or an affiliate may still be a solver; conflict policies are off chain. |
| Verifier work is underpriced | Sponsor must declare at least two units or a 0.5% pool, whichever is greater; reward and pool are included in each attestation. | The minimum can still be uneconomic. Profiles must recommend real budgets and verifiers must refuse inadequate work. |
| Two verifiers collude for reward | Direct verifier addresses cannot be solvers and every claim needs a prior solver commitment. | Two keys can use an affiliate address and capture nearly all reward. No fee, bond, or code check eliminates the trusted-threshold assumption. |
| Claim and refund race | Half-open phases make claim unavailable at the exact refund boundary. Terminal status is written once. | Reorgs near the deadline require finalized-state handling. |
| Reentrancy during payout | Claim only creates credits. Create, claim, and withdraw are guarded; withdrawal updates effects before interaction. | An adversarial token is unsupported even if a particular callback is blocked. |
| One reverting recipient blocks settlement | Pull credits avoid transfers during claim/refund. Each beneficiary withdraws independently and may select a different destination. | A beneficiary that loses its key or is token-blacklisted may be unable to withdraw. |
| Fee-on-transfer deposit creates undercollateralization | ERC-20 creation verifies the exact balance increase before recording a bounty. | Rebases or later token upgrades can still break balance assumptions. |
| Deflationary or deceptive withdrawal | ERC-20 withdrawal verifies exact escrow decrease and destination increase; failure rolls back credit. | Blacklisting, pauses, callbacks, or dishonest `balanceOf` remain unsupported. |
| Forced native currency or direct token transfer changes liabilities | Accounting ignores unsolicited balance increases and exposes them only as surplus. | No rescue exists; unsolicited surplus can be permanently stranded. |
| Admin steals, changes fees, pauses, or upgrades | There is no owner, proxy, pause, arbitrary call, fee setter, or verifier setter. | A discovered bug cannot be patched in place, and compromised verifier keys cannot be rotated. |
| Deadline manipulation | Disjoint comparisons are explicit and duration is capped at 366 days. | Block producers/sequencers can influence timestamps within chain rules; avoid very short windows. |
| Gas denial through unbounded iteration | Claim checks exactly two signatures and settlement iterates exactly twice. No user-sized array is stored or traversed. | Network congestion can still censor time-sensitive transactions. |
| Malicious relayer redirects payment | Solver and every economic recipient are frozen or signature-bound; relayer is not a settlement recipient. | Relayers can withhold transactions; solvers should retain a direct submission path. |
| Frontend substitutes addresses or terms | On-chain getters and events expose deployment and bounty fields. | Users must verify chain ID, contract address, asset, fee recipients, verifier set, hashes, and deadlines outside the frontend. |

## 6. Key-compromise consequences

- **One verifier key compromised:** attacker cannot produce threshold attestations alone but can disrupt or assist another malicious verifier.
- **Two verifier keys compromised:** attacker can satisfy acceptance for any matching commitment submitted before the commit deadline. Open bounties should be treated as at risk. There is no rotation or pause.
- **Solver key compromised:** attacker can replace that solver's commitment before the deadline, submit claims for that solver, and withdraw its credits to another destination.
- **Refund-recipient key compromised or lost:** expired funds can be redirected by the key holder or become inaccessible.
- **DevCo/reserve key compromised or lost:** only that address's accumulated credits are affected; bounty state cannot be administered from these addresses.
- **Sponsor key compromised after creation:** existing bounty terms cannot be changed, although the key can create new bounties with its own assets.

Use independent verifier custody, rehearsed incident communication, and chain monitoring. Immutability is not a substitute for key management.

## 7. Off-chain evaluator risks

The largest product-level risk is a signed but semantically weak result. Before signing, verifier software should:

1. confirm chain ID, escrow address, deployment ID, bounty status, phase, and stored commitment;
2. retrieve content by independently checked hashes from more than one location;
3. reproduce the pinned evaluator in an isolated environment;
4. enforce resource limits and reject nondeterministic or environment-dependent criteria;
5. derive the result digest from canonical bytes;
6. display every typed-data field to the operator; and
7. record a signed, replayable evaluation receipt.

If a profile permits subjective judgment, the fixed 2-of-3 group is acting as an arbitrator even though the contract calls it verification. That use is outside the intended objectively replayable profile and should be labeled honestly.

## 8. Immutability and incident response

There is no privileged emergency action. On a suspected vulnerability or key compromise, operators can only:

- stop directing users to the affected deployment;
- publish the exact chain, address, and issue through established channels;
- ask token users to revoke unused allowances;
- advise beneficiaries to withdraw existing credits if safe;
- allow unaffected open bounties to reach their encoded claim or refund path; and
- deploy a new, separately identified contract after remediation and review.

No operator can cancel a bounty, accelerate a refund, seize credits, rescue surplus, rotate verifiers, or migrate user funds.

## 9. Out-of-scope guarantees

The implementation does not guarantee:

- result truth beyond two verifier signatures;
- anonymity or transaction privacy;
- IPFS availability or gateway neutrality;
- token solvency or issuer behavior;
- resistance to chain-wide censorship or consensus failure;
- legal enforceability, employment classification, sanctions compliance, or tax treatment;
- safe use of arbitrary ERC-20s;
- recoverability after key loss or mistaken transfers; or
- freedom from defects without an independent audit and deployment-specific verification.
