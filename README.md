# sle-micro-os-lifecycle

In-place OS patching for SUSE Linux Micro nodes in Rancher-provisioned RKE2/K3s clusters (Harvester machine pools). Rancher's Fleet ships the patch plans, the System Upgrade Controller (SUC) runs them, and a gate script decides when the cluster is safe for a Kubernetes upgrade.

Status: prototype. Nothing here has been run against a live cluster.

## How it works

1. **Plans.** `fleet/base/plans.yaml` defines three SUC `Plan`s that run in order: `os-patch-etcd`, then `os-patch-cp` (control plane without etcd), then `os-patch-workers`. The second and third plans block in a `prepare` step (`wait-plan.sh`) until the previous group has finished. Nodes are cordoned and drained one at a time (two for workers).
2. **Upgrade job.** `fleet/base/scripts/upgrade.sh` runs on the host through `chroot /host`. It checks SCC registration and btrfs free space, runs `transactional-update`, records `<release> <snapshot id>` in `/var/lib/os-upgrade/state`, and reboots. After the reboot SUC re-runs the job, which verifies the new snapshot, the k3s/rke2 service and `health-checker`, then exits 0 so SUC uncordons the node. If the booted snapshot is not the expected one (a rollback), the job fails and the node stays cordoned.
3. **Inventory.** The `os-inventory` DaemonSet labels each node every 10 minutes with `os-version`, `rpm-fp` (a hash of the installed RPM list) and `os-release` under the label prefix. It reads the host directly, so it also catches out-of-band changes.
4. **Waves.** `fleet/fleet.yaml` selects clusters by the Rancher label `os-lifecycle/wave=canary|prod`. Each overlay sets `spec.version` on all plans. Changing that value starts a rollout.
5. **Gate.** `tools/gate.sh` passes only when every plan has finished on all of its nodes, all nodes share one `rpm-fp`, and no node is cordoned. `bump` then sets `kubernetesVersion` on the Rancher provisioning cluster, and Rancher runs the Kubernetes upgrade.

## Images

No custom image. Script bodies live in `fleet/base/scripts/`. Kustomize turns them into the `os-scripts` ConfigMap, which the inventory DaemonSet mounts. Plans cannot mount a ConfigMap, so kustomize copies the script text into env values on each Plan (`UPGRADE_SCRIPT`, `WAIT_SCRIPT`). Editing a script therefore changes the Plan spec and hash.

- `dp.apps.rancher.io/containers/kubectl:1.37.2` (bci-micro based, uid 1000, no `awk` or `grep`): `prepare` step and inventory DaemonSet
- `registry.suse.com/bci/bci-micro:15.7`: `upgrade` step. It only needs `sh`, `mkdir` and `chroot`, and runs as root.

## Layout

```
cloud-init/   user data for the Harvester machine pool (disables self-patching)
fleet/        Fleet bundle: base manifests, scripts/, canary and prod overlays
tools/        gate.sh
```

## Setup

1. Create the pull secret for `dp.apps.rancher.io` as `dp-apps-rancher-io` in `cattle-system` on each downstream cluster. Both ServiceAccounts reference it. Keep the credentials out of Git.
2. Add `cloud-init/harvester-machine-pool-userdata.yaml` to the machine pool's User Data in Rancher. It disables `transactional-update.timer` and `rebootmgr` so the Plans are the only thing patching nodes. Register nodes with SCC through a secret-backed template. Do not put the registration code in Git.
3. Point a Fleet GitRepo on the Rancher `local` cluster at `fleet/`.
4. Label downstream clusters in Rancher with `os-lifecycle/wave=canary` or `os-lifecycle/wave=prod`.
5. Set `LABEL_PREFIX` in `fleet/base/inventory.yaml` and in your shell when running `gate.sh`. The default is `os-lifecycle`.

## Releasing

Release ids look like `2026.45-1`. Prod should trail canary.

1. Edit the version in `fleet/overlays/canary/kustomization.yaml` and commit. Fleet rolls it out to canary clusters.
2. When the canary plans finish, confirm convergence:

   ```bash
   tools/gate.sh check <canary-kubeconfig>
   ```

3. Set the same version in `fleet/overlays/prod/kustomization.yaml` and commit.
4. After prod converges, optionally request a Kubernetes upgrade through the gate:

   ```bash
   tools/gate.sh bump <downstream-kubeconfig> <rancher-kubeconfig> <cluster-name> <k8s-version>
   ```

Set `MODE` to `patch` in the Plan envs for security-only updates. The default `up` applies all updates.

## Failure behavior

- **Unregistered system or less than 3 GiB free on `/`:** the job fails before touching anything.
- **Rollback by `health-checker`:** the job fails and the node stays cordoned until someone looks at it.
- **Pending snapshot from an earlier run:** the job logs a warning and builds on the current snapshot.
- **Gate closed:** `gate.sh bump` exits 1 and changes nothing.

## Requirements

- SUSE Linux Micro nodes with `transactional-update`, btrfs and `SUSEConnect`
- RKE2 or K3s with the System Upgrade Controller installed in `cattle-system`
- Rancher with Fleet, and `kubectl` access to both Rancher and the downstream clusters
