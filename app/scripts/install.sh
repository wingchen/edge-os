#!/bin/bash
# EdgeOS one-command install script for headless Linux.
# Usage: curl -sSL https://get.edgeos.io | bash
#        or: sudo bash install.sh
#
# What this does:
#   1. Detects the package manager and installs GStreamer system packages
#   2. Downloads and installs the edge-os-edge binary
#   3. Writes the systemd unit and starts the service

set -e

EDGE_DIR="/opt/edge-os-edge"
EDGE_BINARY="$EDGE_DIR/edge-os-edge"
SERVICE="/etc/systemd/system/edge-os.service"
RELEASE_URL="https://github.com/wingchen/edge-os/releases/latest/download/edge-os-edge-linux-x86_64"

# ── Privilege check ────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "Re-running with sudo…"
    exec sudo bash "$0" "$@"
fi

echo "==> EdgeOS installer"

# ── Detect distro and install GStreamer ────────────────────────────────────────
install_gstreamer() {
    if command -v apt-get &>/dev/null; then
        echo "==> Installing GStreamer (apt)"
        apt-get update -qq
        apt-get install -y \
            libgstreamer1.0-0 \
            gstreamer1.0-plugins-base \
            gstreamer1.0-plugins-good \
            gstreamer1.0-plugins-bad \
            gstreamer1.0-nice

    elif command -v dnf &>/dev/null; then
        echo "==> Installing GStreamer (dnf)"
        dnf install -y \
            gstreamer1 \
            gstreamer1-plugins-base \
            gstreamer1-plugins-good \
            gstreamer1-plugins-bad-free \
            libnice

    elif command -v yum &>/dev/null; then
        echo "==> Installing GStreamer (yum)"
        yum install -y \
            gstreamer1 \
            gstreamer1-plugins-base \
            gstreamer1-plugins-good \
            gstreamer1-plugins-bad-free \
            libnice

    elif command -v pacman &>/dev/null; then
        echo "==> Installing GStreamer (pacman)"
        pacman -S --noconfirm \
            gstreamer \
            gst-plugins-base \
            gst-plugins-good \
            gst-plugins-bad

    elif command -v zypper &>/dev/null; then
        echo "==> Installing GStreamer (zypper)"
        zypper install -y \
            gstreamer \
            gstreamer-plugins-base \
            gstreamer-plugins-good \
            gstreamer-plugins-bad \
            libnice10

    else
        echo "WARNING: unknown package manager — skipping GStreamer install."
        echo "         Install these packages manually before starting the service:"
        echo "         gstreamer1.0-plugins-base gstreamer1.0-plugins-good"
        echo "         gstreamer1.0-plugins-bad gstreamer1.0-nice"
    fi
}

install_gstreamer

# ── Install edge binary ────────────────────────────────────────────────────────
echo "==> Installing edge-os-edge binary"
mkdir -p "$EDGE_DIR"
chmod 755 "$EDGE_DIR"

# If a local binary is passed as first argument, use it; otherwise download.
if [ -n "$1" ] && [ -f "$1" ]; then
    echo "    Using local binary: $1"
    cp "$1" "$EDGE_BINARY"
else
    echo "    Downloading from $RELEASE_URL"
    curl -fsSL "$RELEASE_URL" -o "$EDGE_BINARY"
fi

chmod 755 "$EDGE_BINARY"

# ── Write systemd unit ─────────────────────────────────────────────────────────
echo "==> Writing systemd unit"
cat > "$SERVICE" << EOF
[Unit]
Description=EdgeOS Edge Agent
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=$EDGE_BINARY
Restart=always
RestartSec=5
Environment=EDGE_OS_EDGE_DIR=$EDGE_DIR

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable --now edge-os

echo ""
echo "✓ EdgeOS edge agent installed and started."
echo "  Config file : $EDGE_DIR/config.json"
echo "  Logs        : journalctl -u edge-os -f"
echo "  Status      : systemctl status edge-os"
