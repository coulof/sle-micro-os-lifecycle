#!/bin/sh
# DaemonSet loop: publish OS facts as node labels for drift detection.
# Independent of the upgrade path, so it also catches out-of-band changes.
set -eu
PREFIX="${LABEL_PREFIX:-os-lifecycle}"
INTERVAL="${INTERVAL:-600}"
: "${NODE_NAME:?}"

while :; do
  ver=$(. /host/etc/os-release && echo "${VERSION_ID:-unknown}")
  fp=$(chroot /host rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}.%{ARCH}\n' | sort | sha256sum | cut -c1-16)
  rel=none
  [ -f /host/var/lib/os-upgrade/state ] && read -r rel _ < /host/var/lib/os-upgrade/state

  kubectl label node "$NODE_NAME" --overwrite \
    "$PREFIX/os-version=$ver" \
    "$PREFIX/rpm-fp=$fp" \
    "$PREFIX/os-release=$rel" >/dev/null
  echo "[inventory] $NODE_NAME version=$ver fp=$fp release=$rel"
  sleep "$INTERVAL"
done
