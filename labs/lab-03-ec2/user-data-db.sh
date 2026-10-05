#!/bin/bash
# USMS data tier bootstrap. Runs once at first boot via cloud-init.
# Idempotent: refuses to run twice by checking for a marker file.
MARKER=/var/log/usms-db-bootstrap.done
[ -f "$MARKER" ] && { echo "already bootstrapped, exiting"; exit 0; }

exec > /var/log/usms-db-bootstrap.log 2>&1
set -x

dnf -y install postgresql15-server
postgresql-setup --initdb
systemctl enable --now postgresql
sudo -u postgres psql -c "CREATE DATABASE usms;"

TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
IID=$(curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
  http://169.254.169.254/latest/meta-data/instance-id)

echo "$IID $(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$MARKER"