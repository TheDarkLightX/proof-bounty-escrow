# Proof Bounty Escrow static app

A backend-free browser client for the immutable EVM proof-bounty escrow contracts in this repository. The UI has neutral branding and is suitable for a conventional static host or IPFS.

## Build and verify

Requirements: Node.js 20.19 or newer and npm.

```sh
npm ci
npm run verify
npm run reproducibility
```

`npm run build` writes the complete static site to `dist/`. Vite uses a relative base path, so the directory can be added to IPFS as-is. The build contains all JavaScript and CSS dependencies; it loads no runtime CDN, font, image, analytics, or telemetry service.

For local testing:

```sh
npm run dev
```

Do not open `dist/index.html` with a `file:` URL. Browser module and CSP rules require an HTTP origin. `npm run preview` provides one. Production hosting should send `Content-Security-Policy: frame-ancestors 'none'` as an HTTP header; browsers ignore `frame-ancestors` in a meta policy. The app also refuses framed execution in JavaScript as defense in depth.

## Configure deployments

At runtime a user can type a chain ID, optional HTTP(S) RPC URL, contract address, and expected native/ERC-20 variant. The app verifies:

- the provider's chain ID;
- that runtime bytecode exists;
- the contract's `asset()` variant;
- EIP-712 name, version, chain ID, and verifying contract;
- the on-chain ERC-20 symbol and decimals when relevant; and
- current solvency.

When those fields are present in an imported manifest, it also requires exact matches for runtime code hash, asset, deployment ID, verifier-set hash, fee recipients, protocol name, and all three verifier addresses. A matching manifest still needs an authenticated distribution channel; importing an untrusted JSON file proves nothing about who published it.

Users can also import the repository's deployment-manifest JSON format. RPC URLs are deliberately not imported or saved.

A complete manifest bundled inside the same static release/CID is distinguished from manual input and user-imported JSON. Manual and imported targets are visibly marked as provenance-untrusted, and every wallet control stays disabled until the user makes an explicit independent-verification acknowledgement. The gate is a guardrail, not authentication; an attacker who controls the page can remove it, which is why users must authenticate the release/CID first.

The repository's deployment-observation schema binds the ERC-20 address and observed runtime code
hash, but it cannot establish a proxy implementation/admin, future issuer controls, symbol, display
decimals, or a due-diligence decision. Consequently this app never grants an ERC-20 target the
release-bundled trusted status merely from that observation; ERC-20 writes require the
untrusted-target acknowledgement plus injected-provider cross-checks. A signed release dossier
and complete asset review are required before that policy can safely be relaxed.

To bundle official choices into an IPFS release, replace `public/deployments.json` with:

```json
{
  "schemaVersion": 1,
  "deployments": [
    {
      "schemaVersion": 1,
      "deployment": {
        "network": "Example testnet",
        "chainId": 12345,
        "variant": "native",
        "contractAddress": "0x0000000000000000000000000000000000000001"
      },
      "configuration": {
        "protocolName": "Example Proof Bounties",
        "asset": "0x0000000000000000000000000000000000000000"
      }
    }
  ]
}
```

Use complete authenticated manifests in a real release. The UI intentionally does not claim that a live address matches audited source merely because its public interface responds.

## Supported operations

- Read the latest 12 bounties or a specific ID without an indexer.
- Create native-currency or vetted exact-transfer ERC-20 bounties with a sponsor-declared absolute verifier pool. The UI queries the contract's minimum (approximately 0.5%, but always at least two smallest asset units) and 100%-of-reward maximum, suggests an editable 5%, and shows the two-signer split and full funding separately.
- Set or clear an exact ERC-20 allowance.
- Compute and submit a solver commitment.
- Generate a cryptographically random 32-byte salt with Web Crypto.
- Download/import a local solver recovery package containing the salt and result digest.
- Build the exact EIP-712 verifier request locally, but only after a chain-timestamp check proves the commit phase closed and a public read proves the exact solver commitment is stored. The request includes an explicitly unsigned `claimReveal` so a verifier can recompute the commitment before signing.
- Relay a claim carrying two prebuilt 65-byte verifier signatures.
- Permissionlessly mark an expired bounty refunded.
- Read and withdraw the connected account's pull-payment credit.
- Compute keccak256 of exact local file bytes or UTF-8 text without uploading it.

Immediately before every state-changing call, the app requires the injected provider to match the verified chain-history anchor, then re-reads escrow bytecode and immutable configuration through it, simulates through that same provider, sends with that wallet, and observes inclusion/finality from that provider. For ERC-20 deployments it also compares the asset's runtime code hash, symbol, and decimals. Native-currency parsing is deliberately limited to the standard 18-decimal EVM convention. The contract remains authoritative about phase boundaries and validity.

## Deliberate limitations and privacy

The app has no database or indexer and stores no configuration, account, result, salt, or RPC URL in cookies or browser storage. Page reloads clear in-memory values. A downloaded recovery package is an unencrypted secret-bearing file; the user is responsible for protecting it.

Commitments are calculated entirely in-browser as `keccak256(abi.encode(...))`; result digests and salts are never sent to an RPC by commitment or attestation-preparation helpers. Relaying a claim necessarily reveals the claim calldata to the injected wallet provider during preflight simulation and then publishes it in the transaction, so only do that after the commit phase closes.

The app does not upload, pin, fetch, parse, or validate IPFS content. A sponsor should canonicalize a job manifest, hash those exact bytes in the browser, publish the same bytes with an independent IPFS client, and distribute the CID separately. The contract stores the bytes32 hash, not the CID.

No frontend can make normal EVM activity private. The injected wallet and RPC can correlate requests with an IP address, while addresses, calldata, timings, values, and hashes are public on-chain. Private browsing, self-hosted RPC/IPFS infrastructure, separate funded addresses, and careful manifest contents can reduce correlation but cannot provide anonymity.

The frontend is an operator aid, not a bytecode audit, verifier, privacy system, hosted marketplace index, legal review, or token-safety oracle.

The 5% verifier-pool suggestion is not a claim that 5% is economically adequate. Sponsors should price the evaluator profile's real compute, review time, latency, operational risk, and independence requirements. The two verifiers whose signatures settle the claim each receive `floor(pool / 2)`; an odd smallest-unit remainder goes to the security reserve. The profile and off-chain operating agreement must address whether non-signing or unsuccessful reviewers are compensated.

Runtime hashing alone does not establish an upgradeable token proxy's current or future implementation, admin, blacklist, pause, or storage state. Production ERC-20 deployment review must bind and continuously monitor the complete token/proxy identity outside this app; immutable native-currency deployments have a smaller trust surface.
