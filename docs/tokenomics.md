# Tokenomics and fee economics

> **Scope:** this document describes the immutable V1 open-prize escrow. It does not describe an
> employment relationship, assigned-job market, protocol token, or the unimplemented
> [Evaluation Market V2](evaluation-market-v2.md) design target.

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
created. Reward, verifier pool, and the exact paid signer bitmap are included in the EIP-712
attestation, so each verifier explicitly signs both the economics and recipient pair it accepts.

For a 10,200-smallest-unit reward at the minimum verifier pool:

```text
DevCo             204
Verifier pool      51  -> 25 to each signer
Security fee       51  -> reserve receives 52 including verifier dust
Sponsor funds  10,506
Solver gets    10,200
```

For a 1,000,000-unit reward with a sponsor-selected 5% verifier pool, the sponsor funds 1,075,000
units before gas: 1,000,000 to the solver, 20,000 to DevCo, 50,000 split as 25,000 per signing
verifier, and 5,000 to the reserve. This is arithmetic in the escrow asset's smallest units, not a
dollar valuation or a suggested universal price. Common upgradeable, pausable, blacklistable, or
otherwise behavior-changing stablecoins are outside the supported ERC-20 profile even if their
market price is intended to track a dollar.

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
- **Verifiers** are paid only when their signatures participate in the winning accepted settlement.
  They can reject an underpriced bounty; signatures can be relayed, so they need not pay claim gas.
  However, an honest rejection, a completed review by the unused third verifier, and review of a
  losing result are unpaid. This is a material approval/selection bias in V1, not merely a routing
  inconvenience.
- **DevCo** receives 2% of successfully paid reward volume. It has no claim on expired bounties and
  no administrative control over funds.
- **Security reserve** receives 0.5% of successful reward volume plus at most one unit of verifier
  dust. The contract does not enforce how this address spends funds.
- **Relayers** receive no V1 protocol payment. Any relayer business model is off chain.

If successful paid reward volume is `W`, gross DevCo credit is approximately `0.02 * W`, subject to
per-bounty flooring. That is gross protocol revenue, not profit; verifier operations, frontend
distribution, audits, incident response, legal work, taxes, grants, and acquisition remain costs.

### Asset-unit runway, not a salary promise

The contract does not know dollars and does not manufacture purchasing power. Let `C_a` be an
operating requirement measured in units of one escrow asset `a`. Ignoring per-bounty flooring, the
accepted reward volume required for the 2% DevCo fee to credit `C_a` is:

```text
0.02 * W_a = C_a
W_a = 50 * C_a
```

Thus 100,000 units of operating need requires 5,000,000 units of successfully accepted reward
volume in that same asset. Expired volume contributes zero. This identity is a funding threshold,
not a prediction that demand will reach it or that those units will retain value.

If an external expense is quoted as `C_$` dollars and an independently observed market price is
`P` dollars per asset unit, the instantaneous translation is `C_a = C_$ / P` and therefore
`W_a = 50 * C_$ / P`. A 50% fall in `P` doubles the asset-unit volume required; a 50% rise reduces
it by one third. This is scenario arithmetic only. The contract has no price oracle, hedge, swap,
or guarantee that the asset can be sold at `P`.

Credits in different assets cannot be added without choosing external prices, liquidity, slippage,
custody, and a valuation time. Dollars can enter the operator's budget only because a sponsor funds
a suitably safe dollar-redeemable asset or because a fee recipient sells another received asset to
an external buyer. Those conversions happen outside V1 and carry their own risks.

For survival planning, track each asset separately:

```text
runway_a = liquid operating treasury_a / expected operating spend_a per period
coverage_a = realized DevCo credits_a / realized operating spend_a
```

Use conservative price and demand scenarios, maintain an external expense reserve where lawful,
and do not commit fixed external liabilities on the assumption that PLS price or accepted bounty
volume will rise. Grants, donations, and maintenance bounties can supplement fees, but they are
also transfers from funders rather than protocol-created dollars.

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

- A minimum-sized verifier pool can be much too small. At a 1,000,000-unit reward it is only 2,500
  units per signer. The variable pool exists specifically so profiles and sponsors can pay
  realistic costs.
- Only the two submitted signers are paid. A third verifier that performs work but does not sign the
  winning accepted claim receives nothing. A verifier that correctly rejects a bad result is also
  unpaid. Request routing must avoid gratuitous duplicate work, but cannot make this outcome-linked
  payment mechanism neutral. The V2 design target prefunds assigned committee slots and pays valid
  `ACCEPT` or `REJECT` decision receipts independently of the worker-reward outcome.
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
- The `50 * operating requirement` relation says how much accepted same-asset volume generates a 2%
  gross credit. It says nothing about future demand, net income, market value, or creator survival.

Do not market any fee as yield, investment return, insurance premium, bribery resistance, or an ROI
guarantee. These are transparent service charges on a successful bounty settlement.
