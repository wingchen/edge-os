#!/usr/bin/env bash
# Run the edge daemon locally on macOS using the already-installed GStreamer bundle.
# Requires EdgeOS to have been installed at least once (so the gstreamer/ dir exists).
#
# Usage:
#   ./dev-mac.sh          — build (debug) then run
#   ./dev-mac.sh --release — build release then run
#   ./dev-mac.sh --no-build — skip build, re-run last binary

set -euo pipefail

EDGE_DIR="/Library/Application Support/EdgeOS"
PROFILE="debug"

for arg in "$@"; do
  case $arg in
    --release)   PROFILE="release" ;;
    --no-build)  SKIP_BUILD=1 ;;
  esac
done

if [[ ! -d "$EDGE_DIR/gstreamer" ]]; then
  echo "ERROR: $EDGE_DIR/gstreamer not found."
  echo "Install the EdgeOS app once first so the GStreamer bundle is present."
  exit 1
fi

if [[ -z "${SKIP_BUILD:-}" ]]; then
  if [[ "$PROFILE" == "release" ]]; then
    cargo build --release
  else
    cargo build
  fi
fi

BINARY="./target/${PROFILE}/edge-os-edge"

echo "Running $BINARY with installed GStreamer..."

EDGE_OS_EDGE_DIR="$EDGE_DIR" \
GST_PLUGIN_PATH="$EDGE_DIR/gstreamer/plugins" \
GST_REGISTRY_1_0="$EDGE_DIR/gst-registry.bin" \
DYLD_LIBRARY_PATH="$EDGE_DIR/gstreamer/lib" \
RUST_LOG="${RUST_LOG:-debug}" \
"$BINARY"
