# Security evidence and assurance boundary

## 1. Bottom line

The current implementation has useful deterministic, adversarial, fuzz, stateful-invariant,
bounded-model, semantic-mutation, Solidity source-mutation, symbolic, static-analysis,
deployment-rehearsal, and reproducible-build evidence. That evidence increases confidence in
specific properties. It is **not an absolute proof of correctness**, an external audit, or a
guarantee that deployment configuration, verifier behavior, a token, a chain, an off-chain
evaluator, or the browser client is safe.

As of 2026-07-15, the appropriate status is **pre-release / testnet candidate**, not unaudited
production with material funds.

## 2. Reviewed implementation scope

The recorded evidence covers:

- `contracts/ProofBountyEscrowBase.sol`;
- `contracts/ProofBountyEscrowNative.sol`;
- `contracts/ProofBountyEscrowERC20.sol`;
- `contracts/interfaces/IProofBountyEscrow.sol`;
- checked-in Foundry tests and Python reference/mutation models;
- checked-in deployment/audit/observation tooling; and
- the static client under `app/` to the extent described below.

Primary build configuration is:

| Component | Version or setting |
| --- | --- |
| Solidity | 0.8.36 |
| OpenZeppelin Contracts | 5.0.2, lockfile integrity pinned |
| Foundry | 1.7.1, release archive SHA-256 pinned in CI |
| forge-std | 1.16.2 at revision `bf647bd6046f2f7da30d0c2bf435e5c76a780c1b` |
| Optimizer | enabled, 200 runs |
| EVM target | `paris` |
| Via IR | false |
| Bytecode metadata hash | IPFS |

Dependency or setting changes alter the reviewed source/build graph and require a new evidence run.

## 3. Recorded executable tests

The release-candidate Foundry suite contains 53 tests:

- 26 deterministic integration/unit tests;
- 12 targeted adversarial token/signature tests;
- five fuzz properties;
- five native-currency stateful invariants; and
- five exact-transfer ERC-20 stateful invariants.

The fuzz run executes:

| Property | Cases |
| --- | ---: |
| Fee formula and required-funding conservation | 10,000 |
| Commitment binding across all inputs | 10,000 |
| Create/refund/withdraw liability conservation | 2,000 |
| Claim-credit and single-settlement conservation | 2,000 |
| EIP-712 replay rejection after chain-ID change | 1,000 |
| **Total** | **25,000** |

Each native invariant executes 1,000 generated traces with 100 handler calls, for 500,000 aggregate
stateful calls across the five properties. Each ERC-20 invariant executes 512 traces with 80 calls,
for 204,800 aggregate calls. Both campaigns target only the eight state-changing handler actions,
run with `fail_on_revert = true`, and report zero handler reverts. The properties
cover solvency/surplus identity, funding-withdrawal conservation, open-deposit reconciliation,
complete known-credit summation, and terminal-state shape. The ERC-20 campaign deliberately uses
the supported honest exact-transfer token profile; separate adversarial tests cover false returns,
short transfers, callbacks, and unsupported fee behavior.

Deterministic/adversarial coverage includes immutable configuration and deployment separation;
deployment-time verifier-code and self-address guards; malformed creation; exact funding;
minimum/maximum verifier-pool bounds and the two-unit signer floor; EIP-712 binding of the frozen
reward, verifier pool, and exact paid signer pair; signer-pair substitution rejection and complete
settlement receipts;
replaceable per-solver commitments; exact half-open boundaries; first valid claim; exact fee
allocation; complete expiry refund; cross-chain/deployment/bounty replay rejection; duplicate,
malformed, compact, and high-`s` signature rejection; verifier self-award rejection; failed native
and token withdrawal rollback; ERC-20 insolvency admission/withdrawal rejection; asset-contract
credit-sink rejection; partial withdrawals; callback reentrancy attempts; surplus handling;
ordinary native/ERC-20 lifecycles; and absence of common admin selectors.

The static client separately passes 14 unit tests, TypeScript checking, a production Vite build,
and two-build content reproducibility. The recorded `dist/` tree SHA-256 is
`31732f3dfab08c36086829ef7a00ea98339d696a1c6a904cc42e83d33cd733b1`; regenerate it from the final
revision rather than treating this historical hash as a live release. Its production dependency
audit reports zero known vulnerabilities at the recorded time.

Passing tests show that sampled/generated executions met their assertions. They do not prove every
EVM state, browser/provider behavior, external token, or chain implementation.

## 4. Finite reference model

`verification/model/model_check.py` exhaustively explores an abstract one-bounty model within
explicit bounds:

- two solvers;
- three verifiers, every two-verifier pair, and a distinct signed-versus-submitted pair;
- reward inputs `1`, `2`, `199`, and `10,200`, including the rejected one-unit boundary;
- verifier-pool inputs at, immediately around, and above the absolute and percentage-derived
  bounds for each reward;
- time domain `0` through `5`, commit boundary `2`, and claim boundary `4`;
- maximum trace depth `8`; and
- funding, replacement commits, claims, refund, withdrawals, time advancement, and forced native
  currency.

The recorded receipt found no counterexample across 12,466 states and 27,107 transitions. The claim
is exactly: no counterexample was found in those finite numeric, role, action, and depth bounds.

The model abstracts ECDSA as a valid verifier decision, represents one bounty per trace, and does
not execute Solidity, bytecode, gas, ABI decoding, token callbacks, or the EVM. It is not a
refinement proof between model and implementation.

## 5. Mutation sensitivity

`verification/model/mutation_check.py` verifies that the bounded properties kill 13 abstract
semantic faults: accepting commit at the boundary, accepting claim at the refund boundary, double
settlement, ignoring the solver commitment, deducting fees from the solver, omitting fees from the
refund, retaining escrow liability after claim, double-crediting one verifier, accepting a pool
below or above its bounds, accepting a reward below the absolute minimum, and replacing the
declared pool during settlement, and ignoring the signed verifier pair. The recorded run killed all
13.

`verification/solidity_mutation_check.py` creates isolated temporary source trees and applies 23
compiling Solidity mutations covering commit/claim/refund boundaries, terminal status, solver fee,
refund fee, reveal equality, escrow liability, duplicate verifier index, verifier-as-solver,
reward/pool bounds, declared-pool funding and settlement, the absolute signer floor, signer-pair
binding, ERC-20 solvency admission, and asset-contract credit sinks. Targeted tests killed all 23 in
the recorded run.

Mutation scores demonstrate that current checks are sensitive to those selected faults. They are
not exhaustive source mutation, bytecode equivalence, or a proof that an unknown fault is absent.

## 6. Symbolic checks

`test-foundry/ProofBountySymbolic.t.sol` defines four Halmos 0.3.3 obligations. A recorded local Z3
run completed all four without counterexample for:

- returned fee components conserve `requiredFunding` and preserve the declared pool for symbolic
  `uint16` reward and verifier-pool inputs satisfying the contract bounds;
- two verifier shares plus dust conserve a symbolic `uint16` verifier pool;
- `computeCommitment` matches canonical encoding for symbolic bounty ID, solver, result digest, and
  salt; and
- commit, claim, and refund windows are disjoint and total for symbolic `uint64` times where
  `commitDeadline < claimDeadline`.

The default Yices solver timed out on the unchanged deadline inequality obligation at both 30 and
60 seconds, while Z3 completed it in approximately 0.17 seconds. A solver timeout is neither a
proof nor a counterexample. Completed checks establish only their exact assertions under Halmos's
execution model, selected solver, assumptions, and input widths. They do not prove the stateful
contract, ECDSA, token behavior, or EVM. Receipts must be regenerated, hashed, and revision-bound
for a release.

## 7. Static analysis, review, and build artifacts

A production-only Slither 0.11.5 run excludes dependencies, tests, mocks, and scripts. The recorded
results are intended creditor-selected native sends, expected exact-balance ERC-20 reentrancy
patterns, and intentional timestamp windows. [Slither triage](slither-triage.md) records rationale
and residual assumptions. CI fails on any unacknowledged high-impact detector result. Slither's
`success: true` means analysis completed, not that the code is finding-free.

The offline release gate requires every external GitHub Action reference to use a reviewed
40-hex commit SHA with a human-readable version comment. It also rejects duplicate JSON keys,
unknown schema keywords, unresolved local references, invalid patterns, and checked-in instances
that violate the repository's closed Draft 2020-12 profile. The dependency-free validator covers
only the explicitly implemented keyword set and fails closed when a future schema uses a new
keyword; it is not a complete independent implementation of JSON Schema.

An independent review agent identified a cumulative-withdrawal telemetry overflow that could have
blocked withdrawals after enough funding cycles, self-referential recipient traps, deployment
provenance weaknesses, and several frontend stale-target/split-provider/privacy failures. The
cumulative counter was removed; escrow-self recipients/destinations were rejected; runtime and
creation provenance checks were strengthened; and client writes now invalidate stale targets,
re-verify and simulate through the injected provider, compute secret-bearing hashes locally, and
gate verifier requests on public phase/commitment state. Re-review found no remaining concrete
theft, replay, reentrancy, or conservation defect under the documented exact-transfer asset and
honest-threshold assumptions. A later review did find an unsigned verifier-pair fee-redirection
path and ERC-20 insolvency contamination; the signer bitmap, settlement receipt, solvency gates,
asset-credit-sink guards, model property, and adversarial tests in this revision address those
counterexamples. Late-claim reorg risk, immutable-key readiness, evaluator correctness, and the
V1 outcome-linked reviewer incentive remain explicit limitations. These were internal adversarial
reviews, not an external audit.

A clean local deployment rehearsal also exposed that `cast` annotates some decoded integers (for
example, `10000 [1e4]`) and the first manifest parser rejected that valid form. The parser was
hardened to accept only strict decimal/hex integers with an optional bracketed annotation, reject
trailing data, and a regression test was added to the default deployment-configuration gate.

The clean size build reports template runtime sizes of 11,968 bytes for the native adapter and
13,379 bytes for the ERC-20 adapter, below the 24,576-byte EIP-170 limit under recorded settings.
The larger audit *script* is not deployed. Constructor immutables alter deployed runtime bytes, so
template hashes are not deployment evidence.

The local operator rehearsal independently deployed both the native adapter and the ERC-20 adapter
with a mock exact-transfer token to isolated Anvil chains using chain ID 943, replayed
immutable/runtime checks, read each finalized creation receipt, and generated/checked an
observation for each variant. A local rehearsal is evidence about tooling mechanics only, not
PulseChain Testnet V4 compatibility, token approval, or a public deployment.

## 8. Assurance matrix

| Claim | Current evidence | Assurance boundary |
| --- | --- | --- |
| Phase windows do not overlap | Boundary tests, fuzzed flows, both invariant suites, finite model, symbolic partition, killed source/model mutants | Chain timestamp/finality remain assumptions |
| Only one terminal settlement occurs | Competing-claim tests, stateful invariants, model, killed mutant | Does not establish verifier correctness |
| Solver receives advertised reward | Allocation tests, 2,000-case claim fuzz, invariants, model/mutation | Supported asset and later withdrawal required |
| Expiry returns reward and proposed fees | Refund tests, 2,000-case fuzz, invariants, model/mutation | Refund key and asset must remain usable |
| Liabilities remain conserved | Deterministic/adversarial tests plus 704,800 aggregate invariant calls | Arbitrary malicious/rebasing/upgraded tokens unsupported |
| Signatures bind deployment/result/paid verifier pair | EIP-712 implementation, pair-substitution and replay/malleability tests, model/mutations, commitment fuzz, symbolic encoding | ECDSA/OZ/EVM and verifier endpoint correctness assumed |
| Exact-transfer behavior and solvency are enforced at observed transfers | Balance deltas, insolvency/clawback, fee/false/short/callback tests, ERC-20 invariants | Issuer controls, dishonest balances, and future upgrades can still freeze an existing deployment |
| No privileged admin surface | Source review and selector-negative test | Supply-chain/deployment substitution still requires release evidence |
| Client does not RPC-leak commitment preimages before reveal | Local encoding implementation/tests and review | A compromised page, wallet, device, or later claim still reveals data |
| Generated observation binds clean source to creation transaction | Clean-worktree gate, exact initcode prefix/constructor decode, receipt/config/runtime checks | Unsigned observation is not explorer verification or reviewer approval |

## 9. Known evidence gaps and release blockers

Before material mainnet use:

1. freeze and tag the exact source, lockfiles, compiler, dependencies, and static client;
2. regenerate and archive Slither, Halmos, full test, mutation, model, app, and bytecode receipts
   against that exact revision;
3. obtain an external security audit and resolve its findings;
4. implement, review, and operate the canonical evaluator profiles and independent verifier signing
   services—2-of-3 verifier integrity remains the central trust assumption;
5. exercise deployment tooling and the full sponsor/solver/verifier/refund/withdraw lifecycle on
   each intended public testnet and supported asset;
6. publish an unsigned observation plus a signed release dossier containing explorer/source exact
   match, token/proxy/issuer review, finality policy, frontend hash, smoke transactions, and reviewer
   signatures;
7. establish monitoring, deprecation, key-compromise, and incident procedures for an immutable
   deployment;
8. choose a source license and obtain launch-jurisdiction legal/tax review; and
9. separately implement and audit Solana before claiming Solana support.

## 10. Reproduction commands

From a clean checkout with the pinned toolchain:

```sh
make bootstrap
make check
```

`make check` covers Forge formatting/build/lint/tests, both invariant campaigns, model checks, both
mutation layers, static-client tests/build/audit/reproducibility, deployment-parser regression
tests, schema syntax, and two clean Solidity builds. The pinned Slither job runs separately in CI.
Halmos is intentionally separate; run and archive its four exact obligations explicitly.

Preserve versions, complete output, exit codes, source revision, and artifact hashes. Evidence
without revision binding is historical context, not proof about a later build.
