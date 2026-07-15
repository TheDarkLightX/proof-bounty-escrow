#!/usr/bin/env python3
"""Finite reference model for Proof Bounty Escrow V1.

This is a bounded exhaustive state exploration, not a proof of Solidity bytecode.
It deliberately models two competing solvers, three verifiers, a sponsor-declared
verifier pool with protocol bounds, fee dust, exact deadline boundaries, pull
credits, withdrawals, and forced native currency.
"""

from __future__ import annotations

import json
from collections import deque
from dataclasses import dataclass, replace
from pathlib import Path
from typing import Iterable

ROOT = Path(__file__).resolve().parents[2]
ARTIFACTS = ROOT / "artifacts"

NONE, OPEN, PAID, REFUNDED = range(4)
REFUND, SOLVER_0, SOLVER_1, DEVCO, VERIFIER_0, VERIFIER_1, VERIFIER_2, RESERVE = range(8)
ROLE_COUNT = 8
COMMIT_DEADLINE = 2
CLAIM_DEADLINE = 4
MAX_TIME = 5
MAX_DEPTH = 8
REWARDS = (2, 199, 10_200)
FUNDING_REWARD_INPUTS = (1,) + REWARDS
RESULTS = (1, 2)
VERIFIER_PAIRS = ((0, 1), (0, 2), (1, 2))
MIN_REWARD_UNITS = 2
MIN_VERIFIER_FEE_UNITS = 2
DEVCO_BPS = 200
MIN_VERIFIER_BPS = 50
MAX_VERIFIER_BPS = 10_000
SECURITY_BPS = 50
BPS_DENOMINATOR = 10_000


@dataclass(frozen=True)
class Bounty:
    status: int = NONE
    reward: int = 0
    verifier_fee: int = 0
    funded: int = 0
    commitments: tuple[int, int] = (0, 0)
    winner: int = -1
    result: int = 0
    verifier_pair: tuple[int, int] = (-1, -1)
    settlement_count: int = 0


@dataclass(frozen=True)
class State:
    now: int = 0
    bounty: Bounty = Bounty()
    credits: tuple[int, ...] = (0,) * ROLE_COUNT
    withdrawn: tuple[int, ...] = (0,) * ROLE_COUNT
    total_funded: int = 0
    escrowed: int = 0
    actual_balance: int = 0
    forced: int = 0


def minimum_verifier_fee(reward: int) -> int:
    return max(MIN_VERIFIER_FEE_UNITS, reward * MIN_VERIFIER_BPS // BPS_DENOMINATOR)


def maximum_verifier_fee(reward: int) -> int:
    return reward * MAX_VERIFIER_BPS // BPS_DENOMINATOR


def valid_verifier_fee(reward: int, verifier_fee: int) -> bool:
    return minimum_verifier_fee(reward) <= verifier_fee <= maximum_verifier_fee(reward)


def verifier_fee_inputs(reward: int) -> tuple[int, ...]:
    minimum = minimum_verifier_fee(reward)
    maximum = maximum_verifier_fee(reward)
    candidates = {minimum, min(minimum + 1, maximum), maximum, maximum + 1}
    if minimum > 0:
        candidates.add(minimum - 1)
    return tuple(sorted(candidates))


def fees(reward: int, verifier_fee: int) -> tuple[int, int, int]:
    return (
        reward * DEVCO_BPS // BPS_DENOMINATOR,
        verifier_fee,
        reward * SECURITY_BPS // BPS_DENOMINATOR,
    )


def required_funding(reward: int, verifier_fee: int) -> int:
    return reward + sum(fees(reward, verifier_fee))


def commit_enabled(now: int, mutation: str | None) -> bool:
    return now <= COMMIT_DEADLINE if mutation == "commit_at_deadline" else now < COMMIT_DEADLINE


def claim_enabled(now: int, mutation: str | None) -> bool:
    return COMMIT_DEADLINE <= now <= CLAIM_DEADLINE if mutation == "claim_at_deadline" else (
        COMMIT_DEADLINE <= now < CLAIM_DEADLINE
    )


def refund_enabled(now: int) -> bool:
    return now >= CLAIM_DEADLINE


def _add(values: tuple[int, ...], role: int, amount: int) -> tuple[int, ...]:
    updated = list(values)
    updated[role] += amount
    return tuple(updated)


def fund(state: State, reward: int, verifier_fee: int, mutation: str | None) -> State:
    if state.bounty.status != NONE:
        return state
    reward_is_valid = reward >= MIN_REWARD_UNITS
    fee_is_valid = valid_verifier_fee(reward, verifier_fee)
    accepts_invalid_reward = mutation == "accept_reward_below_minimum" and not reward_is_valid
    accepts_invalid_minimum = (
        mutation == "accept_below_min_verifier_fee"
        and reward_is_valid
        and verifier_fee < minimum_verifier_fee(reward)
    )
    accepts_invalid_maximum = (
        mutation == "accept_above_max_verifier_fee"
        and reward_is_valid
        and verifier_fee > maximum_verifier_fee(reward)
    )
    if not (
        (reward_is_valid and fee_is_valid)
        or accepts_invalid_reward
        or accepts_invalid_minimum
        or accepts_invalid_maximum
    ):
        return state
    funded = required_funding(reward, verifier_fee)
    return replace(
        state,
        bounty=Bounty(status=OPEN, reward=reward, verifier_fee=verifier_fee, funded=funded),
        total_funded=state.total_funded + funded,
        escrowed=state.escrowed + funded,
        actual_balance=state.actual_balance + funded,
    )


def commit(state: State, solver: int, result: int, mutation: str | None) -> State:
    if state.bounty.status != OPEN or not commit_enabled(state.now, mutation):
        return state
    commitments = list(state.bounty.commitments)
    commitments[solver] = result
    return replace(state, bounty=replace(state.bounty, commitments=tuple(commitments)))


def claim(state: State, solver: int, result: int, pair: tuple[int, int], mutation: str | None) -> State:
    allowed_status = state.bounty.status == OPEN or (
        mutation == "allow_double_settlement" and state.bounty.status in (PAID, REFUNDED)
    )
    if not allowed_status or not claim_enabled(state.now, mutation):
        return state
    if mutation != "ignore_commitment" and state.bounty.commitments[solver] != result:
        return state

    bounty = state.bounty
    verifier_fee = (
        minimum_verifier_fee(bounty.reward)
        if mutation == "ignore_declared_verifier_fee"
        else bounty.verifier_fee
    )
    dev_fee, verifier_fee, security_fee = fees(bounty.reward, verifier_fee)
    solver_credit = bounty.reward
    if mutation == "deduct_fee_from_solver":
        solver_credit = max(0, bounty.reward - dev_fee - verifier_fee - security_fee)

    credits = _add(state.credits, SOLVER_0 + solver, solver_credit)
    credits = _add(credits, DEVCO, dev_fee)
    per_verifier = verifier_fee // 2
    dust = verifier_fee - per_verifier * 2
    if mutation == "duplicate_verifier_credit":
        credits = _add(credits, VERIFIER_0 + pair[0], per_verifier * 2)
    else:
        credits = _add(credits, VERIFIER_0 + pair[0], per_verifier)
        credits = _add(credits, VERIFIER_0 + pair[1], per_verifier)
    credits = _add(credits, RESERVE, security_fee + dust)

    escrowed = state.escrowed if mutation == "keep_escrow_on_claim" else state.escrowed - bounty.funded
    return replace(
        state,
        bounty=replace(
            bounty,
            status=PAID,
            winner=solver,
            result=result,
            verifier_pair=pair,
            settlement_count=bounty.settlement_count + 1,
        ),
        credits=credits,
        escrowed=escrowed,
    )


def refund(state: State, mutation: str | None) -> State:
    allowed_status = state.bounty.status == OPEN or (
        mutation == "allow_double_settlement" and state.bounty.status in (PAID, REFUNDED)
    )
    if not allowed_status or not refund_enabled(state.now):
        return state
    amount = state.bounty.reward if mutation == "refund_omits_fees" else state.bounty.funded
    return replace(
        state,
        bounty=replace(
            state.bounty,
            status=REFUNDED,
            winner=-1,
            result=0,
            verifier_pair=(-1, -1),
            settlement_count=state.bounty.settlement_count + 1,
        ),
        credits=_add(state.credits, REFUND, amount),
        escrowed=state.escrowed - state.bounty.funded,
    )


def withdraw(state: State, role: int) -> State:
    amount = state.credits[role]
    if amount == 0:
        return state
    credits = list(state.credits)
    withdrawn = list(state.withdrawn)
    credits[role] = 0
    withdrawn[role] += amount
    return replace(
        state,
        credits=tuple(credits),
        withdrawn=tuple(withdrawn),
        actual_balance=state.actual_balance - amount,
    )


def force_native(state: State) -> State:
    return replace(state, actual_balance=state.actual_balance + 1, forced=state.forced + 1)


def tick(state: State) -> State:
    return replace(state, now=min(MAX_TIME, state.now + 1))


def entitlement(state: State, role: int) -> int:
    return state.credits[role] + state.withdrawn[role]


def check_properties(state: State, mutation: str | None = None) -> None:
    withdrawn_total = sum(state.withdrawn)
    liabilities = state.escrowed + sum(state.credits)
    if state.total_funded != liabilities + withdrawn_total:
        raise AssertionError(("liability conservation", state))
    if state.actual_balance != liabilities + state.forced:
        raise AssertionError(("balance backs liability", state))
    if state.actual_balance + withdrawn_total != state.total_funded + state.forced:
        raise AssertionError(("global value conservation", state))
    if state.bounty.settlement_count > 1:
        raise AssertionError(("single settlement", state))
    if claim_enabled(state.now, mutation) and refund_enabled(state.now):
        raise AssertionError(("claim/refund deadline separation", state))
    if state.now == COMMIT_DEADLINE and commit_enabled(state.now, mutation):
        raise AssertionError(("commit boundary", state))

    bounty = state.bounty
    if bounty.status != NONE:
        if bounty.reward < MIN_REWARD_UNITS:
            raise AssertionError(("minimum reward units", state))
        if not valid_verifier_fee(bounty.reward, bounty.verifier_fee):
            raise AssertionError(("verifier fee bounds", state))
        if bounty.funded != required_funding(bounty.reward, bounty.verifier_fee):
            raise AssertionError(("declared verifier fee funding", state))
    if bounty.status == PAID:
        if bounty.winner not in (0, 1) or bounty.result == 0:
            raise AssertionError(("paid result shape", state))
        if bounty.commitments[bounty.winner] != bounty.result:
            raise AssertionError(("commitment binding", state))
        if entitlement(state, SOLVER_0 + bounty.winner) != bounty.reward:
            raise AssertionError(("full advertised reward", state))
        dev_fee, verifier_fee, security_fee = fees(bounty.reward, bounty.verifier_fee)
        if entitlement(state, DEVCO) != dev_fee:
            raise AssertionError(("dev fee", state))
        per_verifier = verifier_fee // 2
        for verifier in range(3):
            expected = per_verifier if verifier in bounty.verifier_pair else 0
            if entitlement(state, VERIFIER_0 + verifier) != expected:
                raise AssertionError(("accepted verifier compensation", state))
        if entitlement(state, RESERVE) != security_fee + verifier_fee - per_verifier * 2:
            raise AssertionError(("reserve fee and dust", state))
    elif bounty.status == REFUNDED:
        if bounty.winner != -1 or bounty.result != 0:
            raise AssertionError(("refund shape", state))
        if entitlement(state, REFUND) != bounty.funded:
            raise AssertionError(("complete no-fee refund", state))
    elif bounty.status in (NONE, OPEN):
        if bounty.winner != -1 or bounty.result != 0 or bounty.settlement_count != 0:
            raise AssertionError(("preterminal shape", state))


def successors(state: State, mutation: str | None = None) -> Iterable[tuple[str, State]]:
    actions: list[tuple[str, State]] = [("tick", tick(state)), ("force", force_native(state))]
    for reward in FUNDING_REWARD_INPUTS:
        for verifier_fee in verifier_fee_inputs(reward):
            actions.append(
                (
                    f"fund({reward},{verifier_fee})",
                    fund(state, reward, verifier_fee, mutation),
                )
            )
    for solver in range(2):
        for result in RESULTS:
            actions.append((f"commit({solver},{result})", commit(state, solver, result, mutation)))
            for pair in VERIFIER_PAIRS:
                actions.append((f"claim({solver},{result},{pair})", claim(state, solver, result, pair, mutation)))
    actions.append(("refund", refund(state, mutation)))
    for role in range(ROLE_COUNT):
        actions.append((f"withdraw({role})", withdraw(state, role)))
    for label, target in actions:
        if target != state:
            yield label, target


def explore(mutation: str | None = None, max_depth: int = MAX_DEPTH) -> dict[str, object]:
    initial = State()
    check_properties(initial, mutation)
    queue = deque([(initial, tuple())])
    seen = {initial}
    transitions = 0
    max_seen_depth = 0
    while queue:
        state, trace = queue.popleft()
        max_seen_depth = max(max_seen_depth, len(trace))
        if len(trace) >= max_depth:
            continue
        for label, target in successors(state, mutation):
            transitions += 1
            next_trace = trace + (label,)
            try:
                check_properties(target, mutation)
            except AssertionError as exc:
                return {
                    "ok": False,
                    "mutation": mutation,
                    "failure": exc.args[0][0],
                    "trace": list(next_trace),
                    "state": repr(target),
                    "states": len(seen),
                    "transitions": transitions,
                }
            if target not in seen:
                seen.add(target)
                queue.append((target, next_trace))
    return {
        "ok": True,
        "mutation": mutation,
        "max_depth": max_depth,
        "max_seen_depth": max_seen_depth,
        "states": len(seen),
        "transitions": transitions,
        "reward_inputs": list(FUNDING_REWARD_INPUTS),
        "minimum_reward_units": MIN_REWARD_UNITS,
        "minimum_verifier_fee_units": MIN_VERIFIER_FEE_UNITS,
        "verifier_fee_inputs": {
            str(reward): list(verifier_fee_inputs(reward)) for reward in FUNDING_REWARD_INPUTS
        },
        "verifier_fee_bounds_bps": [MIN_VERIFIER_BPS, MAX_VERIFIER_BPS],
        "time_domain": list(range(MAX_TIME + 1)),
        "solvers": 2,
        "verifiers": 3,
        "verifier_pairs": [list(pair) for pair in VERIFIER_PAIRS],
    }


def main() -> int:
    report = {
        "schema": "proof-bounty-bounded-model-receipt/v1",
        "claim": "No counterexample in the recorded finite state and numeric bounds.",
        "result": explore(),
        "limitations": [
            "Finite abstract exploration; not a proof of Solidity source, bytecode, ECDSA, or the EVM.",
            "Exactly one bounty is explored per trace, with two solvers and three verifiers.",
            "Verifier signatures are abstracted as valid decisions; collusion and evaluator correctness are assumptions.",
            "Only native exact-transfer accounting is represented; ERC-20 adapter assumptions are tested separately.",
        ],
    }
    if not report["result"]["ok"]:
        raise AssertionError(report)
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / "bounded-model-receipt.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
