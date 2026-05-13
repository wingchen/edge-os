#!/usr/bin/env bash
# Local macOS DMG build — mirrors .github/workflows/build-macos.yml exactly.
# Run from the repo root: ./scripts/build-mac-dmg.sh
#
# Prerequisites (one-time setup):
#   brew install pkgconf gstreamer gst-plugins-base gst-plugins-good \
#                gst-plugins-bad gst-plugins-ugly libnice libnice-gstreamer \
#                dylibbundler node
#   cd app && npm ci

set -euo pipefail
cd "$(dirname "$0")/.."

BREW=$(brew --prefix)

# ── Prerequisites check ────────────────────────────────────────────────────────
for cmd in cargo node npm dylibbundler pkg-config; do
  command -v "$cmd" &>/dev/null || { echo "ERROR: $cmd not found. See prerequisites above."; exit 1; }
done
[ -d "app/node_modules" ] || { echo "ERROR: run 'npm ci' in app/ first."; exit 1; }

# ── Export pkg-config paths ────────────────────────────────────────────────────
export PKG_CONFIG_PATH="${BREW}/lib/pkgconfig"
export LIBRARY_PATH="${BREW}/lib"
export GST_PLUGIN_PATH="${BREW}/lib/gstreamer-1.0"

# ── Build edge binary ──────────────────────────────────────────────────────────
echo "==> Building edge binary..."
(cd edge && cargo build --release --target aarch64-apple-darwin)

EDGE_BIN="edge/target/aarch64-apple-darwin/release/edge-os-edge"
LIB_DIR="app/src-tauri/gstreamer/lib"
PLUGIN_DIR="app/src-tauri/gstreamer/plugins"

# ── Bundle GStreamer ───────────────────────────────────────────────────────────
echo "==> Bundling GStreamer..."
rm -rf "$LIB_DIR" "$PLUGIN_DIR"
mkdir -p "$LIB_DIR" "$PLUGIN_DIR"

# Step 1: edge binary direct deps via dylibbundler
dylibbundler \
  --fix-file "$EDGE_BIN" \
  --bundle-deps \
  --dest-dir "$LIB_DIR" \
  --install-path "@executable_path/gstreamer/lib" \
  --overwrite-dir \
  --search-path "$BREW/lib"

# Step 2: copy plugins
GST_SRC="$(brew --prefix gstreamer)/lib/gstreamer-1.0"
for plugin in \
  libgstcoreelements libgstapp \
  libgstrtsp libgstrtp libgstrtpmanager \
  libgstvideoconvertscale libgstvideorate \
  libgstisomp4 libgstjpeg \
  libgstwebrtc libgstsctp \
  libgstvideoparsersbad libgstapplemedia libgstlibav libgstudp libgstdtls libgstsrtp; do
  if [ -f "$GST_SRC/${plugin}.dylib" ]; then
    cp "$GST_SRC/${plugin}.dylib" "$PLUGIN_DIR/"
  else
    found=$(find -L "$BREW" -name "${plugin}.dylib" 2>/dev/null | head -1)
    [ -n "$found" ] && cp "$found" "$PLUGIN_DIR/" || echo "WARNING: $plugin not found"
  fi
done

# libgstnice lives in libnice-gstreamer, not the main gstreamer formula
nice_src=$(find -L /opt/homebrew/Cellar/libnice-gstreamer -name "libgstnice.dylib" 2>/dev/null | head -1)
if [ -f "$nice_src" ]; then
  cp "$nice_src" "$PLUGIN_DIR/"
  while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*)
        depname=$(basename "$dep")
        [ -f "$LIB_DIR/$depname" ] && continue
        [ -f "$dep" ] && cp "$dep" "$LIB_DIR/" && echo "  nice dep: $depname" ;;
    esac
  done < <(otool -L "$nice_src" | tail -n +2 | awk '{print $1}')
else
  echo "WARNING: libgstnice not found — WebRTC ICE will not work"
fi

# libusrsctp is a direct dep of libgstsctp but lives in its own formula
usrsctp=$(find "$BREW" -name "libusrsctp.*.dylib" -not -name "libusrsctp.dylib" 2>/dev/null | head -1)
[ -n "$usrsctp" ] \
  && cp "$usrsctp" "$LIB_DIR/" && echo "  copied: $(basename "$usrsctp")" \
  || echo "WARNING: libusrsctp not found"

# Step 3: resolve @loader_path/../lib/ deps from each plugin's original Homebrew location
for plugin in "$PLUGIN_DIR"/*.dylib; do
  plugin_name=$(basename "$plugin")
  orig=$(find "$BREW" -name "$plugin_name" 2>/dev/null | head -1)
  [ -z "$orig" ] && continue
  orig_real=$(realpath "$orig" 2>/dev/null || echo "$orig")
  orig_lib="$(cd "$(dirname "$orig_real")/.." 2>/dev/null && pwd)/lib"
  while IFS= read -r dep; do
    [[ "$dep" != @loader_path/../lib/* ]] && continue
    libname="${dep#@loader_path/../lib/}"
    [ -f "$LIB_DIR/$libname" ] && continue
    if [ -f "$orig_lib/$libname" ]; then
      cp "$orig_lib/$libname" "$LIB_DIR/" && echo "  dep: $libname"
    else
      found=$(find "$BREW" -name "$libname" -not -path "*/gstreamer-1.0/*" 2>/dev/null | head -1)
      [ -n "$found" ] && cp "$found" "$LIB_DIR/" && echo "  dep (fallback): $libname"
    fi
  done < <(otool -L "$orig_real" | awk '{print $1}')
done

# Step 4: rewrite all install names to relocatable paths
chmod -R u+w "$LIB_DIR" "$PLUGIN_DIR"

for f in "$LIB_DIR"/*.dylib; do
  libname=$(basename "$f")
  install_name_tool -id "@executable_path/gstreamer/lib/$libname" "$f"
  while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*)
        install_name_tool -change "$dep" \
          "@executable_path/gstreamer/lib/$(basename "$dep")" "$f" 2>/dev/null || true ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done

for f in "$PLUGIN_DIR"/*.dylib; do
  plugname=$(basename "$f")
  install_name_tool -id "@loader_path/../plugins/$plugname" "$f"
  while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*)
        install_name_tool -change "$dep" \
          "@loader_path/../lib/$(basename "$dep")" "$f" 2>/dev/null || true ;;
      @rpath/*)
        install_name_tool -change "$dep" \
          "@loader_path/../lib/$(basename "$dep")" "$f" 2>/dev/null || true ;;
    esac
  done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
done

# Step 5: transitive closure — keep copying missing deps until nothing new is added
echo "==> Resolving transitive deps..."
changed=1
while [ "$changed" -eq 1 ]; do
  changed=0
  for f in "$LIB_DIR"/*.dylib "$PLUGIN_DIR"/*.dylib; do
    [ -f "$f" ] || continue
    while IFS= read -r dep; do
      case "$dep" in
        @executable_path/gstreamer/lib/*) libname="${dep#@executable_path/gstreamer/lib/}" ;;
        @loader_path/../lib/*)            libname="${dep#@loader_path/../lib/}" ;;
        *) continue ;;
      esac
      [ -f "$LIB_DIR/$libname" ] && continue
      found=$(find -L "$BREW" -name "$libname" -not -path "*/gstreamer-1.0/*" 2>/dev/null | head -1)
      if [ -n "$found" ]; then
        cp "$found" "$LIB_DIR/"
        chmod u+w "$LIB_DIR/$libname"
        install_name_tool -id "@executable_path/gstreamer/lib/$libname" "$LIB_DIR/$libname"
        while IFS= read -r ldep; do
          case "$ldep" in
            /opt/homebrew/*|/usr/local/*)
              install_name_tool -change "$ldep" \
                "@executable_path/gstreamer/lib/$(basename "$ldep")" \
                "$LIB_DIR/$libname" 2>/dev/null || true ;;
          esac
        done < <(otool -L "$found" | tail -n +2 | awk '{print $1}')
        codesign -f -s - "$LIB_DIR/$libname" 2>/dev/null || true
        echo "  transitive: $libname"
        changed=1
      fi
    done < <(otool -L "$f" | tail -n +2 | awk '{print $1}')
  done
done

# ── Ad-hoc re-sign all bundled dylibs ─────────────────────────────────────────
echo "==> Re-signing dylibs..."
for f in "$LIB_DIR"/*.dylib "$PLUGIN_DIR"/*.dylib; do
  codesign -f -s - "$f" 2>/dev/null || true
done

echo "=== PLUGINS ($(ls "$PLUGIN_DIR" | wc -l | tr -d ' ') files) ==="
ls -1 "$PLUGIN_DIR"
echo "=== LIBS ($(ls "$LIB_DIR" | wc -l | tr -d ' ') files) ==="

# ── Stage sidecar ─────────────────────────────────────────────────────────────
echo "==> Staging sidecar..."
mkdir -p edge/target/release
cp "$EDGE_BIN" edge/target/release/edge-os-edge-aarch64-apple-darwin

# ── Build Tauri app ────────────────────────────────────────────────────────────
echo "==> Building Tauri app..."
(cd app && APPLE_SIGNING_IDENTITY='-' npm run build -- --target aarch64-apple-darwin --bundles app)

# ── Strip Hardened Runtime + build DMG ────────────────────────────────────────
echo "==> Building DMG..."
BUNDLE="app/src-tauri/target/aarch64-apple-darwin/release/bundle"
APP="$BUNDLE/macos/EdgeOS.app"
DMG_DIR="$BUNDLE/dmg"
DMG="$DMG_DIR/EdgeOS_aarch64.dmg"
mkdir -p "$DMG_DIR"

codesign --force --sign - "$APP/Contents/MacOS/edge-os-edge"
find "$APP/Contents/Resources/gstreamer" -name "*.dylib" \
  -exec codesign --force --sign - {} \;
codesign --force --sign - "$APP"

STAGING=$(mktemp -d)
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "EdgeOS" -srcfolder "$STAGING" -ov -format UDZO "$DMG"
rm -rf "$STAGING"

echo ""
echo "✓ DMG ready: $DMG"
