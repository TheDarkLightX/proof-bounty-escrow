from __future__ import annotations

import sys
import unittest
from pathlib import Path


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

from check_workflow_pins import WorkflowPinError, check_workflow_text  # noqa: E402


PIN = "34e114876b0b11c390a56381ad16ebd13914f8d5"


class WorkflowPinTests(unittest.TestCase):
    def test_accepts_full_sha_with_version_comment(self) -> None:
        count = check_workflow_text(f"steps:\n  - uses: actions/checkout@{PIN} # v4\n")
        self.assertEqual(count, 1)

    def test_accepts_local_action_without_comment(self) -> None:
        count = check_workflow_text("steps:\n  - uses: ./.github/actions/build\n")
        self.assertEqual(count, 1)

    def test_rejects_mutable_tag(self) -> None:
        with self.assertRaisesRegex(WorkflowPinError, "40-hex"):
            check_workflow_text("steps:\n  - uses: actions/checkout@v4 # v4\n")

    def test_rejects_sha_without_version_comment(self) -> None:
        with self.assertRaisesRegex(WorkflowPinError, "version comment"):
            check_workflow_text(f"steps:\n  - uses: actions/checkout@{PIN}\n")

    def test_rejects_expression_reference(self) -> None:
        with self.assertRaises(WorkflowPinError):
            check_workflow_text("jobs:\n  call:\n    uses: owner/repo/.github/workflows/x.yml@${{ github.ref }}\n")

    def test_rejects_quoted_or_inline_key_syntax(self) -> None:
        with self.assertRaisesRegex(WorkflowPinError, "unsupported uses syntax"):
            check_workflow_text(f"steps:\n  - {{'uses': actions/checkout@{PIN}}}\n")

    def test_ignores_comments_that_mention_uses(self) -> None:
        self.assertEqual(check_workflow_text("# uses: actions/checkout@v4\n"), 0)


if __name__ == "__main__":
    unittest.main()
