SHELL := /usr/bin/env bash
.SHELLFLAGS := -Eeuo pipefail -c
.ONESHELL:

REPO ?= tech-sumit/android-oem-pipeline
PROFILES ?= galaxy-s26-ultra-intel-gpu,galaxy-s26-ultra-apple-silicon
# Google's repo tool recommends -j8 for AOSP. -j1 is a ~40 hour wall time on
# the 1013-project Android 16 manifest; -j8 brings it down to ~1-2 hours and
# still stays well under Gerrit's per-IP throttling threshold.
REPO_SYNC_JOBS ?= 8
TMUX_SESSION ?= mayaos-build
REMOTE_LOG ?= /workspace/aosp-logs/mayaos-build.log
REMOTE_OUT ?= /workspace/aosp-out

.PHONY: help doctor validate status secrets mdf-ca-generate mdf-ca-vault \
	mdf-submodule-add mdf-submodule-update mdf-build mdf-dev-up mdf-dev-down \
	mdf-fleet-up mdf-fleet-down mdf-logs mdf-shell mdf-status \
	mdf-perf-baseline mdf-snapshot mdf-restore \
	mdf-ota-append mdf-ota-promote \
	mdf-provision mdf-destroy mdf-rotate-ca mdf-cloudflared-up mdf-cloudflared-down \
	mdf-tf-init mdf-tf-plan mdf-tf-apply \
	mdf-observability-lint mdf-observability-push mdf-observability-push-dashboards \
	mdf-observability-push-alerts \
	mdf-ha-setup mdf-ha-drill \
	docker-build docker-run \
	vast-search vast-provision vast-auto-provision vast-sync \
	vast-build vast-build-direct vast-build-tmux vast-orchestrate \
	vast-watch vast-logs vast-tail vast-tmux-ls vast-remote-status \
	vast-fetch vast-fetch-latest vast-stop vast-destroy vast-clean-local \
	runpod-doctor runpod-search-cpu runpod-search-gpu runpod-provision \
	runpod-sync runpod-build runpod-orchestrate runpod-status \
	runpod-watch runpod-logs runpod-tail runpod-tmux-ls \
	runpod-fetch runpod-fetch-latest runpod-stop runpod-start \
	runpod-destroy runpod-clean-local \
	r2-fetch r2-fetch-latest \
	cuttlefish-up cuttlefish-down cuttlefish-logs cuttlefish-shell \
	cuttlefish-adb cuttlefish-scrcpy cuttlefish-status \
	qemu-up qemu-down qemu-adb qemu-scrcpy \
	emulator-up emulator-down emulator-adb emulator-scrcpy \
	runpod-build-emulator runpod-emulator-fetch runpod-emulator-watch \
	runpod-emulator-build-direct \
	stock-avd-create stock-emu-up stock-emu-wait stock-scrcpy stock-emu-down \
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
	@bash -n vast/*.sh runpod/*.sh pipeline/*.sh pipeline/hooks/*.sh scripts/*.sh \
		aosp-tree/vendor/mayaos/bin/mayaos-command-exec
	@python3 scripts/validate-mayaos.py

status: ## Show local git state and active Vast instance
	@git status --short
	@echo
	@echo "Vast instances:"
	@vastai show instances --raw | python3 -c 'import json,sys; data=json.load(sys.stdin); [print("{}: {} {}".format(i.get("id") or i.get("contract_id"), i.get("label"), i.get("actual_status"))) for i in data]' || true

secrets: gh-secrets-check ## Check required GitHub secrets

mdf-ca-generate: ## Generate the MayaOS Device Farm root CA (10-year RSA-4096) and stage into vendor/mayaos/
	@./scripts/gen-mdf-root-ca.sh

mdf-ca-vault: ## Print the Vault command to push the generated MDF CA private key
	@./scripts/gen-mdf-root-ca.sh --vault-only

mdf-submodule-add: ## One-time: add DeviceFarmer/stf as the command-center/stf submodule
	@if [ -d command-center/stf/.git ] || [ -f command-center/stf/.git ]; then \
		echo "==> command-center/stf already a submodule; skipping"; \
	else \
		git submodule add -b master https://github.com/DeviceFarmer/stf command-center/stf; \
	fi

mdf-submodule-update: ## Sync command-center/stf to the pin recorded in stf-version
	@PIN=$$(awk -F= '$$1=="sha"{print $$2}' command-center/stf-version | tr -d '[:space:]'); \
	echo "==> checking out STF @ $$PIN"; \
	git -C command-center/stf fetch --all --tags; \
	git -C command-center/stf checkout "$$PIN"

mdf-build: ## Build the unified MDF container image (mdf:dev)
	@cd command-center && docker compose -f docker-compose.yml build

mdf-dev-up: ## Phase 4 single-instance dev stack (rethinkdb + stf + 1 emulator)
	@cd command-center && docker compose -f docker-compose.yml up -d
	@echo "==> open http://localhost:8080 -- you should see one device after ~60s"

mdf-dev-down: ## Stop the dev stack
	@cd command-center && docker compose -f docker-compose.yml down

mdf-fleet-up: ## Production fleet stack (Cloudflare Tunnel + RethinkDB cluster)
	@cd command-center && docker compose -f docker-compose.fleet.yml up -d

mdf-fleet-down: ## Stop the production fleet stack
	@cd command-center && docker compose -f docker-compose.fleet.yml down

mdf-logs: ## Tail MDF container logs (SVC=mdf|rethink-1|mdf-tunnel)
	@cd command-center && docker compose -f docker-compose.yml logs -f $(SVC)

mdf-shell: ## Open a shell inside the running MDF container
	@cd command-center && docker compose -f docker-compose.yml exec mdf /bin/bash

mdf-status: ## Show fleet status across all provisioned pods
	@bash mdf/scripts/mdf-status.sh

mdf-pod-status: ## Show in-pod supervisord status (run from a single pod)
	@cd command-center && docker compose -f docker-compose.yml exec mdf supervisorctl status

mdf-perf-baseline: ## Phase 4.5: collect docs/perf-baseline-rev5.1.md numbers
	@cd command-center && bash perf/run-baseline.sh

mdf-perf-density: ## Phase 7: ramp 10 -> 100 -> 250 instances + record TSV
	@cd command-center && bash perf/density-test.sh

mdf-perf-parallel-boot: ## Helper: parallel-boot N=100 BATCH=10 instances; print boot p99
	@cd command-center && N=$(or $(N),100) BATCH=$(or $(BATCH),10) bash perf/parallel-boot.sh

mdf-snapshot: ## Snapshot the running mdf-pod-0-001 instance to "warm" QMP slot
	@cd command-center && docker compose -f docker-compose.yml exec mdf \
		curl -s -XPOST http://127.0.0.1:7180/mdf/warmpool/snapshot \
		-H 'Content-Type: application/json' \
		-d '{"serial":"emulator-5554","name":"warm"}'

mdf-restore: ## Restore mdf-pod-0-001 from "warm" snapshot
	@cd command-center && docker compose -f docker-compose.yml exec mdf \
		curl -s -XPOST http://127.0.0.1:7180/mdf/warmpool/restore \
		-H 'Content-Type: application/json' \
		-d '{"serial":"emulator-5554","name":"warm"}'

mdf-ota-append: ## Append a build to a channel: CHANNEL=canary BUILD_ID=16-r6-rc1 ARTIFACT_DIR=...
	@if [ -z "$(CHANNEL)" ] || [ -z "$(BUILD_ID)" ] || [ -z "$(ARTIFACT_DIR)" ]; then \
		echo "usage: make mdf-ota-append CHANNEL=canary BUILD_ID=16-r6-rc1 ARTIFACT_DIR=out/..."; exit 1; \
	fi
	python3 ota/tools/append.py --channel $(CHANNEL) --build-id $(BUILD_ID) \
		--profile $(or $(PROFILE),galaxy-s26-ultra-emulator-x86) \
		--artifact-dir $(ARTIFACT_DIR) --notes "$(NOTES)"

mdf-ota-promote: ## Promote a build between channels: SRC=canary DST=stable BUILD=16-r6-rc1
	@if [ -z "$(SRC)" ] || [ -z "$(DST)" ] || [ -z "$(BUILD)" ]; then \
		echo "usage: make mdf-ota-promote SRC=canary DST=stable BUILD=16-r6-rc1"; exit 1; \
	fi
	python3 ota/tools/promote.py --from $(SRC) --to $(DST) --build $(BUILD)

# ---- Phase 8: provisioning + edge ----------------------------------------
mdf-tf-init: ## terraform init for the MDF infra
	cd mdf/terraform && terraform init -upgrade

mdf-tf-plan: ## terraform plan for the MDF infra
	cd mdf/terraform && terraform plan

mdf-tf-apply: ## terraform apply for the MDF infra
	cd mdf/terraform && terraform apply

mdf-provision: ## End-to-end fleet provisioning (terraform + sync + compose up)
	@bash mdf/scripts/mdf-provision.sh

mdf-destroy: ## Snapshot RethinkDB, compose down, terraform destroy
	@bash mdf/scripts/mdf-destroy.sh

mdf-rotate-ca: ## Generate a fresh MDF root CA (deprecation window 90d)
	@bash mdf/scripts/mdf-rotate-ca.sh

mdf-cloudflared-up: ## Bring up a local cloudflared (TUNNEL_TOKEN=...)
	@ACTION=up bash mdf/scripts/mdf-cloudflared.sh

mdf-cloudflared-down: ## Stop the local cloudflared
	@ACTION=down bash mdf/scripts/mdf-cloudflared.sh

# ---- Phase 9: observability ----------------------------------------------
mdf-observability-lint: ## Lint dashboards + alerts
	@bash observability/scripts/lint-dashboards.sh
	@for f in observability/alerts/*.yml; do yq -e '.groups[0].rules[0].alert' "$$f" > /dev/null || exit 1; done
	@echo "ok: observability lint clean"

mdf-observability-push-dashboards: ## Push dashboards to Grafana Cloud
	@bash observability/scripts/push-dashboards.sh

mdf-observability-push-alerts: ## Push alert rules to Grafana Cloud Mimir
	@bash observability/scripts/push-alerts.sh

mdf-observability-push: mdf-observability-lint mdf-observability-push-dashboards mdf-observability-push-alerts ## Lint + push everything

# ---- Phase 10: HA --------------------------------------------------------
mdf-ha-setup: ## Bring up 2-pod HA fleet: POD0_HOST=mdf-pod-eu-de-0 POD1_HOST=mdf-pod-eu-de-1
	@if [ -z "$(POD0_HOST)" ] || [ -z "$(POD1_HOST)" ]; then \
		echo "usage: make mdf-ha-setup POD0_HOST=mdf-pod-eu-de-0 POD1_HOST=mdf-pod-eu-de-1"; exit 1; \
	fi
	@POD0_HOST=$(POD0_HOST) POD1_HOST=$(POD1_HOST) bash mdf/scripts/mdf-ha-setup.sh

mdf-ha-drill: ## Run a one-shot HA failover drill: POD0_HOST=... POD1_HOST=...
	@if [ -z "$(POD0_HOST)" ] || [ -z "$(POD1_HOST)" ]; then \
		echo "usage: make mdf-ha-drill POD0_HOST=mdf-pod-eu-de-0 POD1_HOST=mdf-pod-eu-de-1"; exit 1; \
	fi
	@POD0_HOST=$(POD0_HOST) POD1_HOST=$(POD1_HOST) bash mdf/scripts/mdf-failover-drill.sh

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

# ---------------------------------------------------------------------------
# RunPod backend - second-source compute. Same pipeline/ runs here; only the
# lifecycle scripts differ. See runpod/README.md for the full env reference.
# ---------------------------------------------------------------------------

runpod-doctor: ## Check local tools and RunPod auth state
	@command -v curl >/dev/null || { echo "missing: curl"; exit 1; }
	@command -v jq >/dev/null || { echo "missing: jq"; exit 1; }
	@command -v rsync >/dev/null || { echo "missing: rsync"; exit 1; }
	@./runpod/common.sh 2>/dev/null || true
	@bash -c 'source runpod/common.sh && ensure_runpod_auth && echo "ok: curl, jq, rsync, and RunPod auth are ready"'

runpod-search-cpu: ## List the cheapest SECURE CPU flavors
	./runpod/search.sh cpu

runpod-search-gpu: ## List the cheapest SECURE GPU types
	./runpod/search.sh gpu

runpod-provision: ## Rent a RunPod pod (defaults to SECURE CPU 32 vCPU + 1 TB volume)
	./runpod/provision.sh

runpod-sync: ## Sync this repo to the active RunPod pod
	./runpod/sync-source.sh

runpod-build: ## Start detached tmux build on active RunPod pod
	PROFILES="$(PROFILES)" REPO_SYNC_JOBS="$(REPO_SYNC_JOBS)" TMUX_SESSION="$(TMUX_SESSION)" ./runpod/start-tmux-build.sh

runpod-orchestrate: doctor validate runpod-provision runpod-build ## Provision a pod and start detached tmux build

runpod-status: ## Show pod info, tmux state, and last build log lines
	./runpod/status.sh

runpod-watch: ## Attach to the remote tmux build session
	TMUX_SESSION="$(TMUX_SESSION)" ./runpod/tmux-watch.sh

runpod-logs: ## Print recent remote build log lines
	./runpod/ssh.sh 'tail -200 "$(REMOTE_LOG)" 2>/dev/null || true'

runpod-tail: ## Follow remote build log without attaching tmux
	./runpod/ssh.sh 'tail -f "$(REMOTE_LOG)"'

runpod-tmux-ls: ## List remote tmux sessions/windows
	./runpod/ssh.sh 'tmux ls; tmux list-windows -t "$(TMUX_SESSION)" 2>/dev/null || true'

runpod-fetch: ## Fetch build artifacts from the active RunPod pod
	REMOTE_OUT="$(REMOTE_OUT)" ./runpod/fetch-artifacts.sh

runpod-fetch-latest: ## Fetch artifacts into ./out/latest
	LOCAL_OUT_DIR="$$(pwd)/out/latest" REMOTE_OUT="$(REMOTE_OUT)" ./runpod/fetch-artifacts.sh

runpod-stop: ## Stop active RunPod pod (keeps /workspace volume)
	./runpod/destroy.sh --stop

runpod-start: ## Start the previously-stopped RunPod pod
	./runpod/destroy.sh --start

runpod-destroy: ## Destroy the active RunPod pod (deletes /workspace too)
	./runpod/destroy.sh --destroy

runpod-clean-local: ## Remove local RunPod pod pointer only
	rm -f runpod/.pod_id

r2-fetch: ## Fetch a profile bundle from R2 (PROFILES=<id>, ENV_FILE=<path/to/.env>)
	@test -n "$(PROFILES)" || { echo "usage: make r2-fetch PROFILES=<id> [ENV_FILE=...]"; exit 1; }
	PROFILES="$(PROFILES)" ENV_FILE="$(ENV_FILE)" ./runpod/r2-fetch.sh

r2-fetch-latest: ## Fetch a profile bundle from R2 into ./out/latest
	@test -n "$(PROFILES)" || { echo "usage: make r2-fetch-latest PROFILES=<id>"; exit 1; }
	PROFILES="$(PROFILES)" ENV_FILE="$(ENV_FILE)" \
		LOCAL_OUT_DIR="$$(pwd)/out/latest" ./runpod/r2-fetch.sh

# ---------------------------------------------------------------------------
# Cuttlefish-in-Docker -- boot a built profile locally for screen-mirroring.
# On macOS this runs the linux/amd64 cuttlefish-orchestration image under
# Rosetta + TCG (no /dev/kvm), so cold boot takes ~30-60 min. On Linux with
# /dev/kvm it's ~1-2 min. Same Make targets either way.
# ---------------------------------------------------------------------------

cuttlefish-up: ## Boot PROFILE in cuttlefish container (PROFILE=galaxy-s26-ultra-apple-silicon)
	@test -n "$(PROFILE)" || { echo "usage: make cuttlefish-up PROFILE=<id>"; exit 1; }
	PROFILE="$(PROFILE)" ./docker/cuttlefish/run.sh

cuttlefish-down: ## Stop and remove the cuttlefish container
	@docker rm -f cf-mayaos 2>/dev/null && echo "removed cf-mayaos" || echo "no cf-mayaos container"

cuttlefish-status: ## Show container + cvd status
	@docker ps --filter name=cf-mayaos --format 'container: {{.Names}}  status: {{.Status}}  ports: {{.Ports}}' || true
	@docker exec cf-mayaos bash -lc 'cvd fleet 2>/dev/null || echo "(cvd not yet running)"' 2>/dev/null || true

cuttlefish-logs: ## Tail the cvd boot log inside the container
	@docker exec -it cf-mayaos bash -lc 'tail -F /tmp/cvd-create.log /home/vsoc-01/cuttlefish_runtime/launcher.log 2>/dev/null'

cuttlefish-shell: ## Open a shell inside the cuttlefish container
	@docker exec -it cf-mayaos bash -l

cuttlefish-adb: ## adb connect to the booted device
	@adb connect 127.0.0.1:6520

cuttlefish-scrcpy: cuttlefish-adb ## Launch scrcpy mirroring the booted device
	@scrcpy -s 127.0.0.1:6520

# ---------------------------------------------------------------------------
# qemu-system-aarch64 + Apple HVF -- direct boot, skips Cuttlefish entirely.
# Use this on macOS when you need native arm64 acceleration. The image was
# built FOR Cuttlefish, so first-stage init may complain about missing vsock
# or virtio-fs; iterate on EXTRA_APPEND until it boots.
# ---------------------------------------------------------------------------

qemu-up: ## Boot PROFILE under qemu+HVF (PROFILE=galaxy-s26-ultra-apple-silicon)
	@test -n "$(PROFILE)" || { echo "usage: make qemu-up PROFILE=<id> [EXTRA_APPEND='...']"; exit 1; }
	PROFILE="$(PROFILE)" EXTRA_APPEND="$(EXTRA_APPEND)" ./docker/qemu/run.sh

qemu-down: ## Kill the running qemu process
	@pkill -f "qemu-system-aarch64.*mayaos-" 2>/dev/null && echo "killed qemu" || echo "no qemu running"

qemu-adb: ## adb connect to the qemu-booted device
	@adb connect 127.0.0.1:6520

qemu-scrcpy: qemu-adb ## Launch scrcpy against the qemu-booted device
	@scrcpy -s 127.0.0.1:6520

# ---------------------------------------------------------------------------
# Android Studio Emulator (HVF-native arm64 on Mac).
#
# The MayaOS emulator-target profile (galaxy-s26-ultra-emulator) lives in
# mayaos.yaml + aosp-tree/device/mayaos/galaxy-s26-ultra/mayaos_emu_s26ultra.mk
# (rev-5 layered split). It inherits AOSP's sdk_phone64_arm64 product (AVD-shaped
# artifacts: kernel-ranchu, system-qemu.img, vendor-qemu.img, etc.) and applies
# the same Samsung Galaxy S26 Ultra branding spoof as the cuttlefish variants.
#
# Two paths to a built bundle on the pod:
#
#   1. PROPER PIPELINE PATH (recommended):
#         make runpod-build-emulator
#      Runs the standard build pipeline (init.sh -> after-sync ->
#      before-build -> m -> after-build) for ONLY the emulator profile. This
#      runs all the parity checks, applies all the container-env workarounds,
#      packages the emu/ bundle with metadata (build.prop / source.properties /
#      package.xml), and uploads to R2 if R2_* env vars are set.
#
#   2. STANDALONE QUICK PATH (legacy; no metadata bundling):
#         make runpod-emulator-build-direct
#      Bypasses the pipeline; just runs `m droid` against the lunch target in
#      a tmux pane. Useful for ccache-warm rebuilds when iterating on the .mk.
#      after-build hook is NOT invoked, so the resulting artifacts have no
#      emu/ subdir -- run.sh will regenerate metadata at boot time (legacy
#      bundle path).
# ---------------------------------------------------------------------------

runpod-build-emulator: ## Kick a full pipeline build for the emulator profile only on the active pod
	@PROFILES=galaxy-s26-ultra-emulator $(MAKE) runpod-build

runpod-emulator-build-direct: ## (legacy) Direct `m droid` against MayaOS emulator lunch target on the pod, bypasses the pipeline
	./runpod/ssh.sh 'tmux new-window -t mayaos-build -n emulator -d \
		"cd /workspace/aosp-src && source build/envsetup.sh && \
		 lunch mayaos_emu_s26ultra-trunk_staging-userdebug && \
		 time m -j16 droid 2>&1 | tee /workspace/aosp-logs/mayaos-emulator.log; \
		 echo BUILD_DONE; sleep 86400"'

runpod-emulator-watch: ## Tail the emulator-build pane on the pod
	@./runpod/ssh.sh 'tmux capture-pane -t mayaos-build:emulator -p | tail -30; \
		echo; echo === out/emu64a ===; \
		ls /workspace/aosp-src/out/target/product/emu64a/*.img 2>/dev/null | wc -l | xargs -I{} echo "  {} *.img produced"; \
		ls /workspace/aosp-src/out/target/product/emu64a/ 2>/dev/null | head -20'

runpod-emulator-fetch: ## Pull emulator-target artifacts (kernel-ranchu, system.img, ..., metadata) from the pod
	@test -n "$(PROFILE)" || { echo "usage: make runpod-emulator-fetch PROFILE=<id>"; exit 1; }
	@mkdir -p out/latest/$(PROFILE)/emu
	@# Prefer the after-build hook's emu/ bundle (has metadata baked in).
	@# Fall back to raw out/target/product/emu64a/ for legacy / direct builds.
	@source runpod/common.sh && \
		IFS=$$'\t' read -r user host port < <(current_pod_ssh) && \
		ssh_opts="-i $$(ssh_key_path) -p $$port -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR" && \
		bundle_path="/workspace/aosp-src/out/$(PROFILE)/emu/" && \
		if ssh $$ssh_opts $$user@$$host "test -d $$bundle_path"; then \
			echo "fetching pipeline-built bundle: $$bundle_path"; \
			rsync -azP -e "ssh $$ssh_opts" "$$user@$$host:$$bundle_path" "out/latest/$(PROFILE)/emu/"; \
		else \
			echo "no bundle at $$bundle_path; falling back to raw emu64a artifacts"; \
			for f in kernel-ranchu system.img system-qemu.img vendor.img vendor-qemu.img \
			         userdata.img ramdisk.img ramdisk-qemu.img vbmeta.img encryptionkey.img \
			         advancedFeatures.ini kernel_cmdline.txt VerifiedBootParams.textproto; do \
				rsync -azP --ignore-missing-args -e "ssh $$ssh_opts" \
					"$$user@$$host:/workspace/aosp-src/out/target/product/emu64a/$$f" \
					out/latest/$(PROFILE)/emu/ 2>&1 | tail -3; \
			done; \
		fi

emulator-up: ## Boot AOSP emulator AVD with PROFILE's images (background; window+adb visible)
	@test -n "$(PROFILE)" || { echo "usage: make emulator-up PROFILE=<id>"; exit 1; }
	PROFILE="$(PROFILE)" ./docker/emulator/run.sh

emulator-down: ## Kill the running emulator
	@pkill -f "qemu-system-aarch64" 2>/dev/null && echo "killed emulator" || echo "no emulator running"

emulator-adb: ## adb sees the emulator (default ports 5554/5555)
	@adb devices | tail -n +2

emulator-scrcpy: ## scrcpy mirror the booted emulator (uses emulator-5554)
	@scrcpy --serial emulator-5554 --window-title='MayaOS' --max-fps=30 --max-size=1080

# ---------------------------------------------------------------------------
# Stock arm64 AVD demo. Uses Google-distributed system-images;android-36.1;
# google_apis_playstore;arm64-v8a. Useful to (a) sanity-check the local
# emulator+HVF+scrcpy stack before MayaOS images are ready, and (b) keep a
# baseline AVD around for diffing behavior.
# ---------------------------------------------------------------------------

stock-avd-create: ## Create a baseline arm64 AVD (one-shot; idempotent)
	@SDK="$$HOME/Library/Android/sdk"; \
	export ANDROID_HOME="$$SDK" ANDROID_SDK_ROOT="$$SDK"; \
	echo no | "$$SDK/cmdline-tools/latest/bin/avdmanager" create avd \
		-n mayaos-stock \
		-k 'system-images;android-36.1;google_apis_playstore;arm64-v8a' \
		--force >/dev/null
	@echo "created AVD: mayaos-stock"

stock-emu-up: stock-avd-create ## Boot the stock baseline AVD in the background
	@SDK="$$HOME/Library/Android/sdk"; \
	mkdir -p /tmp/mayaos-emu; \
	nohup "$$SDK/emulator/emulator" -avd mayaos-stock -accel on -gpu host \
		-no-snapshot -no-boot-anim -netfast -ports 5554,5555 -verbose \
		>/tmp/mayaos-emu/emu.log 2>&1 & \
	echo $$! > /tmp/mayaos-emu/pid; \
	echo "spawned PID $$(cat /tmp/mayaos-emu/pid); log: /tmp/mayaos-emu/emu.log"

stock-emu-wait: ## Block until sys.boot_completed=1 (~30-60s on first boot)
	@for i in $$(seq 1 60); do \
		state=$$(adb -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' | head -c1); \
		if [ "$$state" = "1" ]; then echo "booted in ~$${i}x2s"; exit 0; fi; \
		echo "[$${i}/60] booting..."; sleep 2; \
	done; \
	echo "timed out waiting for boot"; exit 1

stock-scrcpy: ## scrcpy mirror the stock emulator
	@scrcpy --serial emulator-5554 --window-title='MayaOS (stock arm64)' --max-fps=30 --max-size=1080

stock-emu-down: ## Kill the stock emulator + its qemu-system-aarch64
	@pkill -f 'emulator.*-avd mayaos-stock' 2>/dev/null || true
	@pkill -f 'qemu-system-aarch64.*-avd mayaos-stock' 2>/dev/null || true
	@echo "killed stock emulator"

gh-secrets-list: ## List GitHub Actions secret names
	gh secret list --repo "$(REPO)"

gh-secrets-check: ## Verify required GitHub Actions secrets exist
	@required="VAST_API_KEY VAST_SSH_PRIVATE_KEY VAST_SSH_PUBLIC_KEY RUNPOD_API_KEY R2_ACCOUNT_ID R2_ACCESS_KEY_ID R2_SECRET_ACCESS_KEY R2_BUCKET"; \
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
