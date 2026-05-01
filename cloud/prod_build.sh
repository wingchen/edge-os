#!/bin/bash
set -e

rm -f edge_os_cloud.tar.xz

# build
docker build --platform linux/amd64 -t edge_os_cloud .

# get the binary
docker create --name edgeos-extract edge_os_cloud
docker cp edgeos-extract:/app/. ./edge_os_cloud/
docker rm edgeos-extract

# zip the payload
tar -cJf edge_os_cloud.tar.xz edge_os_cloud/
rm -rf edge_os_cloud

echo 'scp-ing to prod server...'
scp edge_os_cloud.tar.xz root@edgeos.sailoi.com:/opt/edgeos
