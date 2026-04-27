SHELL := /usr/bin/env bash
.SHELLFLAGS := -Eeuo pipefail -c
.ONESHELL:

REPO ?= tech-sumit/android-oem-pipeline
PROFILES ?= galaxy-s26-ultra-intel-gpu,galaxy-s26-ultra-apple-silicon
REPO_SYNC_JOBS ?= 1
TMUX_SESSION ?= mayaos-build
REMOTE_LOG ?= /workspace/aosp-logs/mayaos-build.log
REMOTE_OUT ?= /workspace/aosp-out

.PHONY: help doctor validate status secrets \
	docker-build docker-run \
	vast-search vast-provision vast-auto-provision vast-sync \
	vast-build vast-build-direct vast-build-tmux vast-orchestrate \
	vast-watch vast-logs vast-tail vast-tmux-ls vast-remote-status \
	vast-fetch vast-fetch-latest vast-stop vast-destroy vast-clean-local \
	gh-secrets-list gh-secrets-check r2-check

help: ## Show project commands
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | \
		awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-22s\033[0m %s\n", $$1, $$2}'

doctor: ## Check local tools and Vast.ai auth state
	@command -v docker >/dev/null || { echo "missing: docker"; exit 1; }
	@command -v vastai >/dev/null || { echo "missing: vastai"; exit 1; }
	@command -v rsync >/dev/null || { echo "missing: rsync"; exit 1; }
	@command -v gh >/dev/null || { echo "missing: gh"; exit 1; }
	@./vast/search.sh >/dev/null
	@echo "ok: docker, vastai, rsync, gh, and Vast.ai auth are ready"

validate: ## Run local syntax, XML, and MayaOS profile checks
	@bash -n vast/*.sh pipeline/*.sh pipeline/hooks/*.sh scripts/*.sh \
		device-tree/mayaos/galaxy-s26-ultra/vendor/bin/mayaos-command-exec
	@python3 -c 'import sys, xml.etree.ElementTree as ET; from pathlib import Path; ET.parse("manifests/mayaos.xml"); ET.parse("device-tree/mayaos/galaxy-s26-ultra/sku/galaxy-s26-ultra-features.xml"); y=Path("mayaos.yaml").read_text(); x=Path("device-tree/mayaos/galaxy-s26-ultra/mayaos_cf_s26ultra.mk").read_text(); a=Path("device-tree/mayaos/galaxy-s26-ultra/mayaos_cf_s26ultra_arm64.mk").read_text(); p=Path("device-tree/mayaos/galaxy-s26-ultra/AndroidProducts.mk").read_text(); checks=[("intel profile","id: galaxy-s26-ultra-intel-gpu",y),("apple profile","id: galaxy-s26-ultra-apple-silicon",y),("x86 lunch yaml","lunch_target: mayaos_cf_s26ultra-trunk_staging-userdebug",y),("arm lunch yaml","lunch_target: mayaos_cf_s26ultra_arm64-trunk_staging-userdebug",y),("x86 lunch ap","mayaos_cf_s26ultra-trunk_staging-userdebug",p),("arm lunch ap","mayaos_cf_s26ultra_arm64-trunk_staging-userdebug",p),("x86 model","PRODUCT_MODEL        := SM-S948B",x),("arm model","PRODUCT_MODEL        := SM-S948B",a),("x86 command runner","vendor/bin/mayaos-command-exec:vendor/bin/mayaos-command-exec",x),("arm command runner","vendor/bin/mayaos-command-exec:vendor/bin/mayaos-command-exec",a)]; failed=[name for name,needle,hay in checks if needle not in hay]; (sys.exit("failed checks: "+", ".join(failed)) if failed else print("ok: MayaOS multi-target checks passed"))'

status: ## Show local git state and active Vast instance
	@git status --short
	@echo
	@echo "Vast instances:"
	@vastai show instances --raw | python3 -c 'import json,sys; data=json.load(sys.stdin); [print("{}: {} {}".format(i.get("id") or i.get("contract_id"), i.get("label"), i.get("actual_status"))) for i in data]' || true

secrets: gh-secrets-check ## Check required GitHub secrets

docker-build: ## Build the local AOSP builder container
	docker compose -f docker/docker-compose.yml build builder

docker-run: ## Run the local containerized build path
	docker compose -f docker/docker-compose.yml run --rm builder

vast-search: ## List matching Vast.ai build offers
	./vast/search.sh

vast-provision: ## Rent a Vast.ai instance from OFFER=<id>
	@test -n "$(OFFER)" || { echo "usage: make vast-provision OFFER=<offer_id>"; exit 1; }
	./vast/provision.sh "$(OFFER)"

vast-auto-provision: ## Rent the cheapest matching Vast.ai offer
	@offer="$$(./vast/search.sh | awk 'NR>2 && $$1 ~ /^[0-9]+$$/ {print $$1; exit}')"; \
		test -n "$$offer" || { echo "no matching Vast offer found"; exit 1; }; \
		echo "Selected offer: $$offer"; \
		./vast/provision.sh "$$offer"

vast-sync: ## Sync this repo to the active Vast.ai instance
	./vast/sync-source.sh

vast-build: ## Build via remote Docker on Vast.ai
	./vast/kick-build.sh

vast-build-direct: ## Build directly inside the Vast.ai container
	PROFILES="$(PROFILES)" REPO_SYNC_JOBS="$(REPO_SYNC_JOBS)" ./vast/kick-direct-build.sh

vast-build-tmux: ## Start detached tmux build on active Vast.ai instance
	PROFILES="$(PROFILES)" REPO_SYNC_JOBS="$(REPO_SYNC_JOBS)" TMUX_SESSION="$(TMUX_SESSION)" ./vast/start-tmux-build.sh

vast-orchestrate: doctor validate vast-auto-provision vast-build-tmux ## Provision one instance and start detached tmux build

vast-watch: ## Attach to the remote tmux build session
	TMUX_SESSION="$(TMUX_SESSION)" ./vast/tmux-watch.sh

vast-logs: ## Print recent remote build log lines
	./vast/ssh.sh 'tail -200 "$(REMOTE_LOG)" 2>/dev/null || true'

vast-tail: ## Follow remote build log without attaching tmux
	./vast/ssh.sh 'tail -f "$(REMOTE_LOG)"'

vast-tmux-ls: ## List remote tmux sessions/windows
	./vast/ssh.sh 'tmux ls; tmux list-windows -t "$(TMUX_SESSION)" 2>/dev/null || true'

vast-remote-status: ## Show remote build capacity, tmux, disk, and logs
	./vast/ssh.sh 'tmux ls 2>/dev/null || true; echo; tail -80 "$(REMOTE_LOG)" 2>/dev/null || true; echo; nproc --all; free -h | sed -n "1,2p"; df -h /workspace'

vast-fetch: ## Fetch build artifacts from the active Vast.ai instance
	REMOTE_OUT="$(REMOTE_OUT)" ./vast/fetch-artifacts.sh

vast-fetch-latest: ## Fetch artifacts into ./out/latest
	LOCAL_OUT_DIR="$$(pwd)/out/latest" REMOTE_OUT="$(REMOTE_OUT)" ./vast/fetch-artifacts.sh

vast-stop: ## Stop active Vast.ai instance, keeping disk
	./vast/destroy.sh --stop

vast-destroy: ## Destroy the active Vast.ai instance
	./vast/destroy.sh --destroy

vast-clean-local: ## Remove local Vast instance pointer only
	rm -f vast/.instance_id

gh-secrets-list: ## List GitHub Actions secret names
	gh secret list --repo "$(REPO)"

gh-secrets-check: ## Verify required GitHub Actions secrets exist
	@required="VAST_API_KEY VAST_SSH_PRIVATE_KEY VAST_SSH_PUBLIC_KEY R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET"; \
	existing="$$(gh secret list --repo "$(REPO)" | awk '{print $$1}')"; \
	missing=0; \
	for key in $$required; do \
		if ! grep -qx "$$key" <<<"$$existing"; then \
			echo "missing: $$key"; \
			missing=1; \
		fi; \
	done; \
	test "$$missing" = 0 && echo "ok: required GitHub secrets are set"

r2-check: ## Show configured R2 bucket/prefix and expected secrets
	@awk '/^  r2:/{in_r2=1; next} in_r2 && /^  [^ ]/{exit} in_r2 && NF{sub(/^ +/,""); print}' mayaos.yaml
	@echo 'required secrets: R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET'
