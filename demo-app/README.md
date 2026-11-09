helm upgrade --install podinfo oci://ghcr.io/stefanprodan/charts/podinfo \
  -n podinfo --create-namespace -f podinfo-values.yaml
