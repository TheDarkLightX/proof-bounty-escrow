#!/usr/bin/env python3
"""Fail closed when a workflow references a mutable external action.

This intentionally uses only the Python standard library so the release gate can
run before any network-backed dependency installation. Local actions beginning
with ``./`` are allowed; every other ``uses:`` value must end in a lowercase,
full-length Git commit SHA and carry a human-readable version comment.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path


USES_KEY = re.compile(r"^\s*(?:-\s*)?uses\s*:\s*(?P<value>.*)$")
POSSIBLE_USES_KEY = re.compile(r"(?:^|[\s{,?-])(?:uses|['\"]uses['\"])\s*:")
EXTERNAL_ACTION = re.compile(
    r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_./-]+)?@(?P<sha>[0-9a-f]{40})"
)
VERSION_COMMENT = re.compile(r"^v[0-9]+(?:\.[0-9]+){0,2}(?:[-+][A-Za-z0-9_.-]+)?$")


class WorkflowPinError(ValueError):
    """A workflow contains an unsafe or ambiguous action reference."""


def _split_value_and_comment(raw: str) -> tuple[str, str | None]:
    """Split the deliberately restricted scalar syntax accepted for ``uses``."""

    value, separator, comment = raw.partition("#")
    value = value.strip()
    if not value:
        raise WorkflowPinError("uses value is empty")
    if value[0:1] in {"'", '"'}:
        if len(value) < 2 or value[-1] != value[0]:
            raise WorkflowPinError("uses value has mismatched quotes")
        value = value[1:-1]
    if any(character.isspace() for character in value):
        raise WorkflowPinError("uses value must be a single-line scalar")
    return value, comment.strip() if separator else None


def check_workflow_text(text: str, *, source: str = "<workflow>") -> int:
    """Validate all action references in one workflow and return their count."""

    count = 0
    errors: list[str] = []
    for line_number, line in enumerate(text.splitlines(), start=1):
        stripped = line.lstrip()
        if not stripped or stripped.startswith("#"):
            continue
        match = USES_KEY.match(line)
        if match is None:
            # A uses key split over multiple lines is intentionally rejected,
            # rather than silently escaping the pin policy.
            if POSSIBLE_USES_KEY.search(line):
                errors.append(f"{source}:{line_number}: unsupported uses syntax")
            continue
        count += 1
        try:
            value, comment = _split_value_and_comment(match.group("value"))
            if value.startswith("./"):
                continue
            action = EXTERNAL_ACTION.fullmatch(value)
            if action is None:
                raise WorkflowPinError(
                    "external action must use owner/repository[/path]@ followed by "
                    "a lowercase 40-hex commit SHA"
                )
            if comment is None or VERSION_COMMENT.fullmatch(comment) is None:
                raise WorkflowPinError(
                    "pinned external action must include a version comment such as '# v4'"
                )
        except WorkflowPinError as error:
            errors.append(f"{source}:{line_number}: {error}")

    if errors:
        raise WorkflowPinError("\n".join(errors))
    return count


def check_workflow_directory(directory: Path) -> tuple[int, int]:
    workflows = sorted((*directory.glob("*.yml"), *directory.glob("*.yaml")))
    if not workflows:
        raise WorkflowPinError(f"no workflow files found in {directory}")
    references = 0
    for workflow in workflows:
        references += check_workflow_text(
            workflow.read_text(encoding="utf-8"), source=str(workflow)
        )
    return len(workflows), references


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "directory",
        nargs="?",
        type=Path,
        default=Path(__file__).resolve().parents[1] / ".github" / "workflows",
    )
    args = parser.parse_args(argv)
    try:
        workflow_count, reference_count = check_workflow_directory(args.directory)
    except (OSError, WorkflowPinError) as error:
        print(error, file=sys.stderr)
        return 1
    print(
        f"workflow pins valid: {workflow_count} workflow(s), "
        f"{reference_count} action reference(s)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
