# Off-chain package schemas

The escrow stores only four opaque `bytes32` identifiers. These schemas define a minimal,
backend-free discovery and claim package without changing the contract or putting URIs on
chain.

Hash rules for V1 are deliberately byte-exact:

- `profileId = keccak256(profile artifact bytes)`;
- `specificationHash = keccak256(specification artifact bytes)`;
- `termsHash = keccak256(terms artifact bytes)`; and
- `resultDigest = keccak256(result artifact bytes)`.

Use `cast keccak <file>` from the pinned Foundry toolchain. Reformatting an artifact changes
its identifier. A listing may give multiple `ipfs://` or HTTPS mirrors, but a client must hash
the fetched bytes and compare them with the on-chain value before displaying or executing
anything.

`job-listing-v1` is an untrusted discovery record. A client validates its duplicated on-chain
fields against `getBounty`; it never treats an index or gateway as authoritative. Indexes can
be static files on IPFS, community mirrors, or user-supplied sources.

`claim-package-v1` contains everything a relayer needs to call `claim`. Keep its salt and
artifact locations private until the solver is ready to reveal. Relaying cannot redirect the
solver-bound reward, but premature publication can disclose the work.

`evaluator-profile-v1` freezes reproducibility and verifier policy. The contract does not run
or validate it. The profile also records expected verification effort and a recommended verifier
pool in basis points; the sponsor converts that recommendation into the explicit on-chain
`verifierFee`. The contract enforces a two-unit-or-0.5%-of-reward minimum and reward-sized maximum. Two
verifier keys can still attest dishonestly, so evaluator isolation, independent reproduction,
adequate compensation, and operational monitoring remain required.
