#!/bin/bash
set -e

cp edge-os.service /etc/systemd/system/
systemctl start edge-os
systemctl enable edge-os
