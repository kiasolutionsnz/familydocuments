#!/bin/sh
set -eu
mkdir -p /tmp/signatures
cp /var/lib/clamav/*.cvd /tmp/signatures/
freshclam --config-file=/test/freshclam.conf --datadir=/tmp/signatures --stdout
exec clamd --config-file=/test/clamd.conf --fail-if-cvd-older-than=2
