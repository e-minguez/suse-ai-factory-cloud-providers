# SUSE AI Factory: cloud providers
#
# Terraform/OpenTofu targets walk TF_DIRS; shell lint only sees files git would track.

SHELL := /bin/bash
.DEFAULT_GOAL := help

# Terraform or OpenTofu: TF_BIN (or `make TF=tofu`), else terraform when installed, else tofu.
TF ?= $(or $(TF_BIN),$(if $(shell command -v terraform 2>/dev/null),terraform,tofu))

TF_DIRS := modules examples tools/multicluster
# modules/common only holds the variable file symlinked into each provider module.
LINT_TF_DIRS := $(filter-out modules/common/,$(wildcard modules/*/)) examples tools/multicluster
# Example roots to validate; CI overrides this with one provider per job.
EXAMPLES ?= $(wildcard examples/*/)
# Other Terraform roots to validate; CI runs them in their own job.
TOOL_ROOTS ?= tools/multicluster/register

.PHONY: help tofu-tests-gen tofu-tests-check docs docs-check fmt fmt-check validate lint lint-tf lint-sh test test-tf test-catalog test-scripts test-go test-webui webui image cost cost-fixtures check-consistency ci clean

help: ## Show this help
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  %-18s %s\n", $$1, $$2}'

fmt: ## Reformat all Terraform files (modules/, examples/, tools/multicluster/)
	@for d in $(TF_DIRS); do \
		[ -d "$$d" ] || continue; \
		$(TF) fmt -recursive "$$d"; \
	done

fmt-check: ## Check Terraform formatting without writing changes
	@status=0; \
	for d in $(TF_DIRS); do \
		[ -d "$$d" ] || continue; \
		$(TF) fmt -recursive -check -diff "$$d" || status=1; \
	done; \
	exit $$status

validate: ## init -backend=false + validate for every examples/<provider> and tools root (EXAMPLES=, TOOL_ROOTS= to narrow)
	@status=0; \
	for d in $(EXAMPLES) $(TOOL_ROOTS); do \
		d="$${d%/}"; \
		[ -f "$$d/main.tf" ] || continue; \
		echo "==> validate $$d"; \
		( cd "$$d" && $(TF) init -backend=false -input=false >/dev/null && $(TF) validate ) || status=1; \
		rm -rf "$$d/.terraform" "$$d/.terraform.lock.hcl"; \
	done; \
	exit $$status

lint: lint-tf lint-sh ## tflint + shellcheck

lint-tf: ## tflint (skipped if not installed) on modules/, examples/, tools/multicluster/
	@if ! command -v tflint >/dev/null 2>&1; then echo "lint-tf: tflint not installed, skipping"; exit 0; fi; \
	status=0; \
	for d in $(LINT_TF_DIRS); do \
		[ -d "$$d" ] || continue; \
		echo "==> tflint $$d"; \
		( cd "$$d" && tflint --recursive ) || status=1; \
	done; \
	exit $$status

lint-sh: ## shellcheck (skipped if not installed) on every tracked *.sh
	@if ! command -v shellcheck >/dev/null 2>&1; then echo "lint-sh: shellcheck not installed, skipping"; exit 0; fi; \
	files=$$(git ls-files --cached --others --exclude-standard -- '*.sh'); \
	if [ -z "$$files" ]; then echo "lint-sh: no shell scripts"; exit 0; fi; \
	shellcheck $$files

test: test-tf test-catalog test-scripts test-go test-webui ## Run terraform, script and Go tests

test-scripts: ## Script tests (fake terraform, tofu and ssh) and poll.sh self-test
	bash scripts/tests/tfbin_test.sh
	bash scripts/tests/tofu_tests_test.sh
	bash scripts/tests/scripts_test.sh
	FAKE_TF_NAME=tofu bash scripts/tests/scripts_test.sh
	bash scripts/tests/deploy_test.sh
	FAKE_TF_NAME=tofu bash scripts/tests/deploy_test.sh
	bash scripts/tests/vultr_deploy_test.sh
	bash scripts/tests/evroc_deploy_test.sh
	bash scripts/tests/exoscale_deploy_test.sh
	bash scripts/tests/exoscale_api_test.sh
	bash scripts/tests/build_access_test.sh
	bash scripts/tests/multicluster_test.sh
	bash scripts/tests/check_and_reserve_test.sh
	bash scripts/tests/leftovers_aws_test.sh
	bash scripts/tests/leftovers_evroc_test.sh
	bash scripts/tests/leftovers_exoscale_test.sh
	bash scripts/tests/leftovers_vultr_test.sh
	@if [ -x /bin/bash ]; then \
		for t in aws evroc exoscale vultr; do /bin/bash scripts/tests/leftovers_$${t}_test.sh || exit 1; done; \
	fi
	bash scripts/lib/poll_test.sh
	[ ! -x /bin/bash ] || /bin/bash scripts/lib/poll_test.sh

test-go: ## gofmt, go vet and go test in tools/cost (skipped if go is not installed)
	@if ! command -v go >/dev/null 2>&1; then echo "test-go: go not installed, skipping"; exit 0; fi; \
	cd tools/cost && \
	unformatted=$$(gofmt -l .) && \
	if [ -n "$$unformatted" ]; then echo "gofmt needed:" >&2; echo "$$unformatted" >&2; exit 1; fi && \
	go vet ./... && go test ./...

test-webui: ## gofmt, go vet and go test in tools/webui (skipped if go is not installed)
	@if ! command -v go >/dev/null 2>&1; then echo "test-webui: go not installed, skipping"; exit 0; fi; \
	[ -f tools/webui/go.mod ] || { echo "test-webui: tools/webui has no go.mod yet, skipping"; exit 0; }; \
	cd tools/webui && \
	unformatted=$$(gofmt -l .) && \
	if [ -n "$$unformatted" ]; then echo "gofmt needed:" >&2; echo "$$unformatted" >&2; exit 1; fi && \
	go vet ./... && go test ./...

webui: ## Build the web UI binary to tools/webui/webui (CGO disabled)
	cd tools/webui && CGO_ENABLED=0 go build -trimpath -ldflags="-s -w" -o webui .

WEBUI_VERSION := $(shell cat tools/webui/VERSION)

image: ## Build the web UI container image (suse-ai-factory-cloud-providers:<tools/webui/VERSION> and :dev)
	docker buildx build --load -f tools/webui/Dockerfile --build-arg VERSION=$(WEBUI_VERSION) \
		-t suse-ai-factory-cloud-providers:$(WEBUI_VERSION) -t suse-ai-factory-cloud-providers:dev .

cost: ## Estimate cost from tfvars: make cost PROVIDER=<aws|evroc|exoscale|vultr> TFVARS="common-all.tfvars terraform.tfvars"
	@[ -n "$(PROVIDER)" ] || { echo "cost: set PROVIDER=aws|evroc|exoscale|vultr (and TFVARS=\"f1 f2\", later wins)" >&2; exit 1; }
	cd tools/cost && go run . --provider $(PROVIDER) $(foreach f,$(TFVARS),--var-file $(abspath $(f)))

cost-fixtures: ## Run the live-tagged cost tests (network, optional credentials)
	cd tools/cost && go test -tags live ./...

test-tf: ## terraform test (tofu test with TF=tofu; it reads the generated *.tofutest.hcl) in every module and tools root that has a tests/ directory
	@dirs=$$( { find modules -mindepth 2 -maxdepth 2 -type d -name tests; find tools -mindepth 3 -maxdepth 3 -type d -name tests; } 2>/dev/null); \
	if [ -z "$$dirs" ]; then echo "test: no modules with a tests/ directory yet"; exit 0; fi; \
	status=0; \
	for t in $$dirs; do \
		mod=$$(dirname "$$t"); \
		echo "==> terraform test $$mod"; \
		( cd "$$mod" && $(TF) init -backend=false -input=false >/dev/null && $(TF) test ) || status=1; \
		rm -rf "$$mod/.terraform" "$$mod/.terraform.lock.hcl"; \
	done; \
	exit $$status

test-catalog: ## Plan examples/<provider> with each catalog/*/<provider>/*.tfvars.example (mocked, tests/catalog.tftest.hcl)
# Runs in a copy at the same depth (examples/.catalog-<provider>), so a local
# terraform.tfvars, *.auto.tfvars* or state in examples/<provider> does not leak in.
	@status=0; \
	for ex in examples/*/; do \
		ex="$${ex%/}"; p="$${ex#examples/}"; \
		[ -f "$$ex/tests/catalog.tftest.hcl" ] || continue; \
		files=$$(ls catalog/*/"$$p"/*.tfvars.example 2>/dev/null); \
		[ -n "$$files" ] || continue; \
		w="examples/.catalog-$$p"; rm -rf "$$w"; mkdir -p "$$w/tests"; \
		cp "$$ex"/*.tf "$$w"/; cp "$$ex/tests/catalog.tftest.hcl" "$$w/tests/"; \
		if ( cd "$$w" && terraform init -backend=false -input=false >/dev/null ); then \
			for f in $$files; do \
				echo "==> catalog $$f"; \
				( cd "$$w" && terraform test -var-file="$(CURDIR)/$$f" ) || status=1; \
			done; \
		else status=1; fi; \
		rm -rf "$$w"; \
	done; \
	exit $$status

tofu-tests-gen: ## Regenerate the OpenTofu test variants (tests/*.tofutest.hcl) from the Terraform suites (needs tofu, jq, gawk)
	TF_BIN=tofu bash scripts/tests/tofu-tests.sh --write

tofu-tests-check: ## Fail if a tests/*.tofutest.hcl is missing or out of date
	TF_BIN=tofu bash scripts/tests/tofu-tests.sh --check

docs: ## Regenerate the inputs/outputs tables in modules/*/README.md (needs terraform-docs)
	@command -v terraform-docs >/dev/null 2>&1 || { echo "docs: terraform-docs not installed (brew install terraform-docs; see https://terraform-docs.io/user-guide/installation/)" >&2; exit 1; }
	@for d in modules/*/; do \
		[ -f "$$d/README.md" ] || continue; \
		terraform-docs --config "$(CURDIR)/.terraform-docs.yml" "$$d" >/dev/null || exit 1; \
	done

docs-check: ## Fail if the generated docs in modules/*/README.md are out of date
	@command -v terraform-docs >/dev/null 2>&1 || { echo "docs-check: terraform-docs not installed" >&2; exit 1; }
	@status=0; \
	for d in modules/*/; do \
		[ -f "$$d/README.md" ] || continue; \
		terraform-docs --config "$(CURDIR)/.terraform-docs.yml" --output-check "$$d" >/dev/null || { echo "docs-check: $$d/README.md is out of date; run make docs" >&2; status=1; }; \
	done; \
	exit $$status

check-consistency: ## Check variables-common.tf symlinks, example variable parity, output set and managed labels
	./scripts/check-consistency.sh

ci: fmt-check validate check-consistency docs-check lint test ## Run the full local CI sequence

clean: ## Remove local Terraform working directories and deploy logs
	find $(TF_DIRS) -type d \( -name .terraform -o -name .deploy \) -prune -exec rm -rf {} + 2>/dev/null || true
	find $(TF_DIRS) -name crash.log -delete 2>/dev/null || true
	rm -rf .deploy
