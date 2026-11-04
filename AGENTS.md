# AGENTS.md

SUSE Linux Micro OS patching for Rancher-managed clusters: Fleet + System Upgrade Controller Plans, scripts shipped as a kustomize-generated ConfigMap, one gate script. See README.md for the design.

Not a git repo yet. No test suite, no CI.

## Layout

- `fleet/base/` shared manifests: `plans.yaml`, `rbac.yaml`, `inventory.yaml`
- `fleet/overlays/{canary,prod}/` each patches `spec.version` on every Plan
- `fleet/fleet.yaml` maps the `os-lifecycle/wave` cluster label to an overlay
- `fleet/base/scripts/` `upgrade.sh`, `wait-plan.sh`, `inventory.sh`
- `tools/gate.sh` run by an operator, not in-cluster
- `cloud-init/` machine pool user data

## Checks

Run what exists; none of this is wired into automation.

```bash
kubectl kustomize fleet/overlays/canary
kubectl kustomize fleet/overlays/prod
sh -n fleet/base/scripts/*.sh tools/gate.sh
shellcheck fleet/base/scripts/*.sh tools/gate.sh   # if installed
```

## Rules

- All scripts are POSIX `sh` with `set -eu`. No bashisms. `wait-plan.sh` and `inventory.sh` run on the kubectl image, which has no `awk` or `grep`; use shell builtins, `sed`, `cut`, `sort`, `wc`, `tr`. `upgrade.sh` runs inside a chroot on the host, so use only what SL Micro ships there (`btrfs`, `transactional-update`, `systemctl`, `SUSEConnect`, `awk`).
- `upgrade.sh` must stay idempotent. It is re-run after every reboot and on job retry. State lives in `/var/lib/os-upgrade/state` as `<release> <snapshot id>`. Do not change that format without handling the old one.
- Scripts reach Plans through `replacements` in `fleet/base/kustomization.yaml`, not a mounted file. Rebuild both overlays after any change and confirm `UPGRADE_SCRIPT` and `WAIT_SCRIPT` are filled. `os-patch-etcd` has no `prepare` and is rejected from the `WAIT_SCRIPT` replacement; keep it that way.
- Image references (`dp.apps.rancher.io/containers/kubectl`, `bci-micro`) repeat across the three Plans and `inventory.yaml`. Change them together.
- Plan ordering relies on `wait-plan.sh` and its selector arguments. If you change a plan's `nodeSelector`, update the matching selector in the next plan's `prepare.args` and in `plan_selector()` in `gate.sh`.
- The label prefix (`platform.example.com`) appears in `inventory.yaml`, `inventory.sh` and `gate.sh`. Keep them equal.
- Plans carry the base `spec.version` `0000.00-0`. Only overlays set the real release. Do not set a real version in base.
- Prod must never run a newer release than canary. When editing overlays, check both values.
- Never write an SCC registration code, kubeconfig or token into any file here. `cloud-init/` is intentionally free of the regcode.
- A script change alters the Plan spec, so SUC re-cordons and drains every node even when the release id is unchanged. `upgrade.sh` then sees the state file and only verifies.
- The `dp.apps.rancher.io` pull secret (`dp-apps-rancher-io`) is created out-of-band and referenced from the ServiceAccounts. Never commit it.

## Before editing

- Ask before running `gate.sh bump` or anything that touches a real cluster. `bump` patches a Rancher cluster and starts a Kubernetes upgrade.
- The label prefix is a placeholder. Don't change it to a real value without being told.
- Comments in these files are terse and explain why, not what. Match that.
