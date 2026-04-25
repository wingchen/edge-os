#!/bin/bash
set -e

rm -rf edge_os_cloud_bak && mv edge_os_cloud edge_os_cloud_bak && tar -xf edge_os_cloud.tar.xz
systemctl restart edge-os
