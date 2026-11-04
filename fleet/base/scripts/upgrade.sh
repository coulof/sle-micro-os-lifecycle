#!/bin/sh
# Runs ON THE HOST (via chroot /host) inside a System Upgrade Controller job pod.
# Converge loop: apply -> reboot -> (SUC re-runs job) -> verify -> exit 0 -> SUC uncordons.
# Idempotent: safe to re-run at any point.
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin

MODE="${MODE:-up}"                                   # up | patch
RELEASE="${SYSTEM_UPGRADE_PLAN_LATEST_VERSION:?missing plan version}"
STATE_DIR=/var/lib/os-upgrade
STATE="$STATE_DIR/state"                             # "<release> <target_snapshot_id>"
MIN_FREE_BYTES="${MIN_FREE_BYTES:-3221225472}"       # 3 GiB

log() { echo "[os-upgrade] $*"; }

current_id() { btrfs subvolume show / | awk '/Subvolume ID:/{print $3}'; }
default_id() { btrfs subvolume get-default / | awk '{print $2}'; }

k8s_service() {
  for s in rke2-server rke2-agent k3s k3s-agent; do
    if systemctl is-enabled -q "$s" 2>/dev/null; then echo "$s"; return 0; fi
  done
  return 1
}

preflight() {
  if ! SUSEConnect --status 2>/dev/null | grep -q '"status":"Registered"'; then
    log "ERROR: system not registered with SCC"; return 1
  fi
  free=$(btrfs filesystem usage -b / | awk '/Free \(estimated\):/{print $3}')
  if [ "${free:-0}" -lt "$MIN_FREE_BYTES" ]; then
    log "ERROR: insufficient btrfs free space (${free:-0} < $MIN_FREE_BYTES)"; return 1
  fi
  if systemctl is-active -q transactional-update.timer 2>/dev/null; then
    log "WARN: transactional-update.timer is active -> uncoordinated updates possible"
  fi
  return 0
}

verify() {
  # shellcheck disable=SC1091
  . /etc/os-release
  log "OS: ${PRETTY_NAME:-unknown}, snapshot $(current_id)"
  svc=$(k8s_service) || { log "ERROR: no k3s/rke2 service enabled"; return 1; }
  i=0
  until systemctl is-active -q "$svc"; do
    i=$((i + 1)); [ "$i" -ge 60 ] && { log "ERROR: $svc not active"; return 1; }
    sleep 5
  done
  if systemctl is-failed -q health-checker.service 2>/dev/null; then
    log "ERROR: health-checker reports failure"; return 1
  fi
  return 0
}

reboot_host() {
  log "rebooting into snapshot $(default_id)"
  sync
  systemd-run --on-active=10 --timer-property=AccuracySec=1s /usr/bin/systemctl reboot
  sleep 900          # pod is killed by the reboot; job is retried after boot
  exit 1
}

mkdir -p "$STATE_DIR"
cur=$(current_id)
def=$(default_id)

# 1) Already worked on this release? -> verify / finish reboot / detect rollback
if [ -f "$STATE" ]; then
  read -r st_rel st_snap < "$STATE"
  if [ "$st_rel" = "$RELEASE" ]; then
    if [ "$cur" = "$st_snap" ]; then
      verify && { log "release $RELEASE active"; exit 0; }
      exit 1
    fi
    if [ "$def" = "$st_snap" ]; then
      reboot_host                                   # applied, not yet booted
    fi
    log "ERROR: booted $cur, expected $st_snap (rolled back by health-checker?). Node stays cordoned."
    exit 1
  fi
fi

# 2) New release for this node
preflight || exit 1
[ "$def" != "$cur" ] && log "WARN: pending snapshot $def found from an earlier run; building on current $cur"

log "applying release $RELEASE: transactional-update --non-interactive $MODE"
transactional-update --non-interactive "$MODE"
new=$(default_id)

if [ "$new" = "$cur" ]; then
  echo "$RELEASE $cur" > "$STATE"
  log "no changes for release $RELEASE"
  verify && exit 0
  exit 1
fi

echo "$RELEASE $new" > "$STATE"
reboot_host
