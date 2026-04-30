#
# vendor/mayaos/vendorsetup.sh -- registered with envsetup.sh on every lunch.
#
# Sourced automatically by build/envsetup.sh on `source` because envsetup
# globs vendor/*/vendorsetup.sh during init. Use this to add MayaOS lunch
# combos so they appear in the `lunch` menu without each device dir having
# to repeat them.
#
# add_lunch_combo (deprecated post AOSP 12 in favor of AndroidProducts.mk
# COMMON_LUNCH_CHOICES) is gracefully degraded in modern AOSP -- if the
# function is undefined we silently skip and rely on COMMON_LUNCH_CHOICES.
#

if declare -f add_lunch_combo >/dev/null 2>&1; then
    add_lunch_combo mayaos_cf_s26ultra-trunk_staging-userdebug
    add_lunch_combo mayaos_cf_s26ultra_arm64-trunk_staging-userdebug
    add_lunch_combo mayaos_emu_s26ultra-trunk_staging-userdebug
    add_lunch_combo mayaos_emu_s26ultra_x86_64-trunk_staging-userdebug
fi
