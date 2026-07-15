SHELL := /bin/bash

FORGE ?= forge
ENV_FILE ?= .env
ACCOUNT ?=
FOUNDRY_VERSION := 1.7.1
FORGE_STD_VERSION := 1.16.2
FORGE_STD_REVISION := bf647bd6046f2f7da30d0c2bf435e5c76a780c1b

.PHONY: bootstrap fmt build lint test test-fuzz test-invariant model mutations mutations-solidity app-check release-gate deployment-config check \
	check-repro deploy-native-plan deploy-erc20-plan deploy-native-dry-run deploy-erc20-dry-run deploy-native deploy-erc20 audit-deployment generate-manifest

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

release-gate:
	python3 -m unittest discover -s scripts/tests -p 'test_*.py'
	python3 scripts/check_workflow_pins.py
	python3 scripts/validate_json_schemas.py

deployment-config: release-gate
	python3 -m unittest scripts/test_generate_deployment_manifest.py
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

deploy-native-plan:
	@python3 scripts/deploy_from_env.py --env-file "$(ENV_FILE)" --forge "$(FORGE)" deploy --variant native

deploy-erc20-plan:
	@python3 scripts/deploy_from_env.py --env-file "$(ENV_FILE)" --forge "$(FORGE)" deploy --variant erc20

deploy-native-dry-run:
	@python3 scripts/deploy_from_env.py --env-file "$(ENV_FILE)" --forge "$(FORGE)" deploy --variant native --simulate

deploy-erc20-dry-run:
	@python3 scripts/deploy_from_env.py --env-file "$(ENV_FILE)" --forge "$(FORGE)" deploy --variant erc20 --simulate

deploy-native:
	@python3 scripts/deploy_from_env.py --env-file "$(ENV_FILE)" --forge "$(FORGE)" deploy --variant native --execute --account "$(ACCOUNT)"

deploy-erc20:
	@python3 scripts/deploy_from_env.py --env-file "$(ENV_FILE)" --forge "$(FORGE)" deploy --variant erc20 --execute --account "$(ACCOUNT)"

audit-deployment:
	@python3 scripts/deploy_from_env.py --env-file "$(ENV_FILE)" --forge "$(FORGE)" audit

generate-manifest:
	@python3 scripts/deploy_from_env.py --env-file "$(ENV_FILE)" --forge "$(FORGE)" manifest
