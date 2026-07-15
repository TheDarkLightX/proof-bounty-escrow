#!/usr/bin/env python3
"""Require the bounded model properties to kill each intentional semantic mutant."""

from __future__ import annotations

import json
from pathlib import Path

from model_check import ARTIFACTS, explore

MUTATIONS = (
    "commit_at_deadline",
    "claim_at_deadline",
    "allow_double_settlement",
    "ignore_commitment",
    "deduct_fee_from_solver",
    "refund_omits_fees",
    "keep_escrow_on_claim",
    "duplicate_verifier_credit",
    "accept_below_min_verifier_fee",
    "accept_above_max_verifier_fee",
    "accept_reward_below_minimum",
    "ignore_declared_verifier_fee",
    "ignore_signed_verifier_pair",
)


def main() -> int:
    results = [explore(mutation) for mutation in MUTATIONS]
    survivors = [result["mutation"] for result in results if result["ok"]]
    report = {
        "schema": "proof-bounty-model-mutation-receipt/v1",
        "mutants": len(MUTATIONS),
        "killed": len(MUTATIONS) - len(survivors),
        "survivors": survivors,
        "results": results,
    }
    if survivors:
        raise AssertionError(f"surviving semantic mutants: {survivors}")
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / "model-mutation-receipt.json").write_text(json.dumps(report, indent=2, sort_keys=True) + "\n")
    print(json.dumps(report, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
