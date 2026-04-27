#!/usr/bin/env bash
#
# Phase 4: between after-sync and `m -j`.
#
# Default: no-op. Override to apply patches, regenerate prebuilt artifacts,
# or sanity-check the merged tree before kicking off the (~3-4h) build.
#
set -Eeuo pipefail
# shellcheck source=../lib.sh
source "/opt/pipeline/lib.sh"

log_info "before-build: validating customos lunch combo is registered"

cd "$SRC_DIR"
# Sourcing envsetup.sh is expensive (~3s); only do it here if we're going to
# actually need lunch listings. The build phase sources it again.
(
    set +u
    # shellcheck source=/dev/null
    source build/envsetup.sh
    if ! lunch_choices=$(LUNCH_TARGET="" print_lunch_menu 2>/dev/null) && \
       ! lunch_choices=$(get_build_var COMMON_LUNCH_CHOICES 2>/dev/null); then
        lunch_choices=""
    fi
    if [[ -n "$lunch_choices" && "$lunch_choices" != *customos_cf_x86_64_phone* ]]; then
        log_warn "lunch menu does not list customos_cf_x86_64_phone; \
build will probably fail. Got: $lunch_choices"
    else
        log_info "  lunch combo present"
    fi
)

log_info "before-build: ok"
