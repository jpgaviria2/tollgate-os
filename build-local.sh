#!/bin/bash
set -e

# Local TollGate OS Build Script
# Builds firmware locally without GitHub Actions

echo "🏗️  Local TollGate OS Build Script"
echo "=================================="

# Load environment configuration
if [ -f "local-build.env" ]; then
    echo "📋 Loading configuration from local-build.env"
    source local-build.env
elif [ -f ".env.local" ]; then
    echo "📋 Loading configuration from .env.local"
    source .env.local
fi

# Configuration - customize these as needed
DEVICE_ID="${DEVICE_ID:-glinet_gl-mt6000}"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.1}"
TOLLGATE_VERSION="${TOLLGATE_VERSION:-v0.0.1}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-stable}"
BUILD_DIR="${BUILD_DIR:-/tmp/tollgate-local-build}"

# Create build directory
echo "📁 Setting up build directory: $BUILD_DIR"
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

# Determine target architecture
echo "🔍 Determining target for $DEVICE_ID..."
TARGET_URL="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/mediatek/filogic/profiles.json"
TARGET_DATA=$(curl -s "$TARGET_URL" | jq -r ".profiles.\"$DEVICE_ID\".target // \"mediatek/filogic\"")
echo "🎯 Target: $TARGET_DATA"

# Download ImageBuilder
IMAGEBUILDER_NAME="openwrt-imagebuilder-$OPENWRT_VERSION-mediatek-filogic.Linux-x86_64"
IMAGEBUILDER_URL_XZ="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/mediatek/filogic/$IMAGEBUILDER_NAME.tar.xz"
IMAGEBUILDER_URL_ZST="https://downloads.openwrt.org/releases/$OPENWRT_VERSION/targets/mediatek/filogic/$IMAGEBUILDER_NAME.tar.zst"

# Try .tar.xz first, fall back to .tar.zst
if curl --output /dev/null --silent --head --fail "$IMAGEBUILDER_URL_XZ"; then
    IMAGEBUILDER_URL="$IMAGEBUILDER_URL_XZ"
    ARCHIVE_TYPE="xz"
else
    IMAGEBUILDER_URL="$IMAGEBUILDER_URL_ZST"
    ARCHIVE_TYPE="zst"
fi

echo "📦 Downloading ImageBuilder..."
ARCHIVE_FILE="${IMAGEBUILDER_NAME}.tar.${ARCHIVE_TYPE}"
if [ ! -f "$ARCHIVE_FILE" ]; then
    curl -L -C - -O "$IMAGEBUILDER_URL"
fi

# Extract ImageBuilder
echo "📦 Extracting ImageBuilder..."
if [ ! -d "$IMAGEBUILDER_NAME" ]; then
    if [ "$ARCHIVE_TYPE" = "zst" ]; then
        tar --zstd -xf "${IMAGEBUILDER_NAME}.tar.zst"
    else
        tar xfJ "${IMAGEBUILDER_NAME}.tar.xz"
    fi
fi

cd "$IMAGEBUILDER_NAME"

# Copy custom files
echo "📋 Copying custom files..."
mkdir -p files
if [ -d "../../../files" ]; then
    cp -r ../../../files/* files/
    echo "✅ Custom files copied"
else
    echo "⚠️  No custom files directory found"
fi

# Set up packages
echo "📦 Setting up packages..."

# Base packages (from action.yml)
PACKAGES="base-files busybox ca-bundle dnsmasq dropbear firewall4 fstools kmod-gpio-button-hotplug kmod-leds-gpio libc libgcc libustream-mbedtls logd mtd netifd nftables odhcp6c opkg ppp ppp-mod-pppoe procd procd-seccomp procd-ujail swconfig uci uclient-fetch urandom-seed urngd openssh-sftp-server nodogsplash"

# Device-specific packages
DEVICE_PACKAGES="e2fsprogs f2fsck mkf2fs kmod-usb3 kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware"

# Download TollGate packages
echo "📥 Downloading TollGate packages..."
PACKAGES_DIR="packages/local"
mkdir -p "$PACKAGES_DIR"

# Get architecture for this device (aarch64_cortex-a53 for MT6000)
ARCH="aarch64_cortex-a53"

# Read release.json and download packages
if [ -f "../../../files/etc/tollgate/release.json" ]; then
    echo "🔍 Reading package information from release.json..."

    # Download tollgate-wrt package for our architecture
    PACKAGE_URL=$(jq -r ".modules[0].versions[0].architectures.\"$ARCH\".url" ../../../files/etc/tollgate/release.json)
    PACKAGE_HASH=$(jq -r ".modules[0].versions[0].architectures.\"$ARCH\".hash" ../../../files/etc/tollgate/release.json)

    if [ "$PACKAGE_URL" != "null" ] && [ -n "$PACKAGE_URL" ]; then
        PACKAGE_NAME="tollgate-wrt.ipk"
        echo "📦 Downloading: $PACKAGE_NAME"

        if curl -L -f --connect-timeout 30 --max-time 120 --retry 3 --retry-delay 5 -o "$PACKAGES_DIR/$PACKAGE_NAME" "$PACKAGE_URL"; then
            echo "✅ Downloaded tollgate-wrt package"

            # Create Packages index
            echo "📋 Creating package index..."
            touch "$PACKAGES_DIR/Packages"
            echo "Package: tollgate-wrt" >> "$PACKAGES_DIR/Packages"
            echo "Version: 0.0.1" >> "$PACKAGES_DIR/Packages"
            echo "Architecture: $ARCH" >> "$PACKAGES_DIR/Packages"
            echo "Filename: local/tollgate-wrt.ipk" >> "$PACKAGES_DIR/Packages"
            echo "Size: $(stat -f%z "$PACKAGES_DIR/$PACKAGE_NAME" 2>/dev/null || stat -c%s "$PACKAGES_DIR/$PACKAGE_NAME")" >> "$PACKAGES_DIR/Packages"
            echo "" >> "$PACKAGES_DIR/Packages"

            # Create compressed index
            gzip -9c "$PACKAGES_DIR/Packages" > "$PACKAGES_DIR/Packages.gz"

            TOLLGATE_PACKAGES="tollgate-wrt"
        else
            echo "❌ Failed to download tollgate-wrt package"
            echo "⚠️  Building without TollGate package - you'll need to install it manually later"
            TOLLGATE_PACKAGES=""
        fi
    else
        echo "❌ Could not find package URL for architecture $ARCH"
        TOLLGATE_PACKAGES=""
    fi
else
    echo "❌ release.json not found"
    TOLLGATE_PACKAGES=""
fi

# Combine all packages
ALL_PACKAGES="$PACKAGES $DEVICE_PACKAGES $TOLLGATE_PACKAGES"

echo "📦 Final package list: $ALL_PACKAGES"

# Build the firmware
echo "🏗️  Building firmware..."
echo "This may take 10-20 minutes..."

START_TIME=$(date +%s)

make image \
    PROFILE="$DEVICE_ID" \
    PACKAGES="$ALL_PACKAGES" \
    FILES="files" \
    V=s 2>&1 | tee build.log

END_TIME=$(date +%s)
BUILD_TIME=$((END_TIME - START_TIME))

# Check if build succeeded
if find bin/targets/ -name "*sysupgrade.bin" -type f | grep -q .; then
    echo "✅ Build succeeded! ($BUILD_TIME seconds)"

    # Show the firmware file
    FIRMWARE_PATH=$(find bin/targets/ -name "*sysupgrade.bin" -type f | head -1)
    FIRMWARE_SIZE=$(stat -f%z "$FIRMWARE_PATH" 2>/dev/null || stat -c%s "$FIRMWARE_PATH" 2>/dev/null || echo "unknown")

    echo ""
    echo "🎉 Firmware built successfully!"
    echo "📁 Location: $PWD/$FIRMWARE_PATH"
    echo "📏 Size: $FIRMWARE_SIZE bytes"
    echo ""
    echo "🚀 To flash to your router:"
    echo "scp $FIRMWARE_PATH root@192.168.1.1:/tmp/"
    echo "ssh root@192.168.1.1 'sysupgrade -n /tmp/$(basename $FIRMWARE_PATH)'"
    echo ""
    echo "📋 Build Summary:"
    echo "• Device: $DEVICE_ID"
    echo "• OpenWrt: $OPENWRT_VERSION"
    echo "• TollGate: $TOLLGATE_VERSION"
    echo "• Target: $TARGET_DATA"
    echo "• Build time: $BUILD_TIME seconds"

else
    echo "❌ Build failed!"
    echo "📋 Check build.log for details"
    exit 1
fi
