#!/usr/bin/env bash
# Run the edge daemon locally on macOS.
#
# Usage:
#   ./dev-mac.sh                  — build (debug) + run against Homebrew GStreamer
#   ./dev-mac.sh --release        — build release + run against Homebrew GStreamer
#   ./dev-mac.sh --bundle         — run against the installed EdgeOS bundle (production parity)
#   ./dev-mac.sh --no-build       — skip build, re-run last binary
#
# Option A (default): Homebrew GStreamer — fastest iteration
# Option B: --bundle — uses /Library/Application Support/EdgeOS/gstreamer/
#           (requires EdgeOS to have been installed at least once)

set -euo pipefail
cd "$(dirname "$0")"

BREW=$(brew --prefix)
EDGE_DIR="/Library/Application Support/EdgeOS"
PROFILE="debug"
USE_BUNDLE=0
SKIP_BUILD=0

for arg in "$@"; do
  case $arg in
    --release)   PROFILE="release" ;;
    --bundle)    USE_BUNDLE=1 ;;
    --no-build)  SKIP_BUILD=1 ;;
  esac
done

if [ "$SKIP_BUILD" -eq 0 ]; then
  if [ "$PROFILE" = "release" ]; then
    cargo build --release
  else
    cargo build
  fi
fi

BINARY="./target/${PROFILE}/edge-os-edge"

if [ "$USE_BUNDLE" -eq 1 ]; then
  if [ ! -d "$EDGE_DIR/gstreamer" ]; then
    echo "ERROR: $EDGE_DIR/gstreamer not found. Install EdgeOS first, or run without --bundle."
    exit 1
  fi
  echo "Running against installed bundle..."
  exec env \
    EDGE_OS_EDGE_DIR="$EDGE_DIR" \
    GST_PLUGIN_PATH="$EDGE_DIR/gstreamer/plugins" \
    GST_REGISTRY_1_0="$EDGE_DIR/gst-registry.bin" \
    DYLD_LIBRARY_PATH="$EDGE_DIR/gstreamer/lib" \
    RUST_LOG="${RUST_LOG:-debug}" \
    "$BINARY"
else
  echo "Running against Homebrew GStreamer..."
  exec env \
    EDGE_OS_EDGE_DIR="$EDGE_DIR" \
    GST_PLUGIN_PATH="$BREW/lib/gstreamer-1.0" \
    RUST_LOG="${RUST_LOG:-debug}" \
    "$BINARY"
fi
