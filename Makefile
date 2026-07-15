SHELL := /bin/bash

FORGE ?= forge
ENV_FILE ?= .env
ACCOUNT ?=
FOUNDRY_VERSION := 1.7.1
FORGE_STD_VERSION := 1.16.2
FORGE_STD_REVISION := bf647bd6046f2f7da30d0c2bf435e5c76a780c1b

.PHONY: bootstrap fmt build lint test test-fuzz test-invariant model mutations mutations-solidity app-check deployment-config check \
	check-repro deploy-native-dry-run deploy-erc20-dry-run deploy-native deploy-erc20 audit-deployment generate-manifest

bootstrap:
	npm ci --ignore-scripts --omit=dev
	npm --prefix app ci --ignore-scripts
	@test -d lib/forge-std || $(FORGE) install foundry-rs/forge-std@$(FORGE_STD_REVISION) --no-git
	@test "$$(node -p "require('./lib/forge-std/package.json').version")" = "$(FORGE_STD_VERSION)"

fmt:
	$(FORGE) fmt --check

build:
	$(FORGE) build --force --sizes

lint:
	$(FORGE) lint contracts script --severity high med --deny warnings

test:
	$(FORGE) test

test-fuzz:
	$(FORGE) test --match-contract ProofBountyEscrowFuzzTest

test-invariant:
	$(FORGE) test --match-contract '^ProofBountyEscrow(ERC20)?InvariantTest$$'

model:
	python3 verification/model/model_check.py

mutations:
	python3 verification/model/mutation_check.py

mutations-solidity:
	python3 verification/solidity_mutation_check.py

app-check:
	npm --prefix app run verify
	npm --prefix app run reproducibility
	npm --prefix app audit --omit=dev

deployment-config:
	jq empty deployments/manifest.schema.json deployments/networks.schema.json deployments/networks.json schemas/*.json
	jq --exit-status '.compiler == "0.8.36" and .evmVersion == "paris" and ([.networks[].chainId] | length) == ([.networks[].chainId] | unique | length) and ([.networks[].key] | length) == ([.networks[].key] | unique | length)' deployments/networks.json >/dev/null

check: fmt build lint test model mutations mutations-solidity app-check deployment-config check-repro

check-repro:
	@set -eu; \
		tmp_first="$$(mktemp)"; \
		tmp_second="$$(mktemp)"; \
		trap 'rm -f "$$tmp_first" "$$tmp_second"' EXIT; \
		$(FORGE) clean; \
		$(FORGE) build >/dev/null; \
		$(FORGE) inspect ProofBountyEscrowNative bytecode >"$$tmp_first"; \
		$(FORGE) inspect ProofBountyEscrowERC20 bytecode >>"$$tmp_first"; \
		$(FORGE) clean; \
		$(FORGE) build >/dev/null; \
		$(FORGE) inspect ProofBountyEscrowNative bytecode >"$$tmp_second"; \
		$(FORGE) inspect ProofBountyEscrowERC20 bytecode >>"$$tmp_second"; \
		cmp "$$tmp_first" "$$tmp_second"

deploy-native-dry-run:
	@set -eu; \
		test -f "$(ENV_FILE)"; \
		set -a; source "$(ENV_FILE)"; set +a; \
		test -n "$${RPC_URL:-}"; \
		$(FORGE) script script/DeployNative.s.sol:DeployNative --rpc-url "$$RPC_URL" -vvvv

deploy-erc20-dry-run:
	@set -eu; \
		test -f "$(ENV_FILE)"; \
		set -a; source "$(ENV_FILE)"; set +a; \
		test -n "$${RPC_URL:-}"; \
		$(FORGE) script script/DeployERC20.s.sol:DeployERC20 --rpc-url "$$RPC_URL" -vvvv

deploy-native:
	@set -eu; \
		test -n "$(ACCOUNT)"; \
		test -f "$(ENV_FILE)"; \
		set -a; source "$(ENV_FILE)"; set +a; \
		test -n "$${RPC_URL:-}"; \
		$(FORGE) script script/DeployNative.s.sol:DeployNative --rpc-url "$$RPC_URL" \
			--account "$(ACCOUNT)" --broadcast --slow -vvvv

deploy-erc20:
	@set -eu; \
		test -n "$(ACCOUNT)"; \
		test -f "$(ENV_FILE)"; \
		set -a; source "$(ENV_FILE)"; set +a; \
		test -n "$${RPC_URL:-}"; \
		$(FORGE) script script/DeployERC20.s.sol:DeployERC20 --rpc-url "$$RPC_URL" \
			--account "$(ACCOUNT)" --broadcast --slow -vvvv

audit-deployment:
	@set -eu; \
		test -f "$(ENV_FILE)"; \
		set -a; source "$(ENV_FILE)"; set +a; \
		test -n "$${RPC_URL:-}"; \
		$(FORGE) script script/AuditDeployment.s.sol:AuditDeployment --rpc-url "$$RPC_URL" -vvvv

generate-manifest:
	@set -eu; \
		test -f "$(ENV_FILE)"; \
		set -a; source "$(ENV_FILE)"; set +a; \
		test -n "$${RPC_URL:-}"; \
		test -n "$${NETWORK_KEY:-}"; \
		test -n "$${DEPLOYMENT:-}"; \
		test -n "$${DEPLOYMENT_TX_HASH:-}"; \
		test -n "$${PROTOCOL_NAME:-}"; \
		test -n "$${EXPECTED_RUNTIME_CODE_HASH:-}"; \
		test -n "$${MANIFEST_OUTPUT:-}"; \
		args=(python3 scripts/generate_deployment_manifest.py \
			--network-key "$$NETWORK_KEY" --rpc-url "$$RPC_URL" \
			--deployment "$$DEPLOYMENT" --transaction-hash "$$DEPLOYMENT_TX_HASH" \
			--protocol-name "$$PROTOCOL_NAME" --expected-runtime-code-hash "$$EXPECTED_RUNTIME_CODE_HASH" \
			--confirmations "$${CONFIRMATIONS:-1}" \
			--output "$$MANIFEST_OUTPUT"); \
		if test -n "$${SOURCE_REPOSITORY:-}"; then args+=(--source-repository "$$SOURCE_REPOSITORY"); fi; \
		"$${args[@]}"
