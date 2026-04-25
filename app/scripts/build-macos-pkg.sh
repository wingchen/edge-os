#!/bin/bash
# Builds the EdgeOS .pkg installer for macOS.
# Run from the app/ directory: ./scripts/build-macos-pkg.sh
#
# Prerequisites:
#   - Tauri app built: npm run build
#   - Edge binary built: cd ../edge && cargo build --release
#   - Xcode command-line tools (pkgbuild, productbuild)

set -e
cd "$(dirname "$0")/.."

VERSION=$(python3 -c "import json; print(json.load(open('src-tauri/tauri.conf.json'))['version'])")
APP_PATH="src-tauri/target/release/bundle/macos/EdgeOS.app"
OUTPUT="EdgeOS-${VERSION}.pkg"

if [ ! -d "$APP_PATH" ]; then
    echo "ERROR: $APP_PATH not found. Run 'npm run build' first." >&2
    exit 1
fi

echo "Building $OUTPUT ..."

# Component package: installs EdgeOS.app into /Applications
pkgbuild \
    --component "$APP_PATH" \
    --scripts pkg-scripts \
    --identifier "com.sailoi.edgeos" \
    --version "$VERSION" \
    --install-location "/Applications" \
    "/tmp/EdgeOS-component.pkg"

# Product archive: wraps component with metadata
productbuild \
    --package "/tmp/EdgeOS-component.pkg" \
    --identifier "com.sailoi.edgeos" \
    --version "$VERSION" \
    "$OUTPUT"

rm -f /tmp/EdgeOS-component.pkg
echo "Done: $OUTPUT"
