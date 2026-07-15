# Marketplace delivery architecture

> **Status:** the wallet client and V1 escrow operations exist. Open discovery, IPFS publishing,
> durable pinning, event indexing, a proof-backed evaluator, and a canonical hosted release do not.
> This document distinguishes deployable code from the next implementation work.

## 1. What can be launched from this repository

`app/` is already a static Vite/TypeScript/viem application. It can:

- authenticate a deployment manifest against live bytecode and immutable configuration;
- browse recent on-chain bounty IDs and read one arbitrary ID;
- create and fund native or reviewed exact-transfer ERC-20 bounties;
- compute and submit solver commitments without sending preimages to an RPC;
- export/import a local secret-bearing solver recovery package;
- prepare a signer-pair-bound V1 attestation request from finalized public state;
- relay a claim, trigger a refund, and withdraw pull-payment credit; and
- hash exact local artifact bytes.

The build uses relative URLs and has no runtime CDN, analytics, cookie, or hosted application
dependency, so `app/dist/` can be served from an ordinary HTTPS origin or added to IPFS. That makes
it an operator console and transaction client. It is not yet a searchable public marketplace.

The V1 claim screen reflects the currently implemented fixed-key attestation contract. The target
objective-job interface must instead consume the proof and journal defined in
[Keyless ZK settlement](zk-settlement-v2.md). A fixed-key screen must remain visibly labeled as a
lower-assurance legacy/pilot path.

## 2. Minimal no-mandatory-backend topology

```text
immutable SPA CID
      |
      +---- injected wallet --------> PulseChain transaction submission
      |
      +---- user-selected RPC ------> finalized blocks, calls, and event logs
      |
      +---- IPFS gateways/nodes ----> verified listing and artifact bytes
      |
      +---- local IndexedDB --------> rebuildable finalized search cache

optional community indexers and gateways accelerate this graph but never authorize value.
```

The chain is authoritative for bounty state and settlement. IPFS is authoritative only for bytes
under a CID. The client authenticates protocol artifacts by recomputing the exact on-chain Keccak
digest; a URI, gateway response, catalog entry, or MIME type is never enough.

At pilot volume, a browser can reconstruct the market by scanning finalized contract events with
`eth_getLogs`, reading current bounty state, and caching a cursor and finalized block hash in
IndexedDB. A community GraphQL/Postgres indexer may provide full-text search and analytics later,
but every response must expose its indexed-through block and be independently checkable.

## 3. Why IPFS is not “the backend”

IPFS provides content addressing and distribution. It does not inherently provide:

- a reverse mapping from the escrow's Keccak digest to a CID;
- marketplace search, filters, pagination, or current chain status;
- persistence when nobody pins the blocks;
- private storage for salts, recovery packages, or unrevealed work;
- evaluator or proof computation;
- API-key-safe browser uploads;
- notifications, finality monitoring, or reorg recovery; or
- a wallet or transaction-signing security boundary.

The browser can construct and validate IPFS content, but a browser tab is not a durable provider.
Production content needs intentional replication and retrieval monitoring. Pinning-service tokens
must not be embedded in the public SPA. The safe initial publisher exports a deterministic CAR,
imports it into a local node, and replicates it to multiple independent operators or pinning
services. Kubo's administrative RPC must never be exposed to the public Internet
([Kubo RPC security](https://docs.ipfs.tech/reference/kubo/rpc/)).

Use origin-isolated CID subdomain or DNSLink gateways for a web application; path gateways share an
origin between unrelated content and are not a safe application origin
([IPFS gateway security](https://docs.ipfs.tech/concepts/ipfs-gateway/)). The immutable release CID
is the auditable application identity even when a mutable DNSLink name points to the latest release.

## 4. Public artifact package

One bounty package should be a deterministic directory/CAR:

```text
/
  listing.json
  profile.json
  specification.bin
  terms.json
  integrity.json
  artifacts/...
```

Creation is necessarily two-stage because the finalized bounty ID does not exist until after the
funding transaction:

1. freeze profile, specification, and terms bytes;
2. compute their exact Keccak digests and pin those artifacts;
3. fund the bounty with those digests;
4. wait for the creation receipt to reach the declared finality policy;
5. construct `listing.json` with the exact chain, deployment, bounty, economics, deadlines, and
   artifact URIs;
6. validate it against `job-listing-v1`, build the deterministic IPFS root, and replicate it;
7. publish the listing CID through the discovery mechanism; and
8. have every reader compare duplicated fields to finalized on-chain state and fetched bytes to
   the frozen digests.

Public result bytes must not be uploaded before the commit phase closes. Otherwise another worker
can copy the work and create a competing commitment. Solver salts and recovery packages never
belong on public IPFS. Confidential work requires a separately reviewed encryption and key-release
protocol; transport encryption does not make IPFS content private
([IPFS privacy model](https://docs.ipfs.tech/concepts/privacy-and-encryption/)).

## 5. Open discovery primitive

The V1 escrow stores artifact digests but no reversible CID. Manual bounty ID + CID sharing is
enough for a pilot, but not an open market. The smallest decentralized discovery addition is a
separate, event-only listing registry:

```solidity
interface IProofBountyListingRegistry {
    event ListingPublished(
        address indexed escrow,
        uint256 indexed bountyId,
        address indexed sponsor,
        bytes32 deploymentId,
        bytes32 listingKeccak,
        bytes rootCid
    );

    function publish(
        address escrow,
        uint256 bountyId,
        bytes32 listingKeccak,
        bytes calldata rootCid
    ) external;
}
```

The implementation holds no asset and has no owner, upgrade, pause, fee, or withdrawal. It reads
the bounty and deployment ID, requires the caller to be that bounty's sponsor, rejects zero or
oversized values, and emits metadata. It does not bless the listing. Clients select the latest
finalized sponsor event, fetch the bytes, validate the schema, compare the listing hash, and
reconcile every field with the escrow.

This registry should be a separate reviewed PR. It must not be folded into V1 custody code or made
an authority over proof verification.

## 6. Browser index and optional service index

The canonical low-volume scanner should:

- start from the deployment block in the authenticated release manifest;
- scan only configured escrow and registry addresses in bounded block ranges;
- reduce its range on provider-limit errors;
- cache `(chainId, deploymentId, finalizedBlockNumber, finalizedBlockHash)`;
- verify the cached block hash before resuming and replay a safety window after endpoint changes;
- derive discovery/history from events but read current status directly from the contract;
- label non-finalized observations as provisional; and
- fail closed for deadline-sensitive signing/proving when the provider cannot supply the release's
  required finality signal.

An optional self-hosted indexer can add search, tags, pagination, subscriptions, and aggregate
metrics. Its core entities are `Deployment`, `Bounty`, `ListingAnnouncement`, `Commitment`,
`Settlement`, `Refund`, `Withdrawal`, and `IndexerCheckpoint`. It is a rebuildable cache, never the
source of funds, deadlines, proof acceptance, or artifact integrity.

## 7. Frontend and SDK work

The single-file client should be incrementally split into:

```text
app/src/router.ts                 IPFS-safe hash routes and shareable bounty URLs
app/src/chain/events.ts           exact event definitions and decoding
app/src/chain/indexer.ts          finalized scans, chunking, cache, and rollback
app/src/content/ipfs.ts           bounded verified retrieval and gateway selection
app/src/content/listings.ts       strict schemas and on-chain reconciliation
app/src/content/publisher.ts      CAR export and user-selected publishing adapters
app/src/pages/MarketPage.ts       search, filters, pagination, and finality state
app/src/pages/BountyPage.ts       verified content and complete activity history
app/src/pages/CreatePage.ts       artifact authoring, hash, fund, package, announce
app/src/pages/SolvePage.ts        result, commitment, recovery, and proof workflow
app/src/pages/AccountPage.ts      credits, withdrawals, and transaction receipts
```

Publish the security-sensitive logic as a small pure TypeScript SDK with injected transports:

```text
validateDeployment
scanFinalizedBounties
fetchAndValidateListing
fetchVerifiedArtifact
buildBountyRequest
computeCommitment
buildZkStatement
verifyProofReceipt
simulateAndSend
```

A strict `marketplace-config/v1` file should contain branding-safe text/tokens, deployment and
registry identities, start blocks, runtime hashes, gateway templates, source revision, release CID,
and reproducibility hash. Anyone can use that SDK and configuration to build another frontend.
That makes frontends permissionless; it does not make every frontend trustworthy. Conformance
vectors and deployment revalidation remain mandatory before wallet writes.

## 8. ChatGPT surface

ChatGPT/Codex can generate and maintain an ordinary standalone frontend, and the reference Vite
application already exists. A ChatGPT App is a different surface: it uses an HTTPS MCP server and
optional sandboxed UI component. It is appropriate for read-only tools such as:

```text
search_bounties
get_bounty
verify_artifact
explain_deadlines
get_market_stats
search_evaluator_profiles
```

Wallet signing and crypto transfers must remain in the standalone top-level DApp. Besides the
security benefit, current public ChatGPT app rules prohibit executing crypto transfers, and Apps
SDK components run in a sandboxed frame. The existing wallet app deliberately refuses framed
execution. See the official [Apps SDK architecture](https://developers.openai.com/apps-sdk/concepts/mcp-server),
[UI model](https://developers.openai.com/apps-sdk/build/chatgpt-ui), and
[app guidelines](https://developers.openai.com/apps-sdk/app-guidelines).

The safe product split is:

```text
ChatGPT companion     discover, explain, compare, and verify public evidence
standalone website    connect wallet, simulate, approve, sign, and broadcast
smart contract        custody, deadlines, proof gate, and settlement
IPFS                  immutable public artifacts and audited release snapshots
event scanner/indexer discovery and search
```

ChatGPT Sites may host an ordinary site, but that hosting is not IPFS and injected-wallet behavior
must be tested rather than assumed. The canonical wallet release should remain reproducibly
buildable and independently hostable.

## 9. Implementation order

| Order | Deliverable | Current status |
| ---: | --- | --- |
| 1 | Harden V1 accounting/deployment and label its fixed-key boundary | Implemented in this PR; pre-release evidence only |
| 2 | Publish the static client on a normal HTTPS test origin and mirror its exact build on IPFS | Build exists; no canonical deployment |
| 3 | Add hash routing, finalized event scanning, IndexedDB, verified listing/profile fetch, and search | Not implemented |
| 4 | Add deterministic CAR export, local-node/pinning adapters, replication policy, and retrieval probes | Not implemented |
| 5 | Implement and test the event-only listing registry | Specified above; not implemented |
| 6 | Implement one keyless ZK evaluator and the new proof-gated native-PLS escrow | Specified; not implemented |
| 7 | Run create -> pin -> fund -> announce -> commit -> prove -> settle/refund end to end on testnet | Not run |
| 8 | Add optional community indexer and read-only ChatGPT MCP companion | Not implemented |
| 9 | External audit, adversarial pilot, exposure caps, operations, and incident rehearsal | Release blocker |

The website is not the hard unsolved part. The hard parts are defining the correct evaluator
relation, binding its proof to value movement, keeping artifacts available, rebuilding discovery
from finalized events, and operating all of that without turning an indexer, gateway, pinning key,
or ChatGPT server into a hidden authority.

