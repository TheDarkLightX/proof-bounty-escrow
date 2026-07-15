#!/usr/bin/env python3
"""Require deterministic/adversarial tests to kill high-value Solidity mutants.

The script works in a temporary copy and never edits the checked-out contracts. A mutant is
counted only if it compiles successfully and the selected tests then fail. This is a targeted
mutation gate, not exhaustive mutation coverage.
"""

from __future__ import annotations

import json
import os
import shutil
import subprocess
import tempfile
from dataclasses import dataclass
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
SOURCE = Path("contracts/ProofBountyEscrowBase.sol")
ARTIFACTS = ROOT / "artifacts"
TEST_PATTERN = "^ProofBountyEscrow(Test|AdversarialTest)$"


@dataclass(frozen=True)
class Mutation:
    name: str
    old: str
    new: str
    occurrence: int = 1
    source: Path = SOURCE


MUTATIONS = (
    Mutation(
        "commit_open_at_deadline",
        "if (block.timestamp >= bounty.commitDeadline) revert CommitPhaseClosed();",
        "if (block.timestamp > bounty.commitDeadline) revert CommitPhaseClosed();",
    ),
    Mutation(
        "claim_open_at_claim_deadline",
        "block.timestamp < bounty.commitDeadline || block.timestamp >= bounty.claimDeadline",
        "block.timestamp < bounty.commitDeadline || block.timestamp > bounty.claimDeadline",
    ),
    Mutation(
        "paid_state_not_terminal",
        "bounty.status = BountyStatus.Paid;",
        "bounty.status = BountyStatus.Open;",
    ),
    Mutation(
        "deduct_dev_fee_from_solver",
        "claimable[result.solver] += bounty.reward;",
        "claimable[result.solver] += bounty.reward - devFee;",
    ),
    Mutation(
        "refund_omits_sponsor_fees",
        "claimable[bounty.refundRecipient] += bounty.fundedAmount;",
        "claimable[bounty.refundRecipient] += bounty.reward;",
    ),
    Mutation(
        "accept_wrong_reveal",
        "if (commitments[result.bountyId][result.solver] != commitment_) revert InvalidCommitment();",
        "if (commitments[result.bountyId][result.solver] == bytes32(0)) revert InvalidCommitment();",
    ),
    Mutation(
        "claim_keeps_escrow_liability",
        "totalEscrowed -= bounty.fundedAmount;",
        "totalEscrowed -= 0;",
    ),
    Mutation(
        "duplicate_verifier_counts_twice",
        "if (firstIndex >= secondIndex || secondIndex >= VERIFIER_COUNT) revert InvalidVerifierOrder();",
        "if (firstIndex > secondIndex || secondIndex >= VERIFIER_COUNT) revert InvalidVerifierOrder();",
    ),
    Mutation(
        "verifier_can_claim_as_solver",
        " || isVerifier[result.solver]",
        "",
    ),
    Mutation(
        "refund_delayed_past_boundary",
        "if (block.timestamp < bounty.claimDeadline) revert RefundNotAvailable();",
        "if (block.timestamp <= bounty.claimDeadline) revert RefundNotAvailable();",
    ),
    Mutation(
        "accept_verifier_fee_below_minimum",
        "requestedVerifierFee < minimum || requestedVerifierFee > maximum",
        "false || requestedVerifierFee > maximum",
    ),
    Mutation(
        "accept_verifier_fee_above_maximum",
        "requestedVerifierFee < minimum || requestedVerifierFee > maximum",
        "requestedVerifierFee < minimum || false",
    ),
    Mutation(
        "funding_omits_declared_verifier_fee",
        "return reward + devFee + verifierFee + securityFee;",
        "return reward + devFee + securityFee;",
    ),
    Mutation(
        "settlement_substitutes_minimum_verifier_fee",
        "uint256 verifierShare = bounty.verifierFee / VERIFIER_THRESHOLD;",
        "uint256 verifierShare = minimumVerifierFee(bounty.reward) / VERIFIER_THRESHOLD;",
    ),
    Mutation(
        "bounty_freezes_minimum_instead_of_declared_verifier_fee",
        "verifierFee: request.verifierFee,",
        "verifierFee: minimumVerifierFee(request.reward),",
    ),
    Mutation(
        "remove_absolute_minimum_verifier_fee_units",
        "return percentageFloor > MIN_VERIFIER_FEE_UNITS ? percentageFloor : MIN_VERIFIER_FEE_UNITS;",
        "return percentageFloor;",
    ),
    Mutation(
        "accept_reward_below_minimum_units",
        " || request.reward < MIN_REWARD_UNITS",
        " || request.reward == 0",
    ),
    Mutation(
        "allow_asset_as_fee_recipient",
        "                || (asset_ != address(0) && (devCo_ == asset_ || securityReserve_ == asset_))\n",
        "",
    ),
    Mutation(
        "allow_asset_as_refund_recipient",
        " || (asset != address(0) && request.refundRecipient == asset)",
        "",
    ),
    Mutation(
        "allow_withdrawal_to_asset_contract",
        "(asset != address(0) && destination == asset)",
        "false",
    ),
    Mutation(
        "allow_asset_as_solver",
        " || (asset != address(0) && result.solver == asset)",
        "",
    ),
    Mutation(
        "omit_signed_verifier_pair_binding",
        "        data.signerBitmap = signerBitmap;\n",
        "        data.signerBitmap = 0;\n",
    ),
    Mutation(
        "remove_erc20_solvency_admission_gate",
        """        uint256 accountedBefore = accountedBalance();
        uint256 beforeBalance = token.balanceOf(address(this));
        if (beforeBalance < accountedBefore) revert InsolventAsset(beforeBalance, accountedBefore);
        token.safeTransferFrom(msg.sender, address(this), expected);
        uint256 afterBalance = token.balanceOf(address(this));
        if (
            afterBalance < beforeBalance || afterBalance - beforeBalance != expected
                || afterBalance < accountedBefore + expected
        ) {
""",
        """        uint256 beforeBalance = token.balanceOf(address(this));
        token.safeTransferFrom(msg.sender, address(this), expected);
        uint256 afterBalance = token.balanceOf(address(this));
        if (afterBalance < beforeBalance || afterBalance - beforeBalance != expected) {
""",
        source=Path("contracts/ProofBountyEscrowERC20.sol"),
    ),
)


def run(argv: list[str], cwd: Path) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        argv,
        cwd=cwd,
        env={**os.environ, "FOUNDRY_FUZZ_RUNS": "32", "FOUNDRY_INVARIANT_RUNS": "8"},
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=120,
        check=False,
    )


def stage_tree(destination: Path) -> None:
    for relative in ("contracts", "test-foundry"):
        shutil.copytree(ROOT / relative, destination / relative)
    shutil.copy2(ROOT / "foundry.toml", destination / "foundry.toml")
    for relative in ("node_modules", "lib"):
        source = ROOT / relative
        if source.exists():
            (destination / relative).symlink_to(source, target_is_directory=True)


def apply_mutation(path: Path, mutation: Mutation) -> None:
    source = path.read_text(encoding="utf-8")
    if source.count(mutation.old) < mutation.occurrence:
        raise AssertionError(f"mutation anchor missing or ambiguous: {mutation.name}")
    mutated = source.replace(mutation.old, mutation.new, mutation.occurrence)
    if mutated == source:
        raise AssertionError(f"mutation made no change: {mutation.name}")
    path.write_text(mutated, encoding="utf-8")


def main() -> int:
    forge = shutil.which("forge")
    if forge is None:
        raise SystemExit("forge is required on PATH")

    results: list[dict[str, object]] = []
    with tempfile.TemporaryDirectory(prefix="proof-bounty-mutants-") as raw_temp:
        temp = Path(raw_temp)
        for mutation in MUTATIONS:
            worktree = temp / mutation.name
            worktree.mkdir()
            stage_tree(worktree)
            apply_mutation(worktree / mutation.source, mutation)

            build = run([forge, "build"], worktree)
            if build.returncode != 0:
                raise AssertionError(
                    f"invalid mutant {mutation.name}: compilation failed\n{build.stdout[-4000:]}"
                )
            tests = run(
                [forge, "test", "--match-contract", TEST_PATTERN, "--fail-fast"],
                worktree,
            )
            killed = tests.returncode != 0
            results.append(
                {
                    "mutation": mutation.name,
                    "compiled": True,
                    "killed": killed,
                    "test_exit_code": tests.returncode,
                }
            )
            if not killed:
                raise AssertionError(f"surviving Solidity mutant: {mutation.name}")

    receipt = {
        "schema": "proof-bounty-solidity-mutation-receipt/v1",
        "scope": f"{len(MUTATIONS)} targeted semantic mutants across the escrow contracts",
        "test_contract_pattern": TEST_PATTERN,
        "mutants": len(results),
        "killed": sum(bool(result["killed"]) for result in results),
        "survivors": [result["mutation"] for result in results if not result["killed"]],
        "results": results,
        "limitations": [
            "Targeted mutation set; not exhaustive source-level mutation coverage.",
            "A killed mutant means at least one selected test failed, not that every defect in its class is detected.",
            "Compiler, dependency, and EVM assumptions remain outside this mutation gate.",
        ],
    }
    ARTIFACTS.mkdir(exist_ok=True)
    (ARTIFACTS / "solidity-mutation-receipt.json").write_text(
        json.dumps(receipt, indent=2, sort_keys=True) + "\n", encoding="utf-8"
    )
    print(json.dumps(receipt, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
