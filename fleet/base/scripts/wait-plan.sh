#!/bin/sh
# SUC "prepare" step: block until every node matching <selector> carries the
# latest hash label of <plan>. Gives ordering between plans (etcd -> cp -> workers).
# usage: wait-plan.sh <plan> <label-selector>
set -eu
PLAN=$1
SELECTOR=$2
NS="${NS:-cattle-system}"

while :; do
  hash=$(kubectl -n "$NS" get plan "$PLAN" -o jsonpath='{.status.latestHash}')
  total=$(kubectl get nodes -l "$SELECTOR" -o name | wc -l)
  done_=0
  if [ -n "$hash" ]; then
    done_=$(kubectl get nodes -l "$SELECTOR,plan.upgrade.cattle.io/$PLAN=$hash" -o name | wc -l)
  fi
  echo "[wait-plan] $PLAN: $done_/$total nodes done"
  [ "$done_" -ge "$total" ] && exit 0
  sleep 30
done
