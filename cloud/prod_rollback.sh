#!/bin/bash
set -e

if [ ! -d edge_os_cloud_bak ]; then
  echo "No backup found (edge_os_cloud_bak does not exist). Cannot rollback."
  exit 1
fi

echo "Rolling back to previous release..."
rm -rf edge_os_cloud && mv edge_os_cloud_bak edge_os_cloud
systemctl restart edge-os

echo "Rollback complete."
journalctl -u edge-os -f
