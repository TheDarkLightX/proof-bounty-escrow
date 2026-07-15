# Cross-chain design

## 1. Principle: repeat the escrow, never bridge it

Each network gets an independent deployment that holds only that network's local asset. Bounties, commitments, signatures, credits, and withdrawals exist on one chain only. There is no cross-chain message, canonical global bounty ID, shared vault, wrapped claim, or bridge custody.

This design contains failures. A bridge exploit, sequencer outage, token failure, verifier-key incident, or contract problem on one deployment does not directly move assets held by another deployment.

A unified frontend may index multiple deployments and present a common workflow, but it must always display and sign the selected chain ID, contract address, asset, deployment ID, verifier set, and deadlines. “Same product” must never be presented as “same escrow balance.”

## 2. EVM portability

The current contracts are compiled for Solidity `0.8.36` with optimizer 200, no IR pipeline, and EVM target `paris`. The conservative target avoids depending on newer opcodes that are not uniformly available across all intended networks.

The implemented source is designed for the following independent EVM deployments:

| Network | Chain ID | V1 deployment status |
| --- | ---: | --- |
| Ethereum | 1 | Target only; no address published here |
| PulseChain | 369 | Target only; no address published here |
| Base | 8453 | Target only; no address published here |
| Arbitrum One | 42161 | Target only; no address published here |
| OP Mainnet | 10 | Target only; no address published here |
| Polygon PoS | 137 | Target only; no address published here |
| BNB Smart Chain | 56 | Target only; no address published here |
| Avalanche C-Chain | 43114 | Target only; no address published here |

Listing a chain is a design target, not evidence of compatibility, deployment, audit, explorer verification, RPC behavior, or safe use with material funds. Every chain requires its own testnet exercise, deployment review, bytecode verification, finality policy, monitoring, and asset due diligence.

Suggested pre-production networks are:

| Network | Chain ID |
| --- | ---: |
| Ethereum Sepolia | 11155111 |
| PulseChain Testnet V4 | 943 |
| Base Sepolia | 84532 |
| Arbitrum Sepolia | 421614 |
| OP Sepolia | 11155420 |
| Polygon Amoy | 80002 |
| BNB Smart Chain Testnet | 97 |
| Avalanche Fuji | 43113 |

Network operators can change RPC URLs, explorer APIs, and testnet availability. A release manifest should record observed chain ID from RPC at deployment rather than trust a UI label.

## 3. Deployment identity and replay resistance

Every independently configured deployment receives a distinct `deploymentId` because it binds
chain ID, escrow address, asset, fee recipients, and verifier-set hash. EIP-712 also binds current
chain ID and verifying contract. A fork or state clone that preserves both chain ID and contract
address is not a distinct EIP-712 domain, so verifiers must sign only against their approved,
finalized chain view.

Consequences are intentional:

- an Ethereum commitment is not a PulseChain commitment;
- a native-asset commitment is not an ERC-20 commitment;
- a signature for one contract address is not valid for another address;
- a deployment with different fee recipients or verifiers has a different identity; and
- bounty ID `1` on two deployments represents unrelated bounties.

Clients must compute commitments and attestation typed-data digests locally from verified public
deployment state. Result digests and salts must not be disclosed to an RPC just to invoke a view
helper. Do not construct one chain's payload and mechanically replay it elsewhere.

## 4. Native and ERC-20 deployment profiles

`ProofBountyEscrowNative` should be deployed once per intended native-currency market.

`ProofBountyEscrowERC20` should be deployed once per vetted token address per chain. A token with the
same name or symbol on two chains is not the same asset, and a bridged token inherits bridge and
issuer risk. The generated observation identifies token address and code hash. The signed release
dossier must additionally bind display decimals, issuer/upgrade status, and the due-diligence
decision.

The contract's accounting is unit-agnostic and does not call `decimals`. Interfaces must never use symbol or decimals to identify the asset. Amounts passed to the contract are integer smallest units.

Only exact-transfer, stable-behavior ERC-20s are supported. Token-issuer pause, blacklist, upgrade, fee, hook, rebase, or balance deception can prevent funding, withdrawal, or solvency even if the escrow source is unchanged.

## 5. Chain-specific operational risk

- **Ethereum and EVM L1s:** wait for an explicit finality policy before showing a bounty as irreversibly paid or refunded.
- **Optimistic and sequencer-based L2s:** distinguish unsafe, safe, and finalized views where the RPC exposes them; plan for sequencer downtime and L1 settlement delay.
- **Low-cost EVM chains:** lower gas enables small bounties but does not reduce verifier, token, bridge, or governance risk.
- **All chains:** avoid very short commit and claim windows. Timestamp variance, congestion, RPC failure, reorg, and censorship can make a technically open phase operationally unusable.

The contract itself does not encode a confirmation count. Indexers and frontends should implement a versioned policy per chain and show whether data is pending, safe, or finalized.

## 6. Multi-chain product architecture

A decentralized client can remain static and IPFS-hostable if it consumes a signed or content-addressed deployment registry. A future registry should contain, per release:

- product and protocol version;
- chain ID and human-readable network label;
- escrow address and adapter type;
- asset address or native marker;
- deployment ID and verifier-set hash;
- DevCo, security reserve, and each verifier address;
- deployment transaction and block;
- compiler version and settings;
- verified runtime/source references;
- frontend ABI hash;
- finality policy; and
- status such as test, active, deprecated, or incident.

The registry must not silently replace an address. A new contract is a new deployment entry, and old bounties remain on the old chain-local contract.

The repository includes a versioned target-network catalog, strict schemas for unsigned deployment
observations and reviewed release dossiers, and a static multi-chain client that can be built for
IPFS. It does not contain a populated live-address registry, signed active release dossier, hosted
IPFS release, or indexer.

## 7. Solana: separate future implementation

The Solidity contracts cannot be deployed to Solana. A Solana version would be a separate Rust program with separate review, tests, proof obligations, addresses, signatures, and deployment procedures. It is a design direction only; no Solana code or evidence exists here.

A faithful future design should map the same logical rules to Solana primitives:

- immutable configuration account for fee recipients and a three-key/two-signature verifier policy;
- bounty PDA for frozen terms, amounts, deadlines, status, and winner;
- per-bounty/per-solver commitment PDA so solvers do not block each other;
- program-controlled SOL vault or one vetted SPL-token vault per asset profile;
- atomic claim transition with two distinct Ed25519 verifier attestations checked from transaction instructions;
- full expiry refund to the frozen recipient;
- pull-style or explicit beneficiary withdrawals with conservation checks;
- domain separation binding Solana genesis identity, program ID, configuration account, bounty account, solver, terms, result, and deadline; and
- terminal paid/refunded state with no bridging.

For SPL assets, the implementation must explicitly decide whether classic SPL Token or Token-2022 extensions are supported. Transfer fees, hooks, confidential transfers, permanent delegates, freezes, and mutable token authorities cannot be treated as equivalent to the exact-transfer EVM profile.

Solana upgrade authority must be an explicit launch decision. To match EVM V1 immutability, the reviewed program's upgrade authority would need to be irreversibly revoked after deployment and bytecode verification. Keeping an upgrade authority creates a materially different trust model and must be disclosed.

EVM EIP-712 signatures and encodings must not be reused. Cross-platform conformance requires shared semantic vectors with platform-specific canonical encodings and independent adversarial testing before any claim of equivalence.
