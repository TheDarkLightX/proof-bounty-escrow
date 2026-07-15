# Privacy model

## 1. Summary

V1 provides data minimization, not anonymity. PulseChain, Ethereum, and the targeted EVM networks are transparent ledgers. IPFS hosting can reduce dependence on a conventional web server, but it does not conceal transactions or make published content private.

No zero-knowledge circuit, mixer, shielded pool, private mempool, trusted execution environment, or confidential-compute service is implemented.

## 2. Public on-chain data

Anyone can observe or derive:

- chain ID and escrow address;
- native asset or ERC-20 address;
- DevCo, security reserve, and all three verifier addresses;
- sponsor, refund recipient, reward, total funding, and deadlines;
- profile, specification, and terms hashes;
- each committing solver address and commitment hash;
- the winning solver, result digest, salt in claim calldata, verifier indices, and signatures;
- terminal status and credited/withdrawn amounts;
- withdrawal account and destination from the event and transaction; and
- timing, gas payer, RPC propagation, contract interactions, and address history.

Even when a field is stored only as a hash, a low-entropy or publicly guessable value can be tested by dictionary attack.

## 3. What the commitment hides

Before claim, the contract publishes only:

```text
keccak256(typeHash, deploymentId, bountyId, solver, resultDigest, salt)
```

This can hide the result digest from casual observers if the solver uses a strong, unpredictable, single-use salt. It does not hide the solver address, bounty choice, transaction timing, or the existence of a submission.

Solvers should generate at least 128 bits of cryptographically secure salt entropy, encode it as a nonzero `bytes32`, keep it private until claim, never reuse it, and back it up. A lost salt makes the commitment unusable. A weak salt can permit brute-force recovery, especially if the result has a small candidate set.

At claim, the salt and result digest become public in calldata. Commitment privacy is therefore temporary.

## 4. Off-chain result confidentiality

The contract needs only a result digest, but at least two verifiers ordinarily need the underlying
result to evaluate it. A solver should first commit, wait for required finality, and wait until the
commit deadline before revealing the result to verifiers; disclosure before the boundary lets
another solver create a competing commitment from copied work. The result can remain off chain if
the evaluation profile permits, yet its confidentiality then depends on solver-verifier transport,
verifier storage, logs, backups, and access policy.

Publishing plaintext to IPFS makes it publicly retrievable by content hash wherever it is pinned or cached. Content addressing is not encryption. If an artifact must be private, encrypt it before publication, keep keys off chain, and understand that later key disclosure permanently exposes cached ciphertext content. Encryption and access-control key exchange are not part of V1.

Do not place personal data, credentials, private keys, undisclosed vulnerabilities, regulated data, or illegal content directly in transaction calldata or unencrypted public storage.

## 5. Address privacy

Fresh addresses can reduce simple account-history linkage, but they do not guarantee unlinkability. Gas funding, withdrawals, timing, repeated verifier interaction, exchange deposits, browser telemetry, RPC logs, and common ownership heuristics can reconnect them.

A relayer can submit a claim without becoming the solver, which can hide who paid claim gas. The solver address remains explicit in the claim and receives the credit. Withdrawal must be initiated by the credited account, and the `Withdrawal` event publicly links that account to its chosen destination. V1 is not a payout privacy tool.

Verifier addresses are intentionally public and fixed. Their signatures are public after settlement. Operational signing infrastructure should avoid leaking unrelated metadata, but it cannot hide verifier participation in a paid bounty.

## 6. Frontend and infrastructure metadata

The repository includes a static frontend that can be built and hosted on IPFS because contract
interaction occurs through an injected wallet and configured RPC. It ships without analytics,
telemetry, a remote CDN, or a required backend. Those properties reduce third-party collection but
do not make wallet/RPC/network activity anonymous.

An IPFS deployment can still depend on:

- DNS or ENS naming;
- gateway and pinning providers;
- RPC endpoints;
- wallet providers;
- indexers and analytics;
- source repositories and release channels; and
- browser storage, IP addresses, and telemetry.

For a privacy-conscious client, use multiple independently operated gateways and RPCs, avoid
analytics, make builds reproducible, publish hashes through independent channels, minimize logs,
and let users provide their own endpoints. Compute commitment and EIP-712 preimages locally; do not
send salts or unrevealed result digests through `eth_call`. These measures reduce metadata
concentration but do not create on-chain privacy.

## 7. Privacy claims that must not be made

Do not describe V1 as:

- anonymous;
- confidential;
- zero knowledge;
- untraceable;
- censorship-proof;
- immune to gateway or RPC observation; or
- capable of keeping a claimed result secret on chain.

An accurate claim is: **the contract stores fixed-size digests instead of full specifications and result artifacts, supports relayed claims, and never requires real-world identity, while all addresses, amounts, timing, hashes, signatures, and claim inputs remain publicly observable.**
