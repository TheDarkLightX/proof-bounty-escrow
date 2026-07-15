#!/usr/bin/env python3
"""Plan, simulate, broadcast, audit, or record a deployment without sourcing a shell file.

The configuration file is deliberately a small data format, not dotenv compatibility.  Only
reviewed KEY=VALUE fields are accepted.  No line is evaluated by a shell and signing material is
never accepted from the file.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path
from urllib.parse import urlsplit


ROOT = Path(__file__).resolve().parents[1]
NETWORKS = ROOT / "deployments" / "networks.json"
ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
ADDRESS_IN_TEXT = re.compile(r"0x[0-9a-fA-F]{40}")
REVISION = re.compile(r"^[0-9a-f]{40}$")
INTEGER = re.compile(r"^(0|[1-9][0-9]*)$")
KEY = re.compile(r"^[A-Z][A-Z0-9_]*$")
ACCOUNT_ALIAS = re.compile(r"^[A-Za-z0-9._-]{1,128}$")
SHELL_META = re.compile(r"[`$;&|<>(){}\\\x00-\x1f\x7f]")
SECRET_KEY = re.compile(
    r"(?:^|_)(?:PRIVATE_KEY|MNEMONIC|PASSWORD|PASSPHRASE|SECRET|API_KEY|AUTH_TOKEN|"
    r"ACCESS_TOKEN|KEYSTORE_PASSWORD)(?:$|_)"
)

ALLOWED_KEYS = frozenset(
    {
        "RPC_URL",
        "NETWORK_KEY",
        "EXPECTED_CHAIN_ID",
        "EXPECTED_SOURCE_REVISION",
        "EXPECTED_DEPLOYER",
        "EXPECTED_DEPLOYER_NONCE",
        "PROTOCOL_NAME",
        "DEVCO",
        "SECURITY_RESERVE",
        "VERIFIER_0",
        "VERIFIER_1",
        "VERIFIER_2",
        "TOKEN",
        "DEPLOYMENT",
        "EXPECTED_RUNTIME_CODE_HASH",
        "DEPLOYMENT_TX_HASH",
        "CONFIRMATIONS",
        "MANIFEST_OUTPUT",
        "SOURCE_REPOSITORY",
    }
)

COMMON_DEPLOY_KEYS = (
    "RPC_URL",
    "NETWORK_KEY",
    "EXPECTED_CHAIN_ID",
    "EXPECTED_SOURCE_REVISION",
    "EXPECTED_DEPLOYER",
    "EXPECTED_DEPLOYER_NONCE",
    "PROTOCOL_NAME",
    "DEVCO",
    "SECURITY_RESERVE",
    "VERIFIER_0",
    "VERIFIER_1",
    "VERIFIER_2",
    "TOKEN",
)

EXPECTED_FOUNDRY_VERSION = "1.7.1"
EXPECTED_FOUNDRY_REVISION = "4072e48705af9d93e3c0f6e29e93b5e9a40caed8"
ZERO_ADDRESS = "0x" + "0" * 40


class DeploymentError(RuntimeError):
    """A fail-closed configuration or preflight error."""


@dataclass(frozen=True)
class Preflight:
    config: dict[str, str]
    child_env: dict[str, str]
    network: dict[str, object]
    source_revision: str
    source_tree: str
    deployer: str
    nonce: int
    predicted_address: str
    forge: str
    cast: str


def parse_env_file(path: Path) -> dict[str, str]:
    """Parse the repository's strict, non-executable deployment configuration format."""

    try:
        text = path.read_text(encoding="utf-8")
    except OSError as exc:
        raise DeploymentError(f"cannot read configuration file: {path}") from exc

    result: dict[str, str] = {}
    for line_number, raw_line in enumerate(text.splitlines(), start=1):
        if not raw_line or raw_line.startswith("#"):
            continue
        if raw_line != raw_line.strip():
            raise DeploymentError(f"line {line_number}: surrounding whitespace is not allowed")
        if "=" not in raw_line:
            raise DeploymentError(f"line {line_number}: expected KEY=VALUE")
        key, raw_value = raw_line.split("=", 1)
        if not KEY.fullmatch(key):
            raise DeploymentError(f"line {line_number}: invalid key syntax")
        if key == "ACCOUNT":
            raise DeploymentError("ACCOUNT must be passed only with the --account command-line option")
        if SECRET_KEY.search(key):
            raise DeploymentError(f"line {line_number}: secret-looking keys are forbidden")
        if key not in ALLOWED_KEYS:
            raise DeploymentError(f"line {line_number}: unknown key {key}")
        if key in result:
            raise DeploymentError(f"line {line_number}: duplicate key {key}")
        if SHELL_META.search(raw_value):
            raise DeploymentError(f"line {line_number}: shell syntax is forbidden")

        if raw_value.startswith(("'", '"')):
            quote = raw_value[0]
            if len(raw_value) < 2 or raw_value[-1] != quote or quote in raw_value[1:-1]:
                raise DeploymentError(f"line {line_number}: malformed quoted value")
            value = raw_value[1:-1]
        else:
            if "'" in raw_value or '"' in raw_value or raw_value != raw_value.strip():
                raise DeploymentError(f"line {line_number}: spaces require one matching quote pair")
            if "#" in raw_value:
                raise DeploymentError(f"line {line_number}: inline comments are not supported")
            value = raw_value
        result[key] = value

    return result


def require_values(config: dict[str, str], keys: tuple[str, ...]) -> None:
    missing = [key for key in keys if not config.get(key)]
    if missing:
        raise DeploymentError("missing required configuration keys: " + ", ".join(missing))


def parse_uint(value: str, label: str) -> int:
    if not INTEGER.fullmatch(value):
        raise DeploymentError(f"{label} must be a canonical nonnegative decimal integer")
    return int(value, 10)


def checked_address(value: str, label: str, *, nonzero: bool = False) -> str:
    if not ADDRESS.fullmatch(value):
        raise DeploymentError(f"{label} must be a 20-byte 0x address")
    if nonzero and value.casefold() == ZERO_ADDRESS:
        raise DeploymentError(f"{label} must be nonzero")
    return value


def checked_rpc_url(value: str) -> str:
    parsed = urlsplit(value)
    if parsed.scheme not in {"http", "https"} or not parsed.netloc:
        raise DeploymentError("RPC_URL must be an absolute http(s) URL")
    if parsed.username is not None or parsed.password is not None:
        raise DeploymentError("RPC_URL must not contain URL userinfo credentials")
    return value


def command(
    argv: list[str],
    *,
    env: dict[str, str],
    capture: bool = True,
    timeout: int = 180,
) -> str:
    """Run one argv-only subprocess. Error text never repeats its possibly sensitive argv."""

    completed = subprocess.run(
        argv,
        cwd=ROOT,
        env=env,
        stdin=None if not capture else subprocess.DEVNULL,
        stdout=subprocess.PIPE if capture else None,
        stderr=subprocess.PIPE if capture else None,
        text=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        raise DeploymentError("a preflight or deployment subprocess failed; inspect its sanitized tool output")
    return completed.stdout.strip() if capture and completed.stdout is not None else ""


def resolve_tool(requested: str, label: str) -> str:
    resolved = shutil.which(requested)
    if resolved is None:
        raise DeploymentError(f"{label} is required on PATH")
    return resolved


def child_environment(config: dict[str, str]) -> dict[str, str]:
    """Exclude ambient Foundry/wallet variables and pass only operating-system and reviewed data."""

    inherited = (
        "PATH",
        "HOME",
        "USER",
        "LOGNAME",
        "TMPDIR",
        "XDG_CONFIG_HOME",
        "SSL_CERT_FILE",
        "SSL_CERT_DIR",
        "HTTP_PROXY",
        "HTTPS_PROXY",
        "NO_PROXY",
        "TERM",
    )
    result = {key: os.environ[key] for key in inherited if key in os.environ}
    result.update(config)
    # Foundry and cast consume this without placing the endpoint in process arguments.
    result["ETH_RPC_URL"] = config["RPC_URL"]
    result["NO_COLOR"] = "1"
    return result


def verify_source(config: dict[str, str], env: dict[str, str]) -> tuple[str, str]:
    expected = config.get("EXPECTED_SOURCE_REVISION", "")
    if not REVISION.fullmatch(expected):
        raise DeploymentError("EXPECTED_SOURCE_REVISION must be an exact lowercase 40-hex commit")
    head = command(["git", "rev-parse", "--verify", "HEAD"], env=env)
    if head != expected:
        raise DeploymentError("checked-out HEAD does not equal EXPECTED_SOURCE_REVISION")
    dirty = command(
        ["git", "status", "--porcelain=v1", "--untracked-files=all"], env=env
    )
    if dirty:
        raise DeploymentError("refusing to proceed from a dirty or untracked worktree")
    tree = command(["git", "rev-parse", "HEAD^{tree}"], env=env)
    if not REVISION.fullmatch(tree):
        raise DeploymentError("could not resolve the reviewed source tree")
    return head, tree


def select_network(config: dict[str, str], variant: str) -> dict[str, object]:
    try:
        catalog = json.loads(NETWORKS.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise DeploymentError("cannot read deployments/networks.json") from exc
    matches = [item for item in catalog.get("networks", []) if item.get("key") == config.get("NETWORK_KEY")]
    if len(matches) != 1:
        raise DeploymentError("NETWORK_KEY must match exactly one reviewed network catalog entry")
    network = matches[0]
    expected_chain_id = parse_uint(config.get("EXPECTED_CHAIN_ID", ""), "EXPECTED_CHAIN_ID")
    if expected_chain_id != network.get("chainId"):
        raise DeploymentError("EXPECTED_CHAIN_ID does not match the selected NETWORK_KEY")
    if variant not in network.get("variants", []):
        raise DeploymentError("selected deployment variant is not approved for this network")
    return network


def verify_toolchain(forge: str, cast: str, env: dict[str, str]) -> None:
    for executable, label in ((forge, "forge"), (cast, "cast")):
        version = command([executable, "--version"], env=env)
        if f"Version: {EXPECTED_FOUNDRY_VERSION}" not in version:
            raise DeploymentError(f"{label} must be exact version {EXPECTED_FOUNDRY_VERSION}")
        if f"Commit SHA: {EXPECTED_FOUNDRY_REVISION}" not in version:
            raise DeploymentError(f"{label} is not the reviewed Foundry build revision")

    try:
        foundry_config = json.loads(command([forge, "config", "--json"], env=env))
    except json.JSONDecodeError as exc:
        raise DeploymentError("forge config did not return JSON") from exc
    expected = {
        "solc": "0.8.36",
        "evm_version": "paris",
        "optimizer": True,
        "optimizer_runs": 200,
        "via_ir": False,
        "bytecode_hash": "ipfs",
    }
    for key, value in expected.items():
        if foundry_config.get(key) != value:
            raise DeploymentError(f"reviewed Foundry setting mismatch: {key}")
    command([forge, "build", "--offline", "--force"], env=env, capture=False, timeout=300)


def validate_deploy_config(config: dict[str, str], variant: str) -> tuple[str, int]:
    require_values(config, COMMON_DEPLOY_KEYS)
    checked_rpc_url(config["RPC_URL"])
    deployer = checked_address(config["EXPECTED_DEPLOYER"], "EXPECTED_DEPLOYER", nonzero=True)
    nonce = parse_uint(config["EXPECTED_DEPLOYER_NONCE"], "EXPECTED_DEPLOYER_NONCE")
    if not 1 <= len(config["PROTOCOL_NAME"].encode("utf-8")) <= 64:
        raise DeploymentError("PROTOCOL_NAME must contain 1 through 64 UTF-8 bytes")

    dev_co = checked_address(config["DEVCO"], "DEVCO", nonzero=True)
    reserve = checked_address(config["SECURITY_RESERVE"], "SECURITY_RESERVE", nonzero=True)
    verifiers = [
        checked_address(config[f"VERIFIER_{index}"], f"VERIFIER_{index}", nonzero=True)
        for index in range(3)
    ]
    roles = [deployer, dev_co, reserve, *verifiers]
    if len({address.casefold() for address in roles}) != len(roles):
        raise DeploymentError("deployer, fee recipients, and verifiers must be pairwise distinct")
    if [int(address, 16) for address in verifiers] != sorted(int(address, 16) for address in verifiers):
        raise DeploymentError("verifier addresses must be in strict numeric ascending order")

    token = checked_address(config["TOKEN"], "TOKEN")
    if variant == "native" and token.casefold() != ZERO_ADDRESS:
        raise DeploymentError("TOKEN must be the zero address for a native deployment")
    if variant == "erc20" and token.casefold() == ZERO_ADDRESS:
        raise DeploymentError("TOKEN must be nonzero for an ERC-20 deployment")
    if variant == "erc20" and token.casefold() in {address.casefold() for address in roles}:
        raise DeploymentError(
            "the ERC-20 asset cannot also be the deployer, a fee recipient, or a verifier"
        )
    return deployer, nonce


def deploy_preflight(args: argparse.Namespace, config: dict[str, str]) -> Preflight:
    deployer, nonce = validate_deploy_config(config, args.variant)
    network = select_network(config, args.variant)
    env = child_environment(config)
    source_revision, source_tree = verify_source(config, env)
    forge = resolve_tool(args.forge, "forge")
    cast = resolve_tool(args.cast, "cast")
    verify_toolchain(forge, cast, env)

    observed_chain_id = parse_uint(command([cast, "chain-id"], env=env), "observed chain ID")
    if observed_chain_id != network["chainId"]:
        raise DeploymentError("RPC chain ID does not match the reviewed network")
    observed_nonce = parse_uint(
        command([cast, "nonce", deployer, "--block", "pending"], env=env),
        "observed pending nonce",
    )
    if observed_nonce != nonce:
        raise DeploymentError("pending deployer nonce does not equal EXPECTED_DEPLOYER_NONCE")
    computed = command([cast, "compute-address", deployer, "--nonce", str(nonce)], env=env)
    matches = ADDRESS_IN_TEXT.findall(computed)
    if len(matches) != 1:
        raise DeploymentError("cast did not return exactly one predicted CREATE address")

    return Preflight(
        config=config,
        child_env=env,
        network=network,
        source_revision=source_revision,
        source_tree=source_tree,
        deployer=deployer,
        nonce=nonce,
        predicted_address=matches[0],
        forge=forge,
        cast=cast,
    )


def print_plan(preflight: Preflight, variant: str, mode: str) -> None:
    print("Deployment preflight passed")
    print(f"  mode: {mode}")
    print(f"  network: {preflight.network['key']} (chain {preflight.network['chainId']})")
    print(f"  variant: {variant}")
    print(f"  source revision: {preflight.source_revision}")
    print(f"  source tree: {preflight.source_tree}")
    print(f"  expected deployer: {preflight.deployer}")
    print(f"  expected pending nonce: {preflight.nonce}")
    print(f"  predicted CREATE address: {preflight.predicted_address}")
    print("  RPC endpoint and keystore alias: intentionally redacted")


def run_deploy(args: argparse.Namespace, config: dict[str, str]) -> None:
    if args.execute and not args.account:
        raise DeploymentError("--execute requires a Foundry keystore alias via --account")
    if args.execute and not ACCOUNT_ALIAS.fullmatch(args.account):
        raise DeploymentError("--account must be a simple Foundry keystore alias")
    if not args.execute and args.account:
        raise DeploymentError("--account is accepted only together with --execute")
    mode = "broadcast" if args.execute else "simulation" if args.simulate else "plan only"
    preflight = deploy_preflight(args, config)
    print_plan(preflight, args.variant, mode)
    if not args.execute and not args.simulate:
        print("No simulation or broadcast was requested. Add --simulate or --execute explicitly.")
        return

    target = (
        "script/DeployNative.s.sol:DeployNative"
        if args.variant == "native"
        else "script/DeployERC20.s.sol:DeployERC20"
    )
    argv = [
        preflight.forge,
        "script",
        target,
        "--offline",
        "--sender",
        preflight.deployer,
        "-vvvv",
    ]
    if args.execute:
        # The alias is intentionally accepted only on the command line. Foundry performs the
        # account/deployer match while signing; this process never reads a key or password.
        argv.extend(["--account", args.account, "--broadcast", "--slow"])
        print("Broadcast explicitly authorized; rechecking source, chain, and nonce before signing.")
        rechecked_deployer, rechecked_nonce = validate_deploy_config(preflight.config, args.variant)
        if (
            rechecked_deployer.casefold() != preflight.deployer.casefold()
            or rechecked_nonce != preflight.nonce
        ):
            raise DeploymentError("reviewed deployer context changed after preflight")
        revision, tree = verify_source(preflight.config, preflight.child_env)
        if revision != preflight.source_revision or tree != preflight.source_tree:
            raise DeploymentError("reviewed source context changed after preflight")
        observed_chain_id = parse_uint(
            command([preflight.cast, "chain-id"], env=preflight.child_env),
            "observed chain ID",
        )
        if observed_chain_id != preflight.network["chainId"]:
            raise DeploymentError("RPC chain changed after preflight; refusing broadcast")
        observed_nonce = parse_uint(
            command(
                [preflight.cast, "nonce", preflight.deployer, "--block", "pending"],
                env=preflight.child_env,
            ),
            "observed pending nonce",
        )
        if observed_nonce != preflight.nonce:
            raise DeploymentError("pending nonce changed after preflight; refusing broadcast")
    command(argv, env=preflight.child_env, capture=False, timeout=900)


def read_only_preflight(
    args: argparse.Namespace, config: dict[str, str], *, required: tuple[str, ...]
) -> tuple[dict[str, str], str, str, dict[str, object], str, str]:
    require_values(
        config,
        ("RPC_URL", "NETWORK_KEY", "EXPECTED_CHAIN_ID", "EXPECTED_SOURCE_REVISION", *required),
    )
    checked_rpc_url(config["RPC_URL"])
    token = checked_address(config.get("TOKEN", ""), "TOKEN")
    variant = "native" if token.casefold() == ZERO_ADDRESS else "erc20"
    network = select_network(config, variant)
    env = child_environment(config)
    revision, tree = verify_source(config, env)
    forge = resolve_tool(args.forge, "forge")
    cast = resolve_tool(args.cast, "cast")
    verify_toolchain(forge, cast, env)
    observed_chain_id = parse_uint(command([cast, "chain-id"], env=env), "observed chain ID")
    if observed_chain_id != network["chainId"]:
        raise DeploymentError("RPC chain ID does not match the reviewed network")
    return env, revision, tree, network, forge, cast


def run_audit(args: argparse.Namespace, config: dict[str, str]) -> None:
    required = (
        "PROTOCOL_NAME",
        "DEVCO",
        "SECURITY_RESERVE",
        "VERIFIER_0",
        "VERIFIER_1",
        "VERIFIER_2",
        "TOKEN",
        "DEPLOYMENT",
        "EXPECTED_RUNTIME_CODE_HASH",
    )
    env, revision, tree, network, forge, _ = read_only_preflight(args, config, required=required)
    checked_address(config["DEPLOYMENT"], "DEPLOYMENT", nonzero=True)
    if not re.fullmatch(r"0x[0-9a-fA-F]{64}", config["EXPECTED_RUNTIME_CODE_HASH"]):
        raise DeploymentError("EXPECTED_RUNTIME_CODE_HASH must be bytes32")
    print(f"Auditing reviewed revision {revision} / tree {tree} on {network['key']}; RPC is redacted")
    command(
        [forge, "script", "script/AuditDeployment.s.sol:AuditDeployment", "--offline", "-vvvv"],
        env=env,
        capture=False,
        timeout=900,
    )


def run_manifest(args: argparse.Namespace, config: dict[str, str]) -> None:
    required = (
        "PROTOCOL_NAME",
        "TOKEN",
        "DEPLOYMENT",
        "DEPLOYMENT_TX_HASH",
        "EXPECTED_RUNTIME_CODE_HASH",
        "MANIFEST_OUTPUT",
    )
    env, revision, tree, network, _, _ = read_only_preflight(args, config, required=required)
    confirmations = parse_uint(config.get("CONFIRMATIONS", "1"), "CONFIRMATIONS")
    if confirmations < 1:
        raise DeploymentError("CONFIRMATIONS must be positive")
    argv = [
        sys.executable,
        "scripts/generate_deployment_manifest.py",
        "--network-key",
        config["NETWORK_KEY"],
        "--deployment",
        config["DEPLOYMENT"],
        "--transaction-hash",
        config["DEPLOYMENT_TX_HASH"],
        "--protocol-name",
        config["PROTOCOL_NAME"],
        "--expected-runtime-code-hash",
        config["EXPECTED_RUNTIME_CODE_HASH"],
        "--source-revision",
        revision,
        "--confirmations",
        str(confirmations),
        "--output",
        config["MANIFEST_OUTPUT"],
    ]
    if config.get("SOURCE_REPOSITORY"):
        argv.extend(["--source-repository", config["SOURCE_REPOSITORY"]])
    if args.overwrite:
        argv.append("--overwrite")
    print(f"Generating an unsigned observation for revision {revision} / tree {tree} on {network['key']}")
    print("RPC endpoint is intentionally redacted")
    command(argv, env=env, capture=False, timeout=900)


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--env-file", type=Path, default=Path(".env"))
    result.add_argument("--forge", default="forge")
    result.add_argument("--cast", default="cast")
    subparsers = result.add_subparsers(dest="operation", required=True)

    deploy = subparsers.add_parser("deploy", help="plan, simulate, or explicitly broadcast")
    deploy.add_argument("--variant", choices=("native", "erc20"), required=True)
    mode = deploy.add_mutually_exclusive_group()
    mode.add_argument("--simulate", action="store_true", help="run the Foundry simulation only")
    mode.add_argument("--execute", action="store_true", help="broadcast after every preflight passes")
    deploy.add_argument("--account", help="Foundry keystore alias; valid only with --execute")

    subparsers.add_parser("audit", help="replay the checked-in immutable deployment audit")
    manifest = subparsers.add_parser("manifest", help="generate an unsigned deployment observation")
    manifest.add_argument("--overwrite", action="store_true")
    return result


def main(argv: list[str] | None = None) -> int:
    args = parser().parse_args(argv)
    try:
        config = parse_env_file(args.env_file)
        if args.operation == "deploy":
            run_deploy(args, config)
        elif args.operation == "audit":
            run_audit(args, config)
        else:
            run_manifest(args, config)
    except DeploymentError as exc:
        print(f"error: {exc}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
