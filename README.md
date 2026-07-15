# Proof Bounty Escrow

Proof Bounty Escrow is a chain-local marketplace primitive for objectively replayable work. A sponsor funds a precisely specified bounty, independent solvers commit result digests, and the first committed result accepted by two of three fixed verifiers receives the advertised reward.

The best initial customers are protocol teams, security teams, research groups, and open-source maintainers who need a concrete counterexample, exploit reproduction, test vector, proof artifact, or other result that can be checked against a frozen evaluator. The job it helps them do is: **pay an unknown contributor for an accepted, reproducible result without trusting the sponsor to release escrowed funds after the work is delivered**.

For a solver looking for paid work, the complementary job is: **find a pre-funded, objectively
specified task whose payout no longer depends on the sponsor's discretion, commit privately, and
receive the advertised reward when the frozen verifier process accepts the result**. The protocol
does not find employment, negotiate scope, or judge subjective quality.

It is not a general employment marketplace. V1 has no applications, milestones, subjective dispute process, identity, reputation, messaging, token, governance, bridge, or upgrade mechanism.

## Status

This repository is pre-release. The implementation has substantial automated test and bounded-model evidence, but it has **not** been proven correct in an absolute sense, independently audited, or validated with material funds on every target chain. See [Security evidence](docs/security-evidence.md) before deployment.

The Solidity source is currently marked `UNLICENSED`. Choose and apply a license before public distribution.

## Implemented contracts

- `ProofBountyEscrowNative` escrows one chain's native currency.
- `ProofBountyEscrowERC20` escrows one immutable, vetted ERC-20 address per deployment.
- `ProofBountyEscrowBase` implements the shared state machine, EIP-712 attestations, accounting, and pull withdrawals.

Every deployment is immutable. There is no owner, proxy, pause, cancellation, fee update, verifier rotation, arbitrary call, or rescue function.

## Lifecycle

For commit deadline `C` and claim deadline `D`:

| Time | Available action |
| --- | --- |
| `now < C` | Any solver may record or replace its own nonzero commitment. |
| `C <= now < D` | Anyone may relay a claim for a committed solver with two valid verifier signatures. The first valid claim wins. |
| `now >= D` | Anyone may trigger the full refund if the bounty is still open. |

The sponsor pays the reward, a fixed 2% DevCo fee, a fixed 0.5% security-reserve fee, and an
explicit verifier pool from `max(2 smallest units, floor(0.5% of reward))` through 100% of reward.
The exact two-verifier pair is signed and splits that pool; profiles and sponsors can therefore price real
evaluation work instead of being trapped by a one-size-fits-all percentage. The solver receives
the full advertised reward. If no result is paid, the immutable refund recipient receives the
entire funded amount, including every proposed fee.

There is no protocol token.

V1 is deliberately not the final evaluation-market mechanism: reviewers are paid only when their
signatures settle an accepted result, so rejection and unused review can be unpaid. The
[V2 research specification](docs/evaluation-market-v2.md) designs prefunded, outcome-neutral
decision receipts, assigned work, availability quotes, stronger evaluator tiers, and exact proof
obligations without pretending that a token or fee creates dollars.

Fixed signing keys are also not the target verifier architecture. They remove mutable admin power
but make compromise and unavailability permanent. The [keyless ZK settlement design](docs/zk-settlement-v2.md)
instead freezes public verifier code and an evaluator image/circuit identifier, then binds every
value-moving proof to the exact bounty, solver commitment, artifacts, economics, and deadlines.
V1 should be treated only as a capped attestation pilot while that separate contract is specified,
implemented, and audited.

## Build and verify locally

Prerequisites are Node.js 20 or newer, Python 3, GNU Make, and Foundry. The release workflow pins Foundry `1.7.1`, forge-std `1.16.2`, Solidity `0.8.36`, OpenZeppelin Contracts `5.0.2`, and EVM target `paris`.

```sh
make bootstrap
make check
```

`make check` enforces formatting, a clean size-reporting build, high/medium Forge lint, the full
deterministic/fuzz/native-and-ERC-20 invariant suite, the finite model, model and Solidity source
mutations, deployment/schema checks, the static-client tests/build, and two-build reproducibility
checks. CI additionally runs a pinned Slither gate. See [Security evidence](docs/security-evidence.md)
for the exact assurance boundary and symbolic receipts.

## Deploy

Foundry scripts provide native and ERC-20 dry runs, broadcasts, immutable-configuration logging,
post-deployment runtime/configuration checks, and a clean-revision deployment-observation
generator. Copy `.env.example`, review every public value, then follow
[Operations](docs/operations.md). No mainnet or public-testnet contract address is claimed here.

Deploy an independent escrow on each chain and never bridge escrowed funds between deployments. The same EVM contracts target PulseChain, Ethereum, and the other listed EVM networks; no deployment addresses are claimed in this repository. Solana requires a separate future program and is not implemented. See [Cross-chain design](docs/cross-chain.md).

The repository includes an [IPFS-hostable static client](app/README.md) and strict schemas for job
listings, evaluator profiles, solver recovery packages, deployment observations, and reviewed
release dossiers. There is no canonical hosted release, indexer, verifier daemon, or live-address
registry. IPFS hosting does not make public-chain data private.

## Documentation

- [Protocol specification](docs/specification.md)
- [Threat model](docs/threat-model.md)
- [Tokenomics](docs/tokenomics.md)
- [Evaluation market V2 research specification](docs/evaluation-market-v2.md)
- [Keyless ZK settlement design](docs/zk-settlement-v2.md)
- [Marketplace website, IPFS, indexing, and ChatGPT architecture](docs/marketplace-architecture.md)
- [PulseTensor and PulseChain research roadmap](docs/pulsetensor-research-roadmap.md)
- [Privacy model](docs/privacy.md)
- [Cross-chain design](docs/cross-chain.md)
- [Security evidence](docs/security-evidence.md)
- [Operations and deployment](docs/operations.md)
- [Static client](app/README.md)
- [Off-chain package schemas](schemas/README.md)
