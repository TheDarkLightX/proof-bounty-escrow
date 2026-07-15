# Slither triage

This file triages the production-only Slither 0.11.5 run. The command excludes dependencies,
test contracts, mocks, and deployment scripts. Slither returned ten detector results and a
non-zero exit status because findings were present; none is silently treated as a clean scan.

## Accepted design findings

| Detector | Surface | Disposition |
| --- | --- | --- |
| `arbitrary-send-eth` | Native `withdraw` adapter | Intended. A credited account chooses its own destination. The amount cannot exceed `claimable[msg.sender]`; effects occur before the call; `withdraw` is `nonReentrant`; and a failed call reverts every accounting change. |
| `low-level-calls` | Native `call{value: amount}` | Intended. `call` supports contract-wallet recipients. Its success value is checked and failure reverts. A rejecting-recipient retry test covers the recovery path. |
| `reentrancy-balance` (two instances) | ERC-20 withdrawal balance deltas | Expected postcondition pattern. The pre-call balances are intentionally compared with post-call balances to reject non-exact token behavior. The public `withdraw` entry point is `nonReentrant`; callback attempts and rollback are adversarially tested. |
| `reentrancy-balance` | ERC-20 funding balance delta | Expected postcondition pattern. The public `createBounty` entry point is `nonReentrant`; the comparison rejects fee-on-transfer and short-transfer funding. Callback reentry and false-return rollback are tested. |
| `reentrancy-benign` | ERC-20 funding writes after transfer | Accepted. State is written only after exact receipt is established, while `nonReentrant` prevents a nested creation. Any later revert rolls back the token call and allowance effects in the same EVM transaction. |
| `timestamp` (four instances) | Commit, claim, refund, and maximum-duration boundaries | Intentional protocol time windows. They are half-open (`< commit`, `>= commit && < claim`, `>= claim`) and symbolically checked for disjointness. Operators should use windows measured in hours or days, not depend on exact-second execution. |

## Residual assumptions

The ERC-20 adapter supports only a specifically vetted, immutable-semantics, exact-transfer
token. A token that lies through `balanceOf`, changes behavior after deployment, rebases,
blacklists recipients, or deliberately exhausts gas is outside the supported profile. The
adversarial suite covers callbacks, false returns, short transfers, and transaction rollback;
it cannot make an arbitrary malicious token safe.

This triage is engineering evidence, not an external audit or a proof that no vulnerability
exists.
