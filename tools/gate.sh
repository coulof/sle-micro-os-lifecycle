#!/bin/sh
# Gate between OS patching and Rancher-driven Kubernetes upgrade for ONE downstream cluster.
#   gate.sh check  <downstream-kubeconfig>
#       -> exit 0 if all OS plans complete AND all nodes share one rpm fingerprint
#   gate.sh bump   <downstream-kubeconfig> <rancher-kubeconfig> <cluster-name> <k8s-version>
#       -> runs check, then sets spec.kubernetesVersion on the Rancher provisioning Cluster
set -eu
NS=cattle-system
PREFIX="${LABEL_PREFIX:-platform.example.com}"

plan_selector() {
  case "$1" in
    os-patch-etcd)    echo "node-role.kubernetes.io/etcd=true" ;;
    os-patch-cp)      echo "node-role.kubernetes.io/control-plane=true,!node-role.kubernetes.io/etcd" ;;
    os-patch-workers) echo "!node-role.kubernetes.io/control-plane,!node-role.kubernetes.io/etcd" ;;
  esac
}

check() {
  kc=$1; rc=0
  for p in os-patch-etcd os-patch-cp os-patch-workers; do
    sel=$(plan_selector "$p")
    hash=$(kubectl --kubeconfig "$kc" -n "$NS" get plan "$p" -o jsonpath='{.status.latestHash}')
    total=$(kubectl --kubeconfig "$kc" get nodes -l "$sel" -o name | wc -l)
    ok=$(kubectl --kubeconfig "$kc" get nodes -l "$sel,plan.upgrade.cattle.io/$p=$hash" -o name | wc -l)
    echo "plan $p: $ok/$total"
    [ "$ok" -ge "$total" ] || rc=1
  done
  fps=$(kubectl --kubeconfig "$kc" get nodes -o go-template="{{range .items}}{{index .metadata.labels \"$PREFIX/rpm-fp\"}}{{\"\n\"}}{{end}}" | sort -u)
  n=$(printf '%s\n' "$fps" | grep -c . || true)
  echo "distinct rpm fingerprints: $n"
  [ "$n" -eq 1 ] || { echo "DRIFT:"; kubectl --kubeconfig "$kc" get nodes -L "$PREFIX/rpm-fp,$PREFIX/os-release"; rc=1; }
  unsched=$(kubectl --kubeconfig "$kc" get nodes -o jsonpath='{.items[?(@.spec.unschedulable==true)].metadata.name}')
  [ -z "$unsched" ] || { echo "cordoned nodes: $unsched"; rc=1; }
  return "$rc"
}

case "${1:-}" in
  check) check "$2" ;;
  bump)
    check "$2" || { echo "gate closed"; exit 1; }
    up=$3; cluster=$4; ver=$5
    kubectl --kubeconfig "$up" -n fleet-default wait "clusters.provisioning.cattle.io/$cluster" --for=condition=Ready --timeout=60s
    kubectl --kubeconfig "$up" -n fleet-default patch "clusters.provisioning.cattle.io/$cluster" \
      --type merge -p "{\"spec\":{\"kubernetesVersion\":\"$ver\"}}"
    echo "kubernetesVersion -> $ver requested; Rancher now drives the k8s rollout" ;;
  *) sed -n '2,7p' "$0"; exit 2 ;;
esac
