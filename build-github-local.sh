#!/bin/bash
# Hybrid local-GitHub build script
# Triggers GitHub Actions build and downloads the result

set -e

echo "🚀 TollGate OS GitHub Actions Builder"
echo "===================================="

# Load configuration
if [ -f "local-build.env" ]; then
    echo "📋 Loading configuration from local-build.env"
    source local-build.env
elif [ -f ".env.local" ]; then
    echo "📋 Loading configuration from .env.local"
    source .env.local
fi

# Configuration with defaults
REPO="${REPO:-jpgaviria/tollgate-os}"
DEVICE_ID="${DEVICE_ID:-glinet_gl-mt6000}"
OPENWRT_VERSION="${OPENWRT_VERSION:-24.10.5}"
RELEASE_CHANNEL="${RELEASE_CHANNEL:-stable}"
OUTPUT_DIR="${OUTPUT_DIR:-./firmware}"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Check if GitHub CLI is installed
if ! command -v gh &> /dev/null; then
    echo -e "${RED}❌ GitHub CLI not found!${NC}"
    echo "Install from: https://cli.github.com/"
    echo "Or run: brew install gh"
    echo "Then: gh auth login"
    exit 1
fi

# Check if authenticated
if ! gh auth status &> /dev/null; then
    echo -e "${RED}❌ Not authenticated with GitHub CLI!${NC}"
    echo "Run: gh auth login"
    exit 1
fi

echo -e "${BLUE}📋 Configuration:${NC}"
echo "  Repository: $REPO"
echo "  Device: $DEVICE_ID"
echo "  OpenWrt: $OPENWRT_VERSION"
echo "  Channel: $RELEASE_CHANNEL"
echo ""

# Trigger the workflow
echo -e "${YELLOW}🚀 Triggering GitHub Actions build...${NC}"

WORKFLOW_RUN_ID=$(gh workflow run build-tollgate.yml \
    --repo "$REPO" \
    -f device_id="$DEVICE_ID" \
    -f openwrt_version="$OPENWRT_VERSION" \
    -f release_channel="$RELEASE_CHANNEL" \
    --json databaseId -q .databaseId)

if [ -z "$WORKFLOW_RUN_ID" ]; then
    echo -e "${RED}❌ Failed to trigger workflow${NC}"
    exit 1
fi

echo -e "${GREEN}✅ Workflow triggered! Run ID: $WORKFLOW_RUN_ID${NC}"
echo ""

# Wait for completion
echo -e "${YELLOW}⏳ Waiting for build to complete...${NC}"
echo "You can monitor progress at: https://github.com/$REPO/actions/runs/$WORKFLOW_RUN_ID"
echo ""

# Poll for completion
while true; do
    STATUS=$(gh run view "$WORKFLOW_RUN_ID" --repo "$REPO" --json status -q .status)

    case $STATUS in
        "completed")
            CONCLUSION=$(gh run view "$WORKFLOW_RUN_ID" --repo "$REPO" --json conclusion -q .conclusion)
            if [ "$CONCLUSION" = "success" ]; then
                echo -e "${GREEN}✅ Build completed successfully!${NC}"
                break
            else
                echo -e "${RED}❌ Build failed with conclusion: $CONCLUSION${NC}"
                echo "Check the logs at: https://github.com/$REPO/actions/runs/$WORKFLOW_RUN_ID"
                exit 1
            fi
            ;;
        "in_progress"|"queued")
            echo -n "."
            sleep 30
            ;;
        *)
            echo -e "${RED}❌ Unexpected status: $STATUS${NC}"
            exit 1
            ;;
    esac
done

echo ""

# Download artifacts
echo -e "${YELLOW}📥 Downloading firmware...${NC}"

mkdir -p "$OUTPUT_DIR"
cd "$OUTPUT_DIR"

if gh run download "$WORKFLOW_RUN_ID" --repo "$REPO"; then
    echo -e "${GREEN}✅ Firmware downloaded to: $OUTPUT_DIR${NC}"

    # Find the firmware file
    FIRMWARE_FILE=$(find . -name "*.bin" -type f | head -1)
    if [ -n "$FIRMWARE_FILE" ]; then
        FIRMWARE_SIZE=$(stat -f%z "$FIRMWARE_FILE" 2>/dev/null || stat -c%s "$FIRMWARE_FILE" 2>/dev/null || echo "unknown")
        echo -e "${GREEN}📁 Firmware file: $FIRMWARE_FILE${NC}"
        echo -e "${GREEN}📏 Size: $FIRMWARE_SIZE bytes${NC}"
        echo ""
        echo -e "${BLUE}🚀 To flash to your router:${NC}"
        echo "scp $FIRMWARE_FILE root@192.168.1.1:/tmp/"
        echo "ssh root@192.168.1.1 'sysupgrade -n /tmp/$(basename $FIRMWARE_FILE)'"
    fi
else
    echo -e "${RED}❌ Failed to download artifacts${NC}"
    echo "You can manually download from: https://github.com/$REPO/actions/runs/$WORKFLOW_RUN_ID"
    exit 1
fi

echo ""
echo -e "${GREEN}🎉 Your Trails Coffee TollGate firmware is ready!${NC}"
