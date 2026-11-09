#!/usr/bin/env bash
# Node view for the SL Micro lifecycle demo. Oldest node first (new VMs appear at the bottom).
#
#   viddy -t -d -n 2 ./watch-nodes.sh --bump     # distribution bump: OS / kernel / k8s per node
#   viddy -t -d -n 2 ./watch-nodes.sh --patch    # weekly patch: kernel, boot id, ready since, SUC plan progress
#
# -t hides viddy's header (the clock in the top right corner included); the script prints its own title instead.
#
# Env overrides: SUC_NS (cattle-system), PLAN_ETCD / PLAN_CP / PLAN_WORKERS (os-patch-etcd / -cp / -workers)
# Needs only kubectl + sed/awk/column (macOS defaults are fine).

MODE="${1:---bump}"
PREFIX_RE='^slemicro-pool[0-9]*-[a-z0-9]*-'          # slemicro-pool1-rc8l4-2wxhp -> 2wxhp
SUC_NS="${SUC_NS:-cattle-system}"
PLAN_ETCD="${PLAN_ETCD:-os-patch-etcd}"
PLAN_CP="${PLAN_CP:-os-patch-cp}"
PLAN_WORKERS="${PLAN_WORKERS:-os-patch-workers}"

# Common go-template fragments
T_READY='{{$r := "NotReady"}}{{range .status.conditions}}{{if and (eq .type "Ready") (eq .status "True")}}{{$r = "Ready"}}{{end}}{{end}}{{$r}}{{if .spec.unschedulable}},Cordoned{{end}}'
lbl() { printf '{{with index .metadata.labels "%s"}}{{.}}{{end}}' "$1"; }

shorten() { sed -E "s/$PREFIX_RE//; s/SUSE Linux Micro/SL Micro/; s/-default//g"; }

case "$MODE" in
# ---------------------------------------------------------------------------
--bump)
  printf 'Distribution bump\n\n'
  TPL='{{range .items}}{{.metadata.name}}{{"\t"}}'"$T_READY"'{{"\t"}}'\
'{{.status.nodeInfo.osImage}}{{"\t"}}{{.status.nodeInfo.kernelVersion}}{{"\t"}}{{.status.nodeInfo.kubeletVersion}}{{"\n"}}{{end}}'
  rows=$(kubectl get nodes --sort-by=.metadata.creationTimestamp -o go-template="$TPL" 2>&1) || { echo "kubectl: $rows"; exit 0; }
  rows=$(printf '%s\n' "$rows" | shorten)

  { printf 'NODE\tSTATUS\tOS\tKERNEL\tK8S\n'; printf '%s\n' "$rows"; } | column -t -s $'\t'
  echo
  printf '%s\n' "$rows" | awk -F'\t' '
    { n++; os[$3]++; if ($2 ~ /Cordoned/) c++; if ($2 ~ /^NotReady/) nr++ }
    END {
      printf "%d nodes", n
      for (o in os) printf "  ·  %s: %d", o, os[o]
      if (c)  printf "  ·  %d cordoned", c
      if (nr) printf "  ·  %d not ready", nr
      print ""
    }'
  ;;
# ---------------------------------------------------------------------------
--patch)
  printf 'Weekly patch\n\n'
  tmp=$(mktemp -d); trap 'rm -rf "$tmp"' EXIT

  # 1) Plans: name <TAB> latest hash  (empty if SUC / plans not installed)
  kubectl -n "$SUC_NS" get plans.upgrade.cattle.io \
    -o go-template='{{range .items}}{{.metadata.name}}{{"\t"}}{{.status.latestHash}}{{"\n"}}{{end}}' \
    > "$tmp/plans" 2>/dev/null || : > "$tmp/plans"

  # 2) SUC jobs: node <TAB> plan <TAB> state
  kubectl -n "$SUC_NS" get jobs -l upgrade.cattle.io/plan \
    -o go-template='{{range .items}}'"$(lbl upgrade.cattle.io/node)"'{{"\t"}}'"$(lbl upgrade.cattle.io/plan)"'{{"\t"}}{{if .status.active}}applying{{else if .status.succeeded}}succeeded{{else if .status.failed}}failed{{else}}pending{{end}}{{"\n"}}{{end}}' \
    > "$tmp/jobs" 2>/dev/null || : > "$tmp/jobs"

  # 3) Nodes: name, status, kernel, boot id, ready since (UTC), etcd?, cp?, plan labels (etcd, cp, workers)
  TPL='{{range .items}}{{.metadata.name}}{{"\t"}}'"$T_READY"'{{"\t"}}'\
'{{.status.nodeInfo.kernelVersion}}{{"\t"}}{{slice .status.nodeInfo.bootID 0 8}}{{"\t"}}'\
'{{range .status.conditions}}{{if eq .type "Ready"}}{{slice .lastTransitionTime 11 19}}{{end}}{{end}}{{"\t"}}'\
"$(lbl node-role.kubernetes.io/etcd)"'{{"\t"}}'"$(lbl node-role.kubernetes.io/control-plane)"'{{"\t"}}'\
"$(lbl "plan.upgrade.cattle.io/$PLAN_ETCD")"'{{"\t"}}'"$(lbl "plan.upgrade.cattle.io/$PLAN_CP")"'{{"\t"}}'"$(lbl "plan.upgrade.cattle.io/$PLAN_WORKERS")"'{{"\n"}}{{end}}'
  kubectl get nodes --sort-by=.metadata.creationTimestamp -o go-template="$TPL" > "$tmp/nodes" 2>"$tmp/err" \
    || { echo "kubectl: $(cat "$tmp/err")"; exit 0; }

  awk -F'\t' -v OFS='\t' -v PE="$PLAN_ETCD" -v PC="$PLAN_CP" -v PW="$PLAN_WORKERS" \
      -v PF="$tmp/plans" -v JF="$tmp/jobs" -v SUMF="$tmp/summary" '
    FILENAME == PF { hash[$1] = $2; next }
    FILENAME == JF {
      if ($3 == "applying") job[$1] = "applying"
      else if ($3 == "failed" && job[$1] != "applying") job[$1] = "failed"
      next
    }
    {
      # Which plan applies to this node (same split as the Plans: etcd -> cp -> workers)
      if ($6 == "true")      { p = PE; l = $8 }
      else if ($7 == "true") { p = PC; l = $9 }
      else                   { p = PW; l = $10 }
      if (!(p in hash) || hash[p] == "")  st = "-"
      else if (job[$1] == "applying")     st = "applying"
      else if (l == hash[p])              st = "done"
      else if (job[$1] == "failed")       st = "FAILED"
      else                                st = "waiting"
      cnt[st]++; n++
      print $1, $2, $3, $4, $5, st
    }
    END {
      s = n " nodes"
      if (cnt["done"])     s = s "  ·  " cnt["done"] " done"
      if (cnt["applying"]) s = s "  ·  " cnt["applying"] " applying"
      if (cnt["waiting"])  s = s "  ·  " cnt["waiting"] " waiting"
      if (cnt["FAILED"])   s = s "  ·  " cnt["FAILED"] " FAILED"
      if (cnt["-"] == n)   s = s "  ·  no OS patch plan found in the cluster"
      print s > SUMF
    }' "$tmp/plans" "$tmp/jobs" "$tmp/nodes" | shorten > "$tmp/rows"

  { printf 'NODE\tSTATUS\tKERNEL\tBOOT\tSINCE(UTC)\tPLAN\n'; cat "$tmp/rows"; } | column -t -s $'\t'
  echo
  cat "$tmp/summary"
  ;;
# ---------------------------------------------------------------------------
*)
  echo "usage: $0 --bump | --patch"; exit 1 ;;
esac
