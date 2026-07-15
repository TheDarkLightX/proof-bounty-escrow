from __future__ import annotations

import argparse
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch


SCRIPTS = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SCRIPTS))

import deploy_from_env as deploy  # noqa: E402


REVISION = "1" * 40
TREE = "2" * 40
DEPLOYER = "0x0000000000000000000000000000000000006000"
PREDICTED = "0xBfbA8Ac1858ed181b545C29eCE90C0398bC0380A"


def valid_config() -> dict[str, str]:
    return {
        "RPC_URL": "https://rpc.invalid/v1/redacted",
        "NETWORK_KEY": "pulsechain-v4",
        "EXPECTED_CHAIN_ID": "943",
        "EXPECTED_SOURCE_REVISION": REVISION,
        "EXPECTED_DEPLOYER": DEPLOYER,
        "EXPECTED_DEPLOYER_NONCE": "7",
        "PROTOCOL_NAME": "Proof Bounty Escrow",
        "DEVCO": "0x0000000000000000000000000000000000001000",
        "SECURITY_RESERVE": "0x0000000000000000000000000000000000002000",
        "VERIFIER_0": "0x0000000000000000000000000000000000003000",
        "VERIFIER_1": "0x0000000000000000000000000000000000004000",
        "VERIFIER_2": "0x0000000000000000000000000000000000005000",
        "TOKEN": deploy.ZERO_ADDRESS,
    }


def fake_preflight() -> deploy.Preflight:
    config = valid_config()
    return deploy.Preflight(
        config=config,
        child_env={"ETH_RPC_URL": config["RPC_URL"], "RPC_URL": config["RPC_URL"]},
        network={"key": "pulsechain-v4", "chainId": 943},
        source_revision=REVISION,
        source_tree=TREE,
        deployer=DEPLOYER,
        nonce=7,
        predicted_address=PREDICTED,
        forge="/reviewed/forge",
        cast="/reviewed/cast",
    )


class StrictEnvironmentTests(unittest.TestCase):
    def parse(self, text: str) -> dict[str, str]:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / ".env"
            path.write_text(text, encoding="utf-8")
            return deploy.parse_env_file(path)

    def test_accepts_only_literal_key_value_data(self) -> None:
        parsed = self.parse(
            "# reviewed\nRPC_URL=https://rpc.invalid/v1/key\n"
            'PROTOCOL_NAME="Proof Bounty Escrow"\nEXPECTED_CHAIN_ID=943\n'
        )
        self.assertEqual(parsed["PROTOCOL_NAME"], "Proof Bounty Escrow")
        self.assertEqual(parsed["EXPECTED_CHAIN_ID"], "943")

    def test_rejects_unknown_and_duplicate_keys(self) -> None:
        with self.assertRaisesRegex(deploy.DeploymentError, "unknown key"):
            self.parse("UNREVIEWED=value\n")
        with self.assertRaisesRegex(deploy.DeploymentError, "duplicate key"):
            self.parse("EXPECTED_CHAIN_ID=943\nEXPECTED_CHAIN_ID=943\n")

    def test_rejects_shell_syntax_instead_of_evaluating_it(self) -> None:
        with self.assertRaisesRegex(deploy.DeploymentError, "shell syntax"):
            self.parse("RPC_URL=$(touch /tmp/should-never-exist)\n")
        with self.assertRaisesRegex(deploy.DeploymentError, "shell syntax"):
            self.parse("PROTOCOL_NAME=(subshell)\n")
        self.assertFalse(Path("/tmp/should-never-exist").exists())

    def test_rejects_secret_material_and_account_alias(self) -> None:
        with self.assertRaisesRegex(deploy.DeploymentError, "secret-looking"):
            self.parse("DEPLOYER_PRIVATE_KEY=0x1234\n")
        with self.assertRaisesRegex(deploy.DeploymentError, "command-line"):
            self.parse("ACCOUNT=wallet-alias\n")

    def test_rejects_embedded_rpc_userinfo(self) -> None:
        with self.assertRaisesRegex(deploy.DeploymentError, "userinfo"):
            deploy.checked_rpc_url("https://user:password@rpc.invalid")


class SubprocessSafetyTests(unittest.TestCase):
    def test_command_uses_argv_and_never_a_shell(self) -> None:
        completed = SimpleNamespace(returncode=0, stdout="943\n", stderr="")
        with patch.object(subprocess, "run", return_value=completed) as run:
            result = deploy.command(["cast", "chain-id"], env={"ETH_RPC_URL": "redacted"})
        self.assertEqual(result, "943")
        kwargs = run.call_args.kwargs
        self.assertNotIn("shell", kwargs)
        self.assertEqual(run.call_args.args[0], ["cast", "chain-id"])

    def test_preflight_mocks_rpc_and_checks_pending_nonce(self) -> None:
        args = argparse.Namespace(variant="native", forge="forge", cast="cast")
        config = valid_config()
        calls: list[list[str]] = []

        def fake_command(argv: list[str], **_: object) -> str:
            calls.append(argv)
            if argv[1:] == ["chain-id"]:
                return "943"
            if argv[1:3] == ["nonce", DEPLOYER]:
                return "7"
            if argv[1:3] == ["compute-address", DEPLOYER]:
                return f"Computed Address: {PREDICTED}"
            raise AssertionError(argv)

        with (
            patch.object(deploy, "resolve_tool", side_effect=lambda value, _: f"/reviewed/{value}"),
            patch.object(deploy, "verify_toolchain"),
            patch.object(deploy, "verify_source", return_value=(REVISION, TREE)),
            patch.object(deploy, "command", side_effect=fake_command),
        ):
            result = deploy.deploy_preflight(args, config)

        self.assertEqual(result.predicted_address, PREDICTED)
        self.assertIn(
            ["/reviewed/cast", "nonce", DEPLOYER, "--block", "pending"], calls
        )
        self.assertTrue(all(config["RPC_URL"] not in argument for call in calls for argument in call))

    def test_role_separation_rejects_deployer_overlap(self) -> None:
        config = valid_config()
        config["DEVCO"] = DEPLOYER
        with self.assertRaisesRegex(deploy.DeploymentError, "pairwise distinct"):
            deploy.validate_deploy_config(config, "native")

        config = valid_config()
        config["TOKEN"] = DEPLOYER
        with self.assertRaisesRegex(deploy.DeploymentError, "deployer"):
            deploy.validate_deploy_config(config, "erc20")

        config = valid_config()
        config["TOKEN"] = config["VERIFIER_1"]
        with self.assertRaisesRegex(deploy.DeploymentError, "verifier"):
            deploy.validate_deploy_config(config, "erc20")

    def test_read_only_preflight_validates_token_before_network_selection(self) -> None:
        config = valid_config()
        config["TOKEN"] = "not-an-address"
        args = argparse.Namespace(forge="forge", cast="cast")
        with patch.object(deploy, "select_network") as select_network:
            with self.assertRaisesRegex(deploy.DeploymentError, "TOKEN"):
                deploy.read_only_preflight(args, config, required=("TOKEN",))
        select_network.assert_not_called()

    def test_default_is_plan_only_and_invokes_no_deployment_command(self) -> None:
        args = argparse.Namespace(
            variant="native", execute=False, simulate=False, account=None, forge="forge", cast="cast"
        )
        with (
            patch.object(deploy, "deploy_preflight", return_value=fake_preflight()),
            patch.object(deploy, "command") as command,
            patch("builtins.print"),
        ):
            deploy.run_deploy(args, valid_config())
        command.assert_not_called()

    def test_simulation_binds_sender_without_rpc_or_broadcast_arguments(self) -> None:
        args = argparse.Namespace(
            variant="native", execute=False, simulate=True, account=None, forge="forge", cast="cast"
        )
        command = Mock(return_value="")
        with (
            patch.object(deploy, "deploy_preflight", return_value=fake_preflight()),
            patch.object(deploy, "command", command),
            patch("builtins.print"),
        ):
            deploy.run_deploy(args, valid_config())

        argv = command.call_args.args[0]
        self.assertIn("--sender", argv)
        self.assertIn(DEPLOYER, argv)
        self.assertNotIn("--broadcast", argv)
        self.assertNotIn("--rpc-url", argv)
        self.assertNotIn(valid_config()["RPC_URL"], argv)

    def test_execute_is_mocked_rechecks_nonce_and_uses_keystore_alias(self) -> None:
        args = argparse.Namespace(
            variant="native",
            execute=True,
            simulate=False,
            account="reviewed-alias",
            forge="forge",
            cast="cast",
        )
        preflight = fake_preflight()
        calls: list[list[str]] = []

        def fake_command(argv: list[str], **_: object) -> str:
            calls.append(argv)
            if argv[1] == "chain-id":
                return "943"
            if argv[1] == "nonce":
                return "7"
            return ""

        with (
            patch.object(deploy, "deploy_preflight", return_value=preflight),
            patch.object(deploy, "command", side_effect=fake_command),
            patch.object(deploy, "verify_source", return_value=(REVISION, TREE)) as verify_source,
            patch("builtins.print"),
        ):
            deploy.run_deploy(args, valid_config())

        broadcast = calls[-1]
        self.assertIn("--broadcast", broadcast)
        self.assertEqual(broadcast[broadcast.index("--account") + 1], "reviewed-alias")
        self.assertNotIn("ACCOUNT", preflight.child_env)
        self.assertEqual(calls[-2], [preflight.cast, "nonce", DEPLOYER, "--block", "pending"])
        self.assertIn([preflight.cast, "chain-id"], calls)
        verify_source.assert_called_once_with(preflight.config, preflight.child_env)

    def test_execute_refuses_if_source_changes_after_preflight(self) -> None:
        args = argparse.Namespace(
            variant="native",
            execute=True,
            simulate=False,
            account="reviewed-alias",
            forge="forge",
            cast="cast",
        )
        with (
            patch.object(deploy, "deploy_preflight", return_value=fake_preflight()),
            patch.object(deploy, "verify_source", side_effect=deploy.DeploymentError("dirty")),
            patch.object(deploy, "command") as command,
            patch("builtins.print"),
        ):
            with self.assertRaisesRegex(deploy.DeploymentError, "dirty"):
                deploy.run_deploy(args, valid_config())
        command.assert_not_called()

    def test_execute_requires_cli_account(self) -> None:
        args = argparse.Namespace(
            variant="native", execute=True, simulate=False, account=None, forge="forge", cast="cast"
        )
        with self.assertRaisesRegex(deploy.DeploymentError, "requires"):
            deploy.run_deploy(args, valid_config())


if __name__ == "__main__":
    unittest.main()
