#
# vendor/mayaos/Android.mk -- top-level vendor Make include.
#
# Pulls in every subdir's Android.mk. The MayaOS payload modules
# themselves are Soong (Android.bp); this Make file is the place to
# stick anything the rest of the tree expects to discover via
# PRODUCT_INCLUDE_DIRS / subdir-makefiles.
#

LOCAL_PATH := $(call my-dir)

include $(call all-makefiles-under,$(LOCAL_PATH))
