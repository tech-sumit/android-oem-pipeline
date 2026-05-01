#
# vendor/mayaos/BoardConfigExtra.mk -- shared BoardConfig fragment.
#
# Cuttlefish vsoc_<arch> products auto-generate ro.product.<partition>.{device,
# name} from TARGET_DEVICE / TARGET_PRODUCT, and bake ro.product.first_api_level
# into PRODUCT_VENDOR_PROPERTIES. MayaOS spoofs all of these via
# PRODUCT_PROPERTY_OVERRIDES, which AOSP's post_process_props rejects as a
# duplicate sysprop assignment by default. With BUILD_BROKEN_DUP_SYSPROP,
# duplicates are written to build.prop in source order and Android init's
# last-write-wins behavior at runtime resolves to our overrides.
#
# Rev 5: this used to be inlined into pipeline/hooks/after-sync.sh's
# patch_board_dup_sysprop() helper, which appended the assignment to every
# upstream BoardConfig.mk we touched. The Waydroid-style layout puts it
# in-tree and inherits it from each profile's BoardConfig.mk via:
#
#     -include vendor/mayaos/BoardConfigExtra.mk
#
# (or equivalent). after-sync still patches the upstream BoardConfigs as a
# safety net for branches/boards we haven't enumerated yet.

BUILD_BROKEN_DUP_SYSPROP := true

# Marketing-name properties (values contain spaces) cannot live in
# PRODUCT_PROPERTY_OVERRIDES because Soong splits the variable on
# whitespace before serialising soong.<product>.extra.variables, which
# corrupts the JSON for any value containing a space and crashes
# `merge_json` at the product_config.json step. Route them through a
# property file instead -- build/make/core/Makefile reads each line
# verbatim into /system_ext/build.prop with spaces preserved.
TARGET_SYSTEM_EXT_PROP += vendor/mayaos/marketing.prop
