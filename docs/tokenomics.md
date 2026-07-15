# Tokenomics and fee economics

## 1. No protocol token

V1 has no token, issuance schedule, staking pool, liquidity program, governance voting, emissions,
or promised appreciation. Economic value comes from successfully paid bounties, not from selling
an asset to later participants.

This avoids a speculative security budget and keeps every obligation denominated in the escrow
asset. It also means there is no token-holder subsidy, liquidity moat, or on-chain governance
treasury.

## 2. Sponsor-funded surcharge and verifier budget

For advertised solver reward `R`, the sponsor chooses an explicit verifier pool `V` and deposits:

```text
DevCo fee          = floor(R * 2.00%)
Verifier pool      = V
Security fee       = floor(R * 0.50%)
Required funding   = R + all three components
Allowed V          = max(2 units, floor(R * 0.50%)) through R
```

Rewards below two smallest units are invalid. The two-unit dust floor ensures each signing
verifier can receive at least one unit; the reward-sized maximum limits obvious configuration
mistakes. Neither bound says the minimum is economically adequate. Evaluator
profiles should publish expected effort and a recommended pool, and verifiers should refuse work
whose declared pool does not cover independent reproduction and operational risk.

The solver receives the full advertised reward. DevCo, verifier, and reserve amounts are sponsor
surcharges and are never deducted from solver compensation. The minimum possible total surcharge
is nominally 3% outside dust cases; the actual surcharge is 2.5% plus the chosen verifier pool as a
percentage of reward. Percentage-derived components round down independently in the asset's
smallest unit.

## 3. Successful settlement

On the first valid 2-of-3 claim:

| Recipient | Credit |
| --- | ---: |
| Solver | `R` |
| DevCo | `floor(R * 200 / 10_000)` |
| Each of the two signing verifiers | `floor(V / 2)` |
| Security reserve | `floor(R * 50 / 10_000) + (V mod 2)` |
| Non-signing verifier | `0` |

The verifier remainder is at most one smallest asset unit because exactly two signer shares are
created. Reward and verifier pool are also included in the EIP-712 attestation, so each verifier
explicitly signs the economics it accepts.

For a 10,200-smallest-unit reward at the minimum verifier pool:

```text
DevCo             204
Verifier pool      51  -> 25 to each signer
Security fee       51  -> reserve receives 52 including verifier dust
Sponsor funds  10,506
Solver gets    10,200
```

For a $1,000 stable-asset reward with a sponsor-selected 5% verifier pool, the sponsor funds $1,075
before gas: $1,000 to the solver, $20 to DevCo, $50 split as $25 per signing verifier, and $5 to the
reserve. This is a suggested starting point for a pilot, not a universal price; expensive
evaluators may require more and cheap automated profiles may support less.

## 4. Expired settlement

If no result is paid by the claim deadline, the frozen refund recipient is credited the complete
funded amount: reward, DevCo fee, verifier pool, and security fee. DevCo, verifiers, and reserve earn
nothing from that bounty.

This aligns protocol revenue with a paid result and prevents fees from being retained merely
because verification failed or became unavailable. It also means the operator bears demand,
verifier-availability, and expiration risk.

## 5. Participant incentives

- **Sponsors** obtain commitment-backed competition and a deterministic refund path. They bear the
  reward, fixed fees, declared verifier pool, creation gas, and any token approval gas. They must
  price verification before creating the immutable bounty.
- **Solvers** see the exact gross reward and verifier economics on chain and are not charged a
  protocol fee. They bear commit, optional claim, withdrawal gas, and off-chain work cost.
- **Verifiers** are paid only when their signatures participate in the winning settlement. They can
  reject an underpriced bounty; signatures can be relayed, so they need not pay claim gas.
- **DevCo** receives 2% of successfully paid reward volume. It has no claim on expired bounties and
  no administrative control over funds.
- **Security reserve** receives 0.5% of successful reward volume plus at most one unit of verifier
  dust. The contract does not enforce how this address spends funds.
- **Relayers** receive no V1 protocol payment. Any relayer business model is off chain.

If successful paid reward volume is `W`, gross DevCo credit is approximately `0.02 * W`, subject to
per-bounty flooring. That is gross protocol revenue, not profit; verifier operations, frontend
distribution, audits, incident response, legal work, taxes, grants, and acquisition remain costs.

## 6. Creator capture and forkability

The official deployment permanently directs the 2% fee to its immutable DevCo address. This is
non-custodial creator capture inside that exact deployment: neither a sponsor nor a later
administrator can redirect it.

It is not a global royalty. A licensed source fork can remove or redirect the fee by deploying
different bytecode/configuration under a different address and deployment ID. Sustainable
advantage must therefore come from trusted verifier operations, high-quality evaluator profiles,
discovery, reputation, integrations, availability, and an authenticated release registry—not from
a token or owner key.

## 7. Economic and trust limitations

- A minimum-sized verifier pool can be much too small. At a $1,000 reward it is only $2.50 per
  signer. The variable pool exists specifically so profiles and sponsors can pay realistic costs.
- Only the two submitted signers are paid. A third verifier that performs work but does not sign the
  winning claim receives nothing; request routing must avoid gratuitous duplicate work.
- Two colluding verifiers can authorize an affiliate's committed result and capture nearly the
  entire solver reward. Higher verifier compensation improves honest availability but is not
  cryptoeconomic security, bonding, or slashing.
- A fixed verifier set can become unavailable and cannot be rotated. The expiry refund limits
  sponsor loss but cannot compensate a solver for work.
- Small rewards can produce zero fixed fee components through flooring, and gas can dominate,
  especially on Ethereum mainnet.
- The first accepted result wins; V1 cannot pay multiple contributors or split collaboration.
- The reserve is not insurance and creates no reimbursement right.
- Revenue and verifier budgets inherit asset, custody, token, accounting, and tax risk.

Do not market any fee as yield, investment return, insurance premium, bribery resistance, or an ROI
guarantee. These are transparent service charges on a successful bounty settlement.
