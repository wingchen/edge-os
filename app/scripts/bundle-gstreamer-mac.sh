#!/bin/bash
# Builds a minimal, relocatable GStreamer bundle for macOS using Cerbero.
# Output: app/gstreamer-bundle/  (picked up by tauri.conf.json bundle.resources)
#
# Prerequisites:
#   - Xcode command-line tools
#   - Python 3
#   - git
#
# Run from the app/ directory: ./scripts/bundle-gstreamer-mac.sh
#
# TODO: this script is a framework stub. Fill in each section as you work
# through the Cerbero build. The structure and env vars are correct; the
# Cerbero invocation needs to be verified against the installed version.

set -e
cd "$(dirname "$0")/.."

BUNDLE_DIR="$(pwd)/gstreamer-bundle"
CERBERO_DIR="/tmp/cerbero"
GST_VERSION="1.28.1"   # match system GStreamer version

# Required plugins only — keeps bundle to ~50MB
PLUGINS="
    gstreamer-1.0
    gst-plugins-base-1.0
    gst-plugins-good-1.0
    gst-plugins-bad-1.0
    gst-plugin-webrtc-1.0
    libnice
"

echo "==> GStreamer macOS bundle builder"
echo "    Output: $BUNDLE_DIR"

# ── Step 1: Clone Cerbero ──────────────────────────────────────────────────────
if [ ! -d "$CERBERO_DIR" ]; then
    echo "==> Cloning Cerbero (GStreamer build system)"
    git clone --depth 1 --branch "$GST_VERSION" \
        https://gitlab.freedesktop.org/gstreamer/cerbero.git \
        "$CERBERO_DIR"
fi

cd "$CERBERO_DIR"

# ── Step 2: Bootstrap Cerbero ──────────────────────────────────────────────────
echo "==> Bootstrapping Cerbero"
# TODO: adjust python version if needed
python3 cerbero-uninstalled bootstrap

# ── Step 3: Build minimal bundle ──────────────────────────────────────────────
echo "==> Building GStreamer bundle (this takes 20-40 minutes on first run)"
# TODO: run only the packages we need, not the full build
python3 cerbero-uninstalled build \
    gst-plugins-bad-1.0 \
    gst-plugins-good-1.0 \
    gst-plugin-webrtc-1.0

# ── Step 4: Package into a relocatable bundle ──────────────────────────────────
echo "==> Packaging into relocatable bundle"
python3 cerbero-uninstalled package \
    --offline \
    -o /tmp/gst-bundle \
    gstreamer-1.0

# ── Step 5: Extract and trim ──────────────────────────────────────────────────
echo "==> Trimming to required plugins only"
# TODO: extract the .pkg/tarball from step 4 and copy only the plugins we need:
#   libgstcoreelements, libgstrtspsrc, libgstrtpmanager, libgstrtp,
#   libgsth264parse, libgstrtph264, libgstwebrtc, libgstnice, libgstapp,
#   libgstvideoconvert, libgstopenh264
#
# rm -rf "$BUNDLE_DIR"
# mkdir -p "$BUNDLE_DIR/plugins" "$BUNDLE_DIR/lib"
# cp <selected plugins> "$BUNDLE_DIR/plugins/"
# cp <required dylibs>  "$BUNDLE_DIR/lib/"

# ── Step 6: Relocate dylib paths ──────────────────────────────────────────────
echo "==> Relocating dylib paths with dylibbundler"
# TODO: install dylibbundler if not present: brew install dylibbundler
# Then for each plugin dylib:
#   dylibbundler -od -b \
#     -x "$BUNDLE_DIR/plugins/libgstrtspsrc.dylib" \
#     -d "$BUNDLE_DIR/lib/" \
#     -p @loader_path/../lib/
# Repeat for all plugin dylibs.

echo ""
echo "TODO: complete steps 4-6 before shipping macOS builds."
echo "      The bundle output should land in: $BUNDLE_DIR"
echo "      tauri.conf.json references it as a resource — Tauri will include it in the .app."
