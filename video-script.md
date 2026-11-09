# SL Micro lifecycle demo: video script

**Working title:** One cluster, two OS lifecycles: patching and upgrading SL Micro under K3s, driven from Rancher
**Target length:** 7–8 minutes (after time-lapse editing)
**Audience:** platform engineers and architects who know Kubernetes and Rancher
**Recording setup:** one 4K screen, four quadrants, voice-over recorded live or in post

---

## Screen layout

```
┌───────────────────────────────────┬───────────────────────────────────┐
│ TOP LEFT                          │ TOP RIGHT                         │
│ Rancher › Cluster Management      │ Heartbeat page                    │
│ (machines / machine pool)         │ (who answered, OK/FAIL timeline)  │
├───────────────────────────────────┼───────────────────────────────────┤
│ BOTTOM LEFT                       │ BOTTOM RIGHT                      │
│ viddy -d -n 2 ./watch-nodes.sh    │ stern … -c upgrade (patch)        │
│   --patch  or  --bump             │ or kubectl get pods -o wide       │
└───────────────────────────────────┴───────────────────────────────────┘
```

| Quadrant | Patch segment | Distribution bump segment |
|---|---|---|
| Top left | Rancher cluster view (nodes stay the same) | Rancher › Cluster Management › Machines (VMs created and deleted) |
| Top right | Heartbeat | Heartbeat |
| Bottom left | `viddy -d -n 2 ./watch-nodes.sh --patch` | `viddy -d -n 2 ./watch-nodes.sh --bump` |
| Bottom right | `stern -n cattle-system -l upgrade.cattle.io/plan -c upgrade --since 1m` | `viddy -d -n 2 kubectl get pods -n heartbeat -o wide` |

---

## Before recording: checklist

**Cluster**

- [ ] 3 nodes Ready on SL Micro 6.1, all patched to the **same older level** so the weekly patch has something to install
- [ ] SL Micro 6.2 cloud image uploaded to SUSE Virtualization, ready to pick in the machine pool
- [ ] Traefik at 2 replicas on different nodes (`HelmChartConfig`)
- [ ] Entry point is a single stable IP (MetalLB VIP, or VyOS pointing to it), not node IPs
- [ ] Heartbeat deployed (3 replicas, PDB), page open and green
- [ ] OS patch Plans installed with a version that is **already applied**, so nothing runs until you bump it
- [ ] On every node: `transactional-update.timer` and `rebootmgr` disabled (no surprise reboots during a take)
- [ ] A full dry run of both segments done, with timings noted

**Screen**

- [ ] Terminal font about 20 pt, Pine-coloured background, no shell prompt clutter
- [ ] Browser zoom so the Rancher table and the heartbeat timeline are readable at 1080p
- [ ] Notifications off, no other tabs or bookmarks bar visible
- [ ] Nothing sensitive on screen: no kubeconfigs, tokens, registration codes, internal hostnames you don't want published
- [ ] A clock visible somewhere (terminal timestamps are enough) so time-lapses stay honest

**Capture**

- [ ] Screen recorder at 4K, 30 fps
- [ ] `asciinema rec` running in each terminal as a backup you can re-render
- [ ] Microphone level checked

---

## Sequence overview

| # | Segment | Screen | Target time |
|---|---|---|---|
| 1 | Hook | Title / diagram | 0:00–0:30 |
| 2 | Two kinds of OS change | Side-by-side slide | 0:30–1:15 |
| 3 | Starting state | 4 quadrants | 1:15–1:45 |
| 4 | Patch: trigger | Git / terminal | 1:45–2:15 |
| 5 | Patch: rollout | 4 quadrants, time-lapse | 2:15–3:45 |
| 6 | Patch: result | Bottom left + node shell | 3:45–4:15 |
| 7 | Bump: trigger | Rancher machine pool edit | 4:15–4:45 |
| 8 | Bump: rollout | 4 quadrants, time-lapse | 4:45–6:00 |
| 9 | Bump: result | Bottom left | 6:00–6:30 |
| 10 | Closing | Comparison / next steps | 6:30–7:15 |

---

## 1. Hook (0:00–0:30)

**On screen:** title card, then a simple diagram: "OS lifecycle" and "Kubernetes lifecycle" as two separate boxes, then merging into one.

**Voice-over**

> When you upgrade OpenShift, the operating system comes along: CoreOS and the cluster move together, node by node.
> With K3s and RKE2 on SL Micro, those two lifecycles are separate today.
> In this video I'll show how we can drive SL Micro's lifecycle from Rancher, the same way we drive Kubernetes, on a live cluster, while an application keeps answering.

**Presenter notes**

- Keep it short. The point is the problem statement, not OpenShift.
- Don't promise "zero downtime". The promise is "the service keeps answering".

---

## 2. Two kinds of OS change (0:30–1:15)

**On screen:** the side-by-side slide: *Patch management* vs *Distribution bump*.

**Voice-over**

> Not every OS change is the same.
> On the left, the weekly patch. We stay on the same VM. `transactional-update` builds a new btrfs snapshot in the background, the node is drained, it reboots into the snapshot, and it's back. If anything goes wrong, we boot the previous snapshot.
> On the right, the distribution bump, twice a year, for example 6.1 to 6.2. Here SUSE recommends a fresh install, and on SUSE Virtualization a fresh install is cheap: we point the machine pool at the new SL Micro image and Rancher replaces the nodes one by one.
> Two mechanisms, one goal: every node on the same version, driven from Rancher.

**Presenter notes**

- Point left, then right. Pause on "rollback" for each side; it's the strongest difference.
- The speaker notes on the slide have the same text if you want to read from there.

---

## 3. Starting state (1:15–1:45)

**On screen:** all four quadrants.

**Voice-over**

> Here's the cluster. Three SL Micro 6.1 nodes on SUSE Virtualization, managed by Rancher, top left.
> Top right is a small heartbeat page. It asks the cluster "who's there?" every second. Green means it got an answer, and it shows which pod and which node replied.
> Bottom left, each node: status, kernel, boot ID, and where it is in the upgrade. Right now everything is Ready and up to date.

**Presenter notes**

- Point at the heartbeat timeline: all green, several pods answering from different nodes.
- Point at the BOOT column and say you'll come back to it. It's the reboot proof.
- All three nodes hold every role (control plane, etcd, worker), so they'll be upgraded strictly one at a time. Say it here so nobody expects parallel workers later.

---

## 4. Patch: trigger (1:45–2:15)

**On screen:** terminal or Git UI showing the one-line change, then the commit.

**Action:** bump the Plan version in the canary overlay (`2026.45-1` → `2026.45-2`) and push. Fleet delivers it to the cluster.
*Dry-run fallback if Fleet isn't wired yet: `kubectl -n cattle-system patch plan … --type merge -p '{"spec":{"version":"…"}}'` on each Plan.*

**Voice-over**

> To start the weekly patch, I change one value: the release ID of the OS Plan. That's a Git commit.
> Fleet delivers it to the cluster, and the System Upgrade Controller takes it from there.

**Presenter notes**

- Show the diff, not the whole file. One line changing is the message.
- Don't explain Fleet in detail. "Git commit, Fleet delivers it" is enough.

---

## 5. Patch: rollout (2:15–3:45), time-lapse

**On screen:** all four quadrants. Switch the bottom right to `stern` as soon as the first upgrade pod starts.

**What to point at, in order**

1. Bottom left: first node goes `Ready,Cordoned`, PLAN `applying`
2. Bottom right: `transactional-update` output, packages installed into the new snapshot
3. Top right: heartbeat stays green; answers now come only from the other two nodes
4. Bottom left: node goes `NotReady`, then `Ready` again with a **new BOOT ID** (and a new kernel if the patch had one), PLAN `done`
5. Next node starts, same pattern

**Voice-over**

> The controller picks the first node and cordons it, so no new work lands there, then drains it.
> Meanwhile, on the node, `transactional-update` installs the updates into a new snapshot. The running system isn't touched yet.
> The heartbeat page is still green. The answers just come from the other two nodes now.
> Here's the reboot. The node is NotReady for a moment, then back, and look at the boot ID: it changed. It booted into the new snapshot.
> The script checks the node is healthy before it lets the controller uncordon it, and then the next node starts.

*(Time-lapse the second and third nodes.)*

> Same thing for the second node, and the third. One at a time.

**Presenter notes**

- If you see one or two orange ticks on the heartbeat when a node reboots: **say so**. "That's a request that hit the node as it went down. The service itself didn't stop." It's more credible than hiding it.
- Show a timestamp before and after each time-lapse cut, so viewers know time was compressed.
- If the kernel column changes, call it out. If it doesn't, rely on BOOT: "same kernel this week, but you can see it rebooted into the new snapshot."

---

## 6. Patch: result (3:45–4:15)

**On screen:** bottom left full width; optionally a short cut to a node shell showing `snapper list`.

**Voice-over**

> All three nodes are done. Same VMs, new snapshot on each, new boot IDs, and the service answered throughout.
> And if a patch ever breaks a node, the health check fails and the node simply stays cordoned on its previous snapshot. The rollout stops there.

**Presenter notes**

- `snapper list` is optional but strong: it shows the old and new snapshots side by side. Only show it if the shell has nothing sensitive on screen.
- Mention the failure behaviour in one sentence. Don't demo it in this video.

---

## 7. Distribution bump: trigger (4:15–4:45)

**On screen:** top left enlarged: Rancher › Cluster Management › edit the cluster › machine pool › change the image from SL Micro 6.1 to 6.2 › Save.
Switch the bottom left to `watch-nodes.sh --bump`.

**Voice-over**

> Now the twice-a-year upgrade: SL Micro 6.1 to 6.2.
> In the machine pool, I switch the image to the new SL Micro 6.2 image and save. That's it. The same change could be a Terraform diff.

**Presenter notes**

- Zoom into the image field so the version change is readable.
- Say "or Terraform" once; that's the GitOps-minded audience's question.

---

## 8. Distribution bump: rollout (4:45–6:00), time-lapse

**On screen:** all four quadrants.

**What to point at, in order**

1. Top left: a new VM appears, provisioning
2. Bottom left: a new node joins at the bottom of the list with **SL Micro 6.2**
3. Bottom right: heartbeat pods rescheduled onto the new node
4. Top left and bottom left: an old 6.1 node is drained and deleted, and disappears from the top of the list
5. Top right: heartbeat stays green throughout
6. Repeat until all three are replaced

**Voice-over**

> Rancher creates a new VM from the 6.2 image. It joins the cluster, and here it is at the bottom of the list: SL Micro 6.2.
> Then Rancher drains one of the old nodes and deletes it. The workload moves to the new node.
> No in-place migration, no long package transaction. Just new nodes replacing old ones.

*(Time-lapse the remaining two replacements.)*

> And again for the next one. The heartbeat page hasn't stopped answering.

**Presenter notes**

- The entry point is a single floating IP, so new node IPs don't matter. Worth one sentence if you show the VIP: "the address users hit never changed, even though every node IP did."
- Expect a short pause when the node holding the floating IP is deleted. Same rule as before: say it if you see it.
- Keep the Rancher machines list visible; it's the most intuitive view of this segment.

---

## 9. Distribution bump: result (6:00–6:30)

**On screen:** bottom left full width, summary line visible: `3 nodes · SL Micro 6.2: 3`.

**Voice-over**

> Three new nodes, all on SL Micro 6.2, new kernel, and the same cluster and application as before.

**Presenter notes**

- Hold this shot for two or three seconds without talking. It's the "after" picture.

---

## 10. Closing (6:30–7:15)

**On screen:** comparison table, then next steps.

| | Weekly patch | Distribution bump |
|---|---|---|
| Trigger | Git commit (Plan version) | Machine pool image (UI or Terraform) |
| Mechanism | `transactional-update`, btrfs snapshot | New VM from the new image |
| Node | Same VM, drain → reboot → uncordon | New VM joins, old VM removed |
| Rollback | Boot the previous snapshot | Pool back to the previous image |

**Voice-over**

> So: two kinds of OS change, two mechanisms, and in both cases the cluster and the application kept going.
> Next step is to put both behind one release definition, the way OpenShift does, so the OS version and the Kubernetes version move together.
> The blog post linked below has the details: the upgrade Plans, the trade-offs, and what's still to do.

**Presenter notes**

- Keep "next step" honest. It's a direction, not a product feature.
- End on the link, not on a summary of everything.

---

## Between takes: reset

- **Patch segment:** to re-run, nodes need pending updates again. Either keep a node snapshot from before the patch to roll back to, or record the patch segment only once after a full dry run.
- **Bump segment:** to re-run, switch the machine pool back to the 6.1 image and let Rancher replace the nodes again. Budget the full replacement time.
- Restart the heartbeat page after each take so the counters and timeline start clean.

## B-roll and inserts (optional)

- Close-up of the Plan diff (segment 4)
- `snapper list` on a node after the patch (segment 6)
- Machine pool image dropdown (segment 7)
- The side-by-side slide again over the closing (segment 10)
