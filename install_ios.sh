#!/bin/bash
# Build HermesAgent for a paired iPhone and install via devicectl.
# Uses DerivedData under /tmp to avoid iCloud xattr breaking codesign.
set -euo pipefail
cd "$(dirname "$0")"

XCODE_APP="${XCODE_APP:-/Applications/Xcode-beta.app}"
export DEVELOPER_DIR="$XCODE_APP/Contents/Developer"
SCRATCH="${TMPDIR:-/tmp}/hermesagent-ios-build"
CONFIG="${CONFIGURATION:-Debug}"
# SKIP_SHARE=1: Share Extension なしでビルド（App Groups 未設定のプロビジョニング向け）
SPEC="${XCODEGEN_SPEC:-project.yml}"
if [ "${SKIP_SHARE:-0}" = "1" ]; then
  SPEC="project.device.yml"
  echo "ℹ️  SKIP_SHARE=1 → Share Extension を除外してビルドします"
fi

if [ ! -d "$DEVELOPER_DIR" ]; then
  echo "⚠️  Full Xcode not found at $XCODE_APP" >&2
  echo "   Set XCODE_APP=/Applications/Xcode.app $0" >&2
  exit 1
fi

DEVICE="${DEVICE:-}"
if [ -z "$DEVICE" ]; then
  DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | awk '/available \(paired\)/ { print $3; exit }')
fi
if [ -z "$DEVICE" ]; then
  echo "⚠️  No paired iPhone found. Connect device and trust this Mac, or set DEVICE=<uuid>." >&2
  exit 1
fi

echo "Toolchain: $DEVELOPER_DIR"
echo "Device:    $DEVICE"
echo "Scratch:   $SCRATCH"

command -v xcodegen >/dev/null && xcodegen generate --spec "$SPEC"

xcodebuild \
  -project HermesAgent.xcodeproj \
  -scheme HermesAgent \
  -destination "platform=iOS,id=$DEVICE" \
  -configuration "$CONFIG" \
  -derivedDataPath "$SCRATCH/DerivedData" \
  -allowProvisioningUpdates \
  build

APP="$SCRATCH/DerivedData/Build/Products/${CONFIG}-iphoneos/HermesAgent.app"
xcrun devicectl device install app --device "$DEVICE" "$APP"
xcrun devicectl device process launch --device "$DEVICE" com.custom.hermesagent

echo "✅ Installed and launched HermesAgent on $DEVICE"
