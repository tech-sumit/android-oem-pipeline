#!/usr/bin/env python3
"""
Stub out trusty's nsjail-based VM genrules. The Trusty TEE simulator
build (used only by Cuttlefish for VM-based trusted-HAL emulation)
requires nsjail-mediated bind mounts AND a custom Rust target
(`x86_64-unknown-trusty-kernel`) whose `core` rlib is not in
prebuilts/rust. On managed Docker hosts (RunPod / Vast / GH Actions)
neither works, so the build dies at 85% with E0463 ("can't find crate
for `core`") -- which is fixable in upstream Trusty but not in our
build environment.

This patcher rewrites Android.bp's shared `genrule_cmd_template` to
emit a stub ELF/bin (just an ELF magic header plus a marker tag).
That short-circuits ALL trusty VM genrules in this file:
    * trusty_security_vm_x86_64.elf / trusty_security_vm_arm64.bin
    * trusty_test_vm_x86_64.elf     / trusty_test_vm_arm64.bin
    * trusty_test_vm_os_x86_64.elf  / trusty_test_vm_os_arm64.bin
    * trusty_desktop_vm_arm64.bin   / trusty_desktop_vm_x86_64.bin
    * trusty_desktop_vm_arm64-test.bin
The system images we ship from this build are for diagnostic /
emulation use; the stub VMs will not actually run, but the rest of
Cuttlefish boots and our MayaOS device tree's runtime apps are
unaffected.

Idempotent: re-running this script on an already-patched tree is a
no-op.
"""
import re
import sys
from pathlib import Path

MARKER = "MAYAOS_TRUSTY_STUB"

# Stub command. Notes on quoting:
#   * Soong runs the cmd through bash with $$ -> $ unescaped.
#   * The leading ":" makes bash ignore everything up to the ";".
#     We list every $(location ...) and $(build_*_file) so Soong's
#     "all referenced tools must appear in `tools:`" check passes.
#   * printf emits 4-byte ELF magic, a marker, the project name,
#     a dot, the output extension, a newline. Tiny and identifiable.
STUB = '\n'.join([
    'genrule_cmd_template = "' + ': $(location aidl) $(location aidl_rust_glue) " +',
    '    "$(location aprotoc) $(location trusty_metrics_atoms_protoc_plugin) " +',
    '    "$(location build_trusty) $(build_date_file) $(build_number_file); " +',
    f'    "printf \'\\\\x7fELF{MARKER}-%s.%s\\\\n\' \\"$$PROJECT_NAME\\" \\"$$OUT_EXT\\" > $(out)"',
])

PATTERN = re.compile(
    r'genrule_cmd_template = "\(mkdir -p .*?\$\(out\)"',
    re.DOTALL,
)


def main(path: Path) -> int:
    text = path.read_text()
    if MARKER in text:
        print(f"already stubbed: {path}")
        return 0

    new_text, n = PATTERN.subn(STUB, text)
    if n != 1:
        print(
            f"expected 1 substitution in {path}, got {n} "
            "(file shape changed?)",
            file=sys.stderr,
        )
        return 2

    backup = path.with_suffix(path.suffix + ".mayaosbak")
    if not backup.exists():
        backup.write_text(text)

    path.write_text(new_text)
    print(f"patched {path} ({n} substitution; backup -> {backup.name})")
    return 0


if __name__ == "__main__":
    target = (
        Path(sys.argv[1])
        if len(sys.argv) > 1
        else Path(
            "/workspace/aosp-src/trusty/vendor/google/aosp/scripts/Android.bp"
        )
    )
    sys.exit(main(target))
