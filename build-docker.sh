#!/bin/bash
# Docker-based local TollGate OS build script
# Runs OpenWrt ImageBuilder in a Linux container

set -e

echo "🐳 Docker TollGate OS Build Script"
echo "=================================="

# Load configuration
if [ -f "local-build.env" ]; then
    echo "📋 Loading configuration from local-build.env"
    source local-build.env
elif [ -f ".env.local" ]; then
    echo "📋 Loading configuration from .env.local"
    source .env.local
fi

# Configuration with defaults
DEVICE_ID="${DEVICE_ID:-glinet_gl-mt6000}"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
TOLLGATE_VERSION="${TOLLGATE_VERSION:-v0.0.1}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-stable}"
BUILD_DIR="${BUILD_DIR:-/tmp/tollgate-docker-build}"

# Docker configuration
DOCKER_IMAGE="ubuntu:22.04"
CONTAINER_NAME="tollgate-builder-$(date +%s)"

echo "📋 Configuration:"
echo "  Device: $DEVICE_ID"
echo "  OpenWrt: $OPENWRT_VERSION"
echo "  Channel: $RELEASE_CHANNEL"
echo "  Build Dir: $BUILD_DIR"
echo ""

# Check if Docker is running
if ! docker info >/dev/null 2>&1; then
    echo "❌ Docker is not running. Please start Docker Desktop."
    exit 1
fi

# Create build directory
echo "📁 Setting up build directory..."
mkdir -p "$BUILD_DIR"

# Create Dockerfile for the build environment
cat > "$BUILD_DIR/Dockerfile" << 'EOF'
FROM ubuntu:22.04

# Install required packages
RUN apt-get update && apt-get install -y \
    curl \
    wget \
    jq \
    xz-utils \
    zstd \
    build-essential \
    libncurses-dev \
    gawk \
    gettext \
    libssl-dev \
    xsltproc \
    zlib1g-dev \
    python3 \
    file \
    && rm -rf /var/lib/apt/lists/*

# Create build user
RUN useradd -m -s /bin/bash builder
USER builder
WORKDIR /home/builder

CMD ["/bin/bash"]
EOF

# Create build script that will run inside Docker
cat > "$BUILD_DIR/build-inside-docker.sh" << EOF
#!/bin/bash
set -e

echo "🏗️  Building inside Docker container..."

# Configuration (passed from host)
DEVICE_ID="$DEVICE_ID"
OPENWRT_VERSION="$OPENWRT_VERSION"
TOLLGATE_VERSION="$TOLLGATE_VERSION"
RELEASE_CHANNEL="$RELEASE_CHANNEL"

echo "🔍 Determining target for \$DEVICE_ID..."
TARGET_URL="https://downloads.openwrt.org/releases/\$OPENWRT_VERSION/targets/mediatek/filogic/profiles.json"
TARGET_DATA=\$(curl -s "\$TARGET_URL" | jq -r ".profiles.\"\$DEVICE_ID\".target // \"mediatek/filogic\"")
echo "🎯 Target: \$TARGET_DATA"

# Download ImageBuilder
IMAGEBUILDER_NAME="openwrt-imagebuilder-\$OPENWRT_VERSION-mediatek-filogic.Linux-x86_64"
IMAGEBUILDER_URL_ZST="https://downloads.openwrt.org/releases/\$OPENWRT_VERSION/targets/mediatek/filogic/\$IMAGEBUILDER_NAME.tar.zst"

echo "📦 Downloading ImageBuilder..."
if [ ! -f "\$IMAGEBUILDER_NAME.tar.zst" ]; then
    curl -L -C - -O "\$IMAGEBUILDER_URL_ZST"
fi

# Extract ImageBuilder
echo "📦 Extracting ImageBuilder..."
if [ ! -d "\$IMAGEBUILDER_NAME" ]; then
    tar --zstd -xf "\${IMAGEBUILDER_NAME}.tar.zst"
fi

cd "\$IMAGEBUILDER_NAME"

# Copy custom files
echo "📋 Copying custom files..."
mkdir -p files
if [ -d "/build/files" ]; then
    cp -r /build/files/* files/
    echo "✅ Custom files copied"
fi

# Set up packages
echo "📦 Setting up packages..."

# Base packages
PACKAGES="base-files busybox ca-bundle dnsmasq dropbear firewall4 fstools kmod-gpio-button-hotplug kmod-leds-gpio libc libgcc libustream-mbedtls logd mtd netifd nftables odhcp6c opkg ppp ppp-mod-pppoe procd procd-seccomp procd-ujail swconfig uci uclient-fetch urandom-seed urngd openssh-sftp-server nodogsplash"

# Device-specific packages
DEVICE_PACKAGES="e2fsprogs f2fsck mkf2fs kmod-usb3 kmod-mt7915e kmod-mt7986-firmware mt7986-wo-firmware"

# TollGate packages
PACKAGES_DIR="packages/local"
mkdir -p "\$PACKAGES_DIR"

# Try to download tollgate-wrt package
echo "📥 Downloading TollGate packages..."
if [ -f "/build/files/etc/tollgate/release.json" ]; then
    ARCH="aarch64_cortex-a53"
    PACKAGE_URL=\$(jq -r ".modules[0].versions[0].architectures.\"\$ARCH\".url" /build/files/etc/tollgate/release.json 2>/dev/null)

    if [ "\$PACKAGE_URL" != "null" ] && [ -n "\$PACKAGE_URL" ]; then
        PACKAGE_NAME="tollgate-wrt.ipk"
        echo "📦 Downloading: \$PACKAGE_NAME"

        if curl -L -f --connect-timeout 30 --max-time 120 --retry 3 --retry-delay 5 -o "\$PACKAGES_DIR/\$PACKAGE_NAME" "\$PACKAGE_URL"; then
            echo "✅ Downloaded tollgate-wrt package"

            # Create Packages index
            touch "\$PACKAGES_DIR/Packages"
            echo "Package: tollgate-wrt" >> "\$PACKAGES_DIR/Packages"
            echo "Version: 0.0.1" >> "\$PACKAGES_DIR/Packages"
            echo "Architecture: \$ARCH" >> "\$PACKAGES_DIR/Packages"
            echo "Filename: local/tollgate-wrt.ipk" >> "\$PACKAGES_DIR/Packages"
            echo "Size: \$(stat -c%s "\$PACKAGES_DIR/\$PACKAGE_NAME" 2>/dev/null || stat -f%z "\$PACKAGES_DIR/\$PACKAGE_NAME")" >> "\$PACKAGES_DIR/Packages"
            echo "" >> "\$PACKAGES_DIR/Packages"
            gzip -9c "\$PACKAGES_DIR/Packages" > "\$PACKAGES_DIR/Packages.gz"

            TOLLGATE_PACKAGES="tollgate-wrt"
        else
            echo "❌ Failed to download tollgate-wrt package"
            TOLLGATE_PACKAGES=""
        fi
    fi
fi

# Combine all packages
ALL_PACKAGES="\$PACKAGES \$DEVICE_PACKAGES \$TOLLGATE_PACKAGES"
echo "📦 Final package list: \$ALL_PACKAGES"

# Build the firmware
echo "🏗️  Building firmware..."
echo "This may take 15-25 minutes..."

START_TIME=\$(date +%s)

make image \
    PROFILE="\$DEVICE_ID" \
    PACKAGES="\$ALL_PACKAGES" \
    FILES="files" \
    V=s 2>&1 | tee build.log

END_TIME=\$(date +%s)
BUILD_TIME=\$((END_TIME - START_TIME))

# Check if build succeeded
if find bin/targets/ -name "*sysupgrade.bin" -type f | grep -q .; then
    echo "✅ Build succeeded! (\$BUILD_TIME seconds)"

    # Copy the firmware to the shared volume
    FIRMWARE_PATH=\$(find bin/targets/ -name "*sysupgrade.bin" -type f | head -1)
    cp "\$FIRMWARE_PATH" /build/

    echo "📁 Firmware copied to host: /build/\$(basename "\$FIRMWARE_PATH")"
    echo "📏 Build time: \$BUILD_TIME seconds"
    echo ""
    echo "🎉 Build completed successfully!"

else
    echo "❌ Build failed!"
    echo "📋 Check build.log for details"
    exit 1
fi
EOF

chmod +x "$BUILD_DIR/build-inside-docker.sh"

# Build the Docker image
echo "🏗️  Building Docker image..."
docker build -t tollgate-builder "$BUILD_DIR"

# Run the build in Docker
echo "🚀 Running build in Docker container..."
docker run --rm \
    --name "$CONTAINER_NAME" \
    -v "$PWD:$BUILD_DIR" \
    -v "$PWD:/build" \
    --workdir "/tmp" \
    tollgate-builder \
    bash "/tmp/build-inside-docker.sh"

# Check if firmware was created
FIRMWARE_FILE=$(find . -name "*sysupgrade.bin" -type f | head -1)
if [ -n "$FIRMWARE_FILE" ]; then
    FIRMWARE_SIZE=$(stat -f%z "$FIRMWARE_FILE" 2>/dev/null || stat -c%s "$FIRMWARE_FILE" 2>/dev/null || echo "unknown")

    echo ""
    echo "🎉 Docker build completed successfully!"
    echo "📁 Firmware location: $PWD/$FIRMWARE_FILE"
    echo "📏 Size: $FIRMWARE_SIZE bytes"
    echo ""
    echo "🚀 To flash to your router:"
    echo "scp $FIRMWARE_FILE root@192.168.1.1:/tmp/"
    echo "ssh root@192.168.1.1 'sysupgrade -n /tmp/$(basename $FIRMWARE_FILE)'"
    echo ""
    echo "☕ Your Trails Coffee TollGate firmware is ready!"
else
    echo "❌ Build failed - no firmware file found"
    echo "Check Docker logs: docker logs $CONTAINER_NAME"
    exit 1
fi
