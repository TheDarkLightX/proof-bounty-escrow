# PulseTensor and PulseChain research roadmap

> **Status: evidence-backed roadmap; not an implementation claim.** This document records public
> sources reviewed on 2026-07-15 and explains how Proof Bounty Escrow can become one value-moving
> component of PulseTensor. Public issue reports are signals, not a representative community
> survey. The immutable V1 escrow does not implement a subnet network, evaluator daemon, proof
> system, indexer, grants program, or the V2 market described here.

## 1. What “Bittensor level” actually requires

Bittensor is more than an escrow or token. Its current official architecture has subnet owners
define incentive mechanisms, miners produce off-chain digital commodities, validators score
miners, stakers economically weight validators, Yuma Consensus aggregates the weights, and the
chain distributes TAO/alpha emissions. Its SDK, CLI, wallet model, metagraph, registration,
delegation, subnet lifecycle, queries, and transaction tooling form a complete operator surface.

Primary sources:

- [current network roles](https://github.com/RaoFoundation/subtensor/blob/32f3b652cfa74df5f8f595a5be051bf5bb86925f/docs/concepts/network.mdx);
- [current emissions and Yuma flow](https://github.com/RaoFoundation/subtensor/blob/32f3b652cfa74df5f8f595a5be051bf5bb86925f/docs/concepts/emissions.mdx);
- [current money, alpha, fees, and slippage model](https://github.com/RaoFoundation/subtensor/blob/32f3b652cfa74df5f8f595a5be051bf5bb86925f/docs/concepts/money.mdx); and
- [original whitepaper](https://www.bittensor.com/whitepaper).

At the source revision reviewed here, useful work and scoring occur off chain. Yuma uses
stake-weighted consensus, clipping, bonds, and dividends to aggregate validator weights. That is
an economic agreement mechanism about scores; it is not a cryptographic proof that an output
satisfies an external specification. Current subnet emission also depends on market and staking
state, and each subnet alpha is a volatile asset whose spot value can differ from realizable exit
value after fees and slippage.

The following are inferences from those sources, not claims made by Bittensor:

- Stake and market price can provide Sybil resistance and capital allocation, but neither is a
  proof of computation correctness.
- An inflation-funded owner allocation is a subsidy in a volatile asset, not customer revenue or
  a source of dollars.
- PulseTensor should copy the useful systems surface—worker/validator protocols, discovery,
  lifecycle, SDK/CLI, observability, and task-specific incentives—without copying assurance or
  token assumptions that do not fit PulseChain demand.

Recent Bittensor research is also a warning against one universal score. A preliminary network
study reports stake/reward concentration across observed subnets
([preprint](https://arxiv.org/abs/2507.02951)); work on Subnet 9 describes winner-take-all incentives
and model-hoarding pressure ([preprint](https://arxiv.org/abs/2507.17766)); and Gauntlet evaluates
marginal-loss contribution scoring, uniqueness checks, and reliability filtering
([preprint](https://arxiv.org/abs/2505.21684)). These papers require independent methodology
review, but they support testing incentive rules per task rather than declaring one mechanism
universally truthful.

## 2. What PulseChain public signals suggest

Official starting points are the [PulseChain developer page](https://pulsechain.com/develop), the
[official GitLab group](https://gitlab.com/pulsechaincom), the
[mainnet repository README](https://gitlab.com/pulsechaincom/pulsechain-mainnet/-/blob/873716af300a7ea4612423d5fb5fb7093bd0a9ad/README.md),
and the [explorer version metadata](https://scan.pulsechain.com/version.json). The developer page
primarily exposes generic EVM tooling, public RPC/GraphQL endpoints, explorer verification, and
community support. The mainnet README documents the copied Ethereum state and explicitly welcomes
additional explorers.

Open public reports include:

- [contract verification failure](https://gitlab.com/pulsechaincom/pulsechain-mainnet/-/work_items/258),
  where another verification service accepted the same source;
- [explorer API failures affecting tax integration](https://gitlab.com/pulsechaincom/pulsechain-mainnet/-/work_items/247);
- [difficulty obtaining current price data for an accessibility project](https://gitlab.com/pulsechaincom/pulsechain-mainnet/-/work_items/252);
- [WalletConnect trouble on the explorer surface](https://gitlab.com/pulsechaincom/pulsechain-mainnet/-/work_items/260);
- [slow public-RPC transaction propagation](https://gitlab.com/pulsechaincom/erigon-pulse/-/work_items/6);
- historical reports involving [failed transaction status](https://gitlab.com/pulsechaincom/pulsechain-mainnet/-/work_items/208),
  [Hardhat deployment hangs](https://gitlab.com/pulsechaincom/pulsechain-mainnet/-/work_items/233),
  and [transaction export](https://gitlab.com/pulsechaincom/pulsechain-mainnet/-/work_items/184).

These reports vary in age and may be stale. They do not prove community-wide priority. The
evidence-bounded inference is that useful initial work includes:

1. reproducible deployment, source verification, and contract-provenance tooling;
2. finality-aware multi-RPC observation, indexer health, and transaction-status reconciliation;
3. machine-verifiable project discovery tied to chain ID, deployed runtime, source revision, and
   authenticated release evidence;
4. accessible exports and stable developer interfaces; and
5. self-hostable evaluator and monitoring infrastructure.

The copied Ethereum state makes provenance especially important: a familiar address or historical
balance does not by itself show that a PulseChain project is intended, maintained, or safe. No
official grant, DAO treasury, or durable developer-funding program was found on the official
surfaces reviewed. That is not proof none exists; a business plan must simply not assume one.

## 3. Build sequence

### Stage 0 — finish the narrow native-PLS escrow

Keep the first release an explicitly capped native-PLS open-prize pilot. Complete independent
audit, finality/reorg policy, verifier proof-of-possession and readiness receipts, one frozen
evaluator profile, testnet lifecycle rehearsal, signed release dossier, monitoring, and exposure
caps. Do not activate arbitrary ERC-20 assets merely because an exact-transfer mock passes.

The V1 contract guarantees only its encoded accounting and authorization transitions under named
assumptions. Two verifier keys still attest; the contract does not execute or prove the evaluator.

### Stage 1 — reproducible evaluator plane

Build a self-hostable runner and verifier service before a generalized market:

- content-addressed evaluator package and OCI image digest;
- architecture, kernel/VM, filesystem, environment, time, randomness, network, syscall/device, and
  resource policies;
- canonical input, output, reason-code, and execution-receipt encodings;
- independent replay by each verifier from a finalized chain anchor;
- signed readiness, availability, decision, and software-supply-chain receipts;
- no signing key in the runner process; and
- deterministic public conformance vectors and hostile mutations.

This converts opaque “we ran it” signatures into reproducible evidence without overstating that
reproduction proves human intent.

### Stage 2 — provenance and discovery plane

Build an authenticated, mirrorable registry/indexer whose records bind:

- chain ID, deployment address, creation transaction and finalized block hash;
- runtime, creation input, constructor arguments, compiler input, dependency, and source-tree
  hashes;
- active/deprecated release status and independent reviewer signatures;
- evaluator, specification, terms, result, and artifact roots; and
- RPC/indexer disagreement and finality status.

The frontend should be static/self-hostable, accessible, exportable, and able to verify records
against multiple RPC operators. Indexes remain caches; contract state and authenticated release
evidence remain authoritative for their respective claims.

### Stage 3 — keyless objective settlement

Implement the separate [keyless ZK settlement design](zk-settlement-v2.md) for one narrow relation.
Freeze public verifier bytecode, evaluator image/circuit ID, input encoding, and artifact hashes;
bind the proof journal to the exact chain, deployment, bounty, solver commitment, economics, and
deadlines. The value path contains no secret verifier authority. Prove/model conservation,
single-settlement, commitment binding, journal completeness, and verifier isolation, then audit and
pilot it with capped native PLS.

### Stage 4 — Evaluation Market V2 fallback

Implement the separate [V2 specification](evaluation-market-v2.md): explicit open-prize and
assigned-job modes, signed expiring evaluator quotes, bounded committees, outcome-neutral payment
for valid `ACCEPT` or `REJECT` receipts, artifact availability, separate reward/refund and review
budgets, and narrowly provable fault penalties. This is the explicitly lower-assurance path for
jobs without a proof-backed relation. It must not reuse permanent V1 keys. Start with an off-chain
shadow ledger, then an executable model, then a new contract whose value transitions refine that
model.

### Stage 5 — additional objective verification adapters

Add one relation at a time:

1. deterministic replay receipts;
2. independent committee replay;
3. optimistic computation with a bonded challenge game;
4. a succinct proof verified by frozen on-chain code/key; and
5. theorem artifacts checked by a small pinned proof kernel.

Every adapter names the exact theorem/relation, input encoding, semantics, trusted computing base,
proof-system assumptions, and revision. A proof of the wrong specification is still wrong for the
user.

### Stage 6 — PulseTensor network surface

Only after the value and evaluator planes work should PulseTensor add Bittensor-like network
ergonomics:

- worker and evaluator registration with explicit Sybil/conflict policy;
- task/subnet manifests and lifecycle;
- miner/evaluator protocol SDK, CLI, local simulator, conformance suite, and reference nodes;
- signed capability/price/availability discovery;
- contribution/reliability metrics with reproducible raw evidence;
- dashboards, export APIs, incident/deprecation feeds, and community-operated mirrors; and
- optional staking or bonds only for precisely modeled roles and slashable faults.

Initial rewards should remain sponsor-funded rather than require a new token. A later subsidy or
staking asset would need its own demand thesis, manipulation model, liquidity analysis, governance,
legal review, and proof that it improves the service rather than obscures revenue.

## 4. Research foundations and limits

Reviewer truth cannot be obtained by paying for agreement alone. Classic peer prediction makes
truthful reporting an equilibrium under correlated-signal/common-prior assumptions
([Miller, Resnick, and Zeckhauser](https://doi.org/10.1287/mnsc.1050.0375)), while later work shows
undesirable and collusive relabeling equilibria remain a fundamental concern
([Kong and Schoenebeck](https://arxiv.org/abs/1603.07751)). Multi-task mechanisms can induce effort
under additional assumptions ([Dasgupta and Ghosh](https://arxiv.org/abs/1303.0799)), and proper
scoring rules can elicit probabilities when objective outcomes later resolve
([Gneiting and Raftery](https://doi.org/10.1198/016214506000001437)). These are routing/reputation
tools, not roots of safety when no ground truth exists. The oracle-security literature likewise
shows that off-chain facts introduce an explicit trust model
([SoK](https://arxiv.org/abs/2106.00667)).

The high-assurance path is closer to proof-carrying code: the producer supplies an artifact and a
machine-checkable proof against an explicit consumer policy
([Necula](https://doi.org/10.1145/263699.263712)). Correct-by-design transition systems
([VeriSolid](https://arxiv.org/abs/1901.01292)) and formal EVM semantics
([KEVM](https://doi.org/10.1109/CSF.2018.00022)) show how to state and reduce the
model-to-execution gap. Succinct verifiable computation
([Pinocchio](https://doi.org/10.1109/SP.2013.47)), interactive verification games
([TrueBit-style analysis](https://arxiv.org/abs/1908.04756)), and proof-generation markets
([Prooφ](https://arxiv.org/abs/2404.06495)) provide stronger objective tiers with their own
soundness, setup, capacity, collusion, and liveness assumptions.

A digest proves identity of bytes, not delivery or persistence. FairSwap uses a contract as a
dispute judge for off-chain digital goods ([paper](https://eprint.iacr.org/2018/740)); fraud and
data-availability work separates validity from retrievability
([paper](https://arxiv.org/abs/1809.09044)); and proofs of retrievability address continued storage
under a particular challenge model
([Juels and Kaliski](https://doi.org/10.1145/1315245.1315317)). PulseTensor must fund and specify
availability rather than infer it from an accepted hash.

## 5. What “beyond” should mean

PulseTensor is beyond Bittensor only if the comparison is testable:

- every value movement refines a published state machine and preserves conservation;
- every payment binds the exact worker, evaluator/committee, evidence, economics, and deadline;
- users can distinguish economic consensus, deterministic replay, optimistic verification,
  succinct proof, and theorem checking;
- public artifacts bind source, bytecode, evaluator, chain state, and release revision;
- reviewer incentives do not pay only for approval;
- revenue is reported in received asset units, separately from volatile external valuations; and
- deployment, discovery, monitoring, and recovery paths are usable without surrendering keys to a
  hosted operator.

No formal method guarantees demand, honest human intent, PLS price, dollars, liquidity, artifact
persistence, chain finality, or safe arbitrary tokens. Those remain explicit operational and
economic assumptions, not footnotes hidden behind “verified.”
