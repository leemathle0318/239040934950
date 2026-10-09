ARCHS = arm64
TARGET = iphone:clang:16.5:15.0
THEOS_PACKAGE_SCHEME = rootless

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = VCamLiveBridge
VCamLiveBridge_FILES = Tweak.c Overlay.m
VCamLiveBridge_CFLAGS = -O2 -Wall -Wextra
VCamLiveBridge_OBJCFLAGS = -fobjc-arc -O2 -Wall -Wextra
VCamLiveBridge_FRAMEWORKS = UIKit AVFoundation QuartzCore
VCamLiveBridge_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk
