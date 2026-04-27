#!/bin/bash
# Installs the EdgeOS edge agent as a systemd system service on Linux desktop.
# Run with sudo after installing the EdgeOS app.
#
# TODO (Phase 2E): fold this into the .deb postinst script so it runs
# automatically on package install.

set -e

EDGE_DIR="/opt/edge-os-edge"
EDGE_BINARY="$EDGE_DIR/edge-os-edge"
SERVICE="/etc/systemd/system/edge-os.service"

if [ "$(id -u)" -ne 0 ]; then
    echo "ERROR: run with sudo" >&2
    exit 1
fi

# Locate the installed edge binary
APP_BINARY=$(find /opt/EdgeOS -name "edge-os-edge-*-linux-*" 2>/dev/null | head -1)
if [ -z "$APP_BINARY" ]; then
    echo "ERROR: edge-os-edge binary not found under /opt/EdgeOS" >&2
    exit 1
fi

mkdir -p "$EDGE_DIR"
cp "$APP_BINARY" "$EDGE_BINARY"
chmod 755 "$EDGE_BINARY"

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

echo "EdgeOS daemon installed and started."
