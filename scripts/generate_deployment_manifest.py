#!/usr/bin/env python3
"""Generate an unsigned deployment observation from a finalized creation transaction.

The tool is read-only with respect to the chain and never handles a signer. It binds observed
chain state to a clean local revision and exact locally compiled creation bytecode. The output is
still not an explorer verification, token review, smoke-test receipt, reviewer signature, or
activation decision; those belong in a separately reviewed release dossier.
"""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import re
import shutil
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
NETWORKS = ROOT / "deployments" / "networks.json"
PACKAGE_LOCK = ROOT / "package-lock.json"
FORGE_STD = ROOT / "lib" / "forge-std"
ZERO_ADDRESS = "0x" + "0" * 40
HASH = re.compile(r"^0x[0-9a-fA-F]{64}$")
ADDRESS = re.compile(r"^0x[0-9a-fA-F]{40}$")
REVISION = re.compile(r"^[0-9a-f]{40}$")
HEX_DATA = re.compile(r"^0x(?:[0-9a-fA-F]{2})*$")
INTEGER_TEXT = re.compile(r"^(0[xX][0-9a-fA-F]+|[0-9]+)(?:\s+\[[^\]\r\n]+\])?$")


def command(argv: list[str], *, cwd: Path = ROOT, timeout: int = 90) -> str:
    completed = subprocess.run(
        argv,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        timeout=timeout,
        check=False,
    )
    if completed.returncode != 0:
        detail = completed.stderr.strip() or completed.stdout.strip()
        preview = " ".join(argv[:2])
        raise RuntimeError(f"command failed ({preview}): {detail}")
    return completed.stdout.strip()


def parse_int(value: object, label: str) -> int:
    if isinstance(value, int):
        result = value
    elif isinstance(value, str):
        normalized = value.strip().strip('"')
        matched = INTEGER_TEXT.fullmatch(normalized)
        if matched is None:
            raise ValueError(f"{label} is not an integer")
        result = int(matched.group(1), 0)
    else:
        raise ValueError(f"{label} is not an integer")
    if result < 0:
        raise ValueError(f"{label} must be nonnegative")
    return result


def checked_address(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{label} is not a string address")
    normalized = value.strip().strip('"')
    if not ADDRESS.fullmatch(normalized):
        raise ValueError(f"{label} is not an address: {normalized}")
    return normalized


def checked_hash(value: object, label: str) -> str:
    if not isinstance(value, str):
        raise ValueError(f"{label} is not a string hash")
    normalized = value.strip().strip('"')
    if not HASH.fullmatch(normalized):
        raise ValueError(f"{label} is not a bytes32 value: {normalized}")
    return normalized


def same_address(left: str, right: str) -> bool:
    return left.casefold() == right.casefold()


def bytes_hex(value: bytes) -> str:
    return "0x" + value.hex()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def sha256_tree(root: Path) -> str:
    if not root.is_dir():
        raise RuntimeError(f"dependency tree is missing: {root.relative_to(ROOT)}")
    digest = hashlib.sha256()
    files = sorted(path for path in root.rglob("*") if path.is_file() and ".git" not in path.parts)
    if not files:
        raise RuntimeError(f"dependency tree is empty: {root.relative_to(ROOT)}")
    for path in files:
        relative = path.relative_to(root).as_posix().encode("utf-8")
        content_hash = bytes.fromhex(sha256_file(path))
        digest.update(len(relative).to_bytes(8, "big"))
        digest.update(relative)
        digest.update(content_hash)
    return digest.hexdigest()


def require_clean_revision(requested: str | None) -> str:
    head = command(["git", "rev-parse", "--verify", "HEAD"])
    if not REVISION.fullmatch(head):
        raise RuntimeError("HEAD is not a full Git commit")
    if requested is not None and requested != head:
        raise RuntimeError("--source-revision must equal the checked-out HEAD")
    dirty = command(["git", "status", "--porcelain=v1", "--untracked-files=normal"])
    if dirty:
        raise RuntimeError("refusing deployment observation from a dirty or untracked worktree")
    return head


def verify_toolchain(forge: str) -> dict[str, object]:
    version_output = command([forge, "--version"])
    if "Version: 1.7.1" not in version_output:
        raise RuntimeError("forge must be exact version 1.7.1")
    config = json.loads(command([forge, "config", "--json"]))
    expected = {
        "solc": "0.8.36",
        "evm_version": "paris",
        "optimizer": True,
        "optimizer_runs": 200,
        "via_ir": False,
        "bytecode_hash": "ipfs",
    }
    for key, value in expected.items():
        if config.get(key) != value:
            raise RuntimeError(f"unexpected Foundry setting {key}: {config.get(key)!r}")

    lock = json.loads(PACKAGE_LOCK.read_text(encoding="utf-8"))
    openzeppelin = lock.get("packages", {}).get("node_modules/@openzeppelin/contracts", {})
    expected_integrity = "sha512-ytPc6eLGcHHnapAZ9S+5qsdomhjo6QBHTDRRBFfTxXIpsicMhVPouPgmUPebZZZGX7vt9USA+Z+0M0dSVtSUEA=="
    if openzeppelin.get("version") != "5.0.2" or openzeppelin.get("integrity") != expected_integrity:
        raise RuntimeError("package-lock.json does not pin the reviewed OpenZeppelin 5.0.2 archive")
    forge_std_package = json.loads((FORGE_STD / "package.json").read_text(encoding="utf-8"))
    if forge_std_package.get("version") != "1.16.2":
        raise RuntimeError("lib/forge-std is not version 1.16.2")

    command([forge, "build", "--offline", "--force"], timeout=180)
    return {
        "foundry": "1.7.1",
        "forgeBinarySha256": sha256_file(Path(forge).resolve()),
        "forgeStd": "1.16.2",
        "forgeStdTreeSha256": sha256_tree(FORGE_STD),
        "openzeppelinContracts": "5.0.2",
        "openzeppelinIntegrity": expected_integrity,
        "solc": "0.8.36",
        "evmVersion": "paris",
        "optimizerEnabled": True,
        "optimizerRuns": 200,
        "viaIr": False,
        "metadataBytecodeHash": "ipfs",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--network-key", required=True)
    parser.add_argument("--rpc-url", default=os.environ.get("RPC_URL"))
    parser.add_argument("--deployment", required=True)
    parser.add_argument("--transaction-hash", required=True)
    parser.add_argument("--protocol-name", required=True)
    parser.add_argument("--expected-runtime-code-hash", required=True)
    parser.add_argument("--source-revision")
    parser.add_argument("--source-repository")
    parser.add_argument("--confirmations", type=int, default=1)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--overwrite", action="store_true")
    args = parser.parse_args()

    if not args.rpc_url:
        parser.error("--rpc-url or RPC_URL is required")
    if args.confirmations < 1:
        parser.error("--confirmations must be positive")
    deployment = checked_address(args.deployment, "deployment")
    transaction_hash = checked_hash(args.transaction_hash, "transaction hash")
    expected_runtime_code_hash = checked_hash(args.expected_runtime_code_hash, "expected runtime code hash")
    if not 1 <= len(args.protocol_name.encode("utf-8")) <= 64:
        parser.error("--protocol-name must contain 1 through 64 UTF-8 bytes")

    revision = require_clean_revision(args.source_revision)
    forge = shutil.which("forge")
    cast = shutil.which("cast")
    if forge is None or cast is None:
        raise SystemExit("forge and cast are required on PATH")
    toolchain = verify_toolchain(forge)

    catalog = json.loads(NETWORKS.read_text(encoding="utf-8"))
    matches = [item for item in catalog["networks"] if item["key"] == args.network_key]
    if len(matches) != 1:
        parser.error("--network-key must match exactly one deployments/networks.json entry")
    network = matches[0]

    rpc = ["--rpc-url", args.rpc_url]
    observed_chain_id = parse_int(command([cast, "chain-id", *rpc]), "chain ID")
    if observed_chain_id != network["chainId"]:
        raise RuntimeError(
            f"wrong RPC chain: catalog expects {network['chainId']}, observed {observed_chain_id}"
        )

    receipt = json.loads(
        command(
            [
                cast,
                "receipt",
                "--json",
                "--confirmations",
                str(args.confirmations),
                transaction_hash,
                *rpc,
            ]
        )
    )
    if parse_int(receipt.get("status", 0), "receipt status") != 1:
        raise RuntimeError("deployment transaction did not succeed")
    receipt_contract = checked_address(receipt.get("contractAddress", ""), "receipt contractAddress")
    if not same_address(receipt_contract, deployment):
        raise RuntimeError("receipt contractAddress does not match --deployment")
    deployer = checked_address(receipt.get("from", ""), "receipt from")
    block_number = parse_int(receipt.get("blockNumber"), "receipt blockNumber")
    block_hash = checked_hash(receipt.get("blockHash", ""), "receipt blockHash")

    transaction = json.loads(command([cast, "tx", transaction_hash, "--json", *rpc]))
    if transaction.get("to") is not None:
        raise RuntimeError("deployment transaction is not a top-level contract creation")
    transaction_from = checked_address(transaction.get("from", ""), "transaction from")
    transaction_block_hash = checked_hash(transaction.get("blockHash", ""), "transaction blockHash")
    if not same_address(transaction_from, deployer) or transaction_block_hash.casefold() != block_hash.casefold():
        raise RuntimeError("transaction and receipt provenance disagree")
    transaction_input = transaction.get("input")
    if not isinstance(transaction_input, str) or not HEX_DATA.fullmatch(transaction_input):
        raise RuntimeError("deployment transaction input is not even-length hex data")

    def call(signature: str, *arguments: str) -> str:
        return command([cast, "call", deployment, signature, *arguments, *rpc])

    if parse_int(command([cast, "codesize", deployment, *rpc]), "code size") == 0:
        raise RuntimeError("deployment has no runtime code")
    runtime_code_hash = checked_hash(command([cast, "codehash", deployment, *rpc]), "runtime code hash")
    if runtime_code_hash.casefold() != expected_runtime_code_hash.casefold():
        raise RuntimeError("runtime code hash does not match the independently supplied expectation")
    asset = checked_address(call("asset()(address)"), "asset")
    protocol_version = call("PROTOCOL_VERSION()(string)").strip('"')
    protocol_id = checked_hash(call("PROTOCOL_ID()(bytes32)"), "protocol ID")
    deployment_id = checked_hash(call("deploymentId()(bytes32)"), "deployment ID")
    dev_co = checked_address(call("devCo()(address)"), "DevCo")
    security_reserve = checked_address(call("securityReserve()(address)"), "security reserve")
    verifiers = [checked_address(call("verifierAt(uint256)(address)", str(i)), f"verifier {i}") for i in range(3)]
    verifier_set_hash = checked_hash(call("verifierSetHash()(bytes32)"), "verifier set hash")
    threshold = parse_int(call("VERIFIER_THRESHOLD()(uint8)"), "verifier threshold")
    dev_bps = parse_int(call("DEVCO_BPS()(uint16)"), "DevCo bps")
    minimum_verifier_bps = parse_int(call("MIN_VERIFIER_BPS()(uint16)"), "minimum verifier bps")
    maximum_verifier_bps = parse_int(call("MAX_VERIFIER_BPS()(uint16)"), "maximum verifier bps")
    reserve_bps = parse_int(call("SECURITY_BPS()(uint16)"), "security bps")
    fixed_bps = parse_int(call("FIXED_FEE_BPS()(uint16)"), "fixed fee bps")
    minimum_reward_units = parse_int(call("MIN_REWARD_UNITS()(uint256)"), "minimum reward units")
    minimum_verifier_fee_units = parse_int(
        call("MIN_VERIFIER_FEE_UNITS()(uint256)"), "minimum verifier fee units"
    )
    minimum_dust_probe = parse_int(
        call("minimumVerifierFee(uint256)(uint256)", "199"), "minimum verifier fee dust probe"
    )
    minimum_probe = parse_int(call("minimumVerifierFee(uint256)(uint256)", "10200"), "minimum verifier fee probe")
    maximum_probe = parse_int(call("maximumVerifierFee(uint256)(uint256)", "10200"), "maximum verifier fee probe")
    funding_probe = parse_int(
        call("requiredFunding(uint256,uint256)(uint256)", "10200", "10200"),
        "required funding probe",
    )
    if (
        protocol_version != "1"
        or threshold != 2
        or (dev_bps, reserve_bps, fixed_bps, minimum_verifier_bps, maximum_verifier_bps)
        != (200, 50, 250, 50, 10_000)
        or (minimum_reward_units, minimum_verifier_fee_units, minimum_dust_probe) != (2, 2, 2)
        or (minimum_probe, maximum_probe, funding_probe) != (51, 10_200, 20_655)
    ):
        raise RuntimeError("unexpected protocol constants")
    variant = "native" if asset.casefold() == ZERO_ADDRESS else "erc20"
    if variant not in network["variants"]:
        raise RuntimeError("deployment variant is not listed for the selected network")

    domain = json.loads(
        command(
            [
                cast,
                "call",
                deployment,
                "eip712Domain()(bytes1,string,string,uint256,address,bytes32,uint256[])",
                "--json",
                *rpc,
            ]
        )
    )
    if (
        not isinstance(domain, list)
        or len(domain) != 7
        or parse_int(domain[0], "EIP-712 fields") & 0x0F != 0x0F
        or domain[1] != args.protocol_name
        or domain[2] != "1"
        or parse_int(domain[3], "EIP-712 chain ID") != observed_chain_id
        or not same_address(checked_address(domain[4], "EIP-712 verifying contract"), deployment)
        or checked_hash(domain[5], "EIP-712 salt") != "0x" + "0" * 64
        or domain[6] != []
    ):
        raise RuntimeError("EIP-712 domain does not match the requested deployment identity")

    contract_name = "ProofBountyEscrowNative" if variant == "native" else "ProofBountyEscrowERC20"
    artifact_path = ROOT / "out" / f"{contract_name}.sol" / f"{contract_name}.json"
    artifact = json.loads(artifact_path.read_text(encoding="utf-8"))
    creation_code = artifact.get("bytecode", {}).get("object")
    if not isinstance(creation_code, str) or not HEX_DATA.fullmatch(creation_code) or creation_code == "0x":
        raise RuntimeError("local build artifact has invalid creation bytecode")
    if not transaction_input.casefold().startswith(creation_code.casefold()):
        raise RuntimeError("deployment transaction does not start with the exact local creation bytecode")
    constructor_data = "0x" + transaction_input[len(creation_code) :]
    if constructor_data == "0x":
        raise RuntimeError("deployment transaction has no constructor arguments")

    constructor_signature = (
        "f()(string,address,address,address[3])"
        if variant == "native"
        else "f()(string,address,address,address,address[3])"
    )
    decoded = json.loads(command([cast, "abi-decode", constructor_signature, constructor_data, "--json"]))
    expected_decoded: list[object] = (
        [args.protocol_name, dev_co, security_reserve, verifiers]
        if variant == "native"
        else [args.protocol_name, asset, dev_co, security_reserve, verifiers]
    )
    if json.dumps(decoded).casefold() != json.dumps(expected_decoded).casefold():
        raise RuntimeError("constructor arguments do not match the observed immutable configuration")

    def keccak(data: str, label: str) -> str:
        if not HEX_DATA.fullmatch(data):
            raise RuntimeError(f"cannot hash malformed {label}")
        return checked_hash(command([cast, "keccak", data]), label)

    expected_protocol_id = keccak(bytes_hex(b"proof-bounty-escrow/v1"), "expected protocol ID")
    if protocol_id.casefold() != expected_protocol_id.casefold():
        raise RuntimeError("unexpected protocol ID")
    encoded_verifier_set = command(
        [cast, "abi-encode", "f(address[3],uint8)", "[" + ",".join(verifiers) + "]", "2"]
    )
    if verifier_set_hash.casefold() != keccak(encoded_verifier_set, "expected verifier set hash").casefold():
        raise RuntimeError("verifier-set hash does not match the observed verifier addresses")
    protocol_name_hash = keccak(bytes_hex(args.protocol_name.encode("utf-8")), "protocol name hash")
    encoded_deployment_id = command(
        [
            cast,
            "abi-encode",
            "f(bytes32,bytes32,uint256,address,address,address,address,bytes32)",
            protocol_id,
            protocol_name_hash,
            str(observed_chain_id),
            deployment,
            asset,
            dev_co,
            security_reserve,
            verifier_set_hash,
        ]
    )
    if deployment_id.casefold() != keccak(encoded_deployment_id, "expected deployment ID").casefold():
        raise RuntimeError("deployment ID does not match the independently reconstructed value")

    canonical_abi = json.dumps(artifact.get("abi"), sort_keys=True, separators=(",", ":")).encode("utf-8")
    build_record = {
        "contract": contract_name,
        "abiCanonicalization": "utf8-json-sort-keys-no-whitespace-v1",
        "abiHash": keccak(bytes_hex(canonical_abi), "ABI hash"),
        "creationCodeHash": keccak(creation_code, "creation code hash"),
        "constructorArgumentsHash": keccak(constructor_data, "constructor arguments hash"),
    }
    asset_code_hash = None
    if variant == "erc20":
        if parse_int(command([cast, "codesize", asset, *rpc]), "asset code size") == 0:
            raise RuntimeError("ERC-20 asset has no runtime code")
        asset_code_hash = checked_hash(command([cast, "codehash", asset, *rpc]), "asset code hash")

    source: dict[str, object] = {"revision": revision, "worktreeClean": True}
    if args.source_repository:
        source["repository"] = args.source_repository

    deployment_record: dict[str, object] = {
        "networkKey": network["key"],
        "network": network["name"],
        "environment": network["environment"],
        "chainId": observed_chain_id,
        "variant": variant,
        "contractAddress": deployment,
        "deployer": deployer,
        "transactionHash": transaction_hash,
        "transactionInputHash": keccak(transaction_input, "transaction input hash"),
        "blockNumber": block_number,
        "blockHash": block_hash,
        "observedConfirmations": args.confirmations,
        "runtimeCodeHash": runtime_code_hash,
    }
    configuration: dict[str, object] = {
        "protocolName": args.protocol_name,
        "protocolVersion": protocol_version,
        "protocolId": protocol_id,
        "deploymentId": deployment_id,
        "asset": asset,
        "devCo": dev_co,
        "securityReserve": security_reserve,
        "verifiers": verifiers,
        "verifierSetHash": verifier_set_hash,
        "verifierThreshold": threshold,
        "feePolicy": {
            "devCoBps": dev_bps,
            "securityReserveBps": reserve_bps,
            "fixedFeeBps": fixed_bps,
            "minimumRewardUnits": minimum_reward_units,
            "verifierFee": {
                "mode": "sponsor-declared-absolute",
                "minimumBps": minimum_verifier_bps,
                "minimumUnits": minimum_verifier_fee_units,
                "maximumBps": maximum_verifier_bps,
            },
        },
    }
    if asset_code_hash is not None:
        configuration["assetCodeHash"] = asset_code_hash

    manifest = {
        "schemaVersion": 1,
        "kind": "proof-bounty-deployment-observation",
        "status": "unsigned-observation",
        "generatedAt": dt.datetime.now(dt.timezone.utc).isoformat(timespec="seconds").replace("+00:00", "Z"),
        "source": source,
        "toolchain": toolchain,
        "build": build_record,
        "deployment": deployment_record,
        "configuration": configuration,
    }

    output = args.output.resolve()
    try:
        output.relative_to(ROOT.resolve())
    except ValueError as exc:
        raise RuntimeError("--output must remain inside the repository") from exc
    if output.exists() and (not args.overwrite or output.is_symlink()):
        raise RuntimeError("output exists; pass --overwrite for a regular file")
    output.parent.mkdir(parents=True, exist_ok=True)
    temporary = output.with_suffix(output.suffix + ".tmp")
    if temporary.exists() or temporary.is_symlink():
        raise RuntimeError("temporary output path already exists")
    with temporary.open("x", encoding="utf-8") as handle:
        handle.write(json.dumps(manifest, indent=2, sort_keys=True) + "\n")
    temporary.replace(output)
    print(output.relative_to(ROOT).as_posix())
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
