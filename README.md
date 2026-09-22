
# Rancher Observability Check

`rancher-observability-check.sh` is a read-only support utility for Rancher Monitoring V2 and the Rancher 2.15+ decoupled monitoring architecture.

## Checks

- Kubernetes API access and automatic architecture detection
- Prometheus Operator CRDs; workload, PVC, OOM and event health
- Services and EndpointSlices
- Monitoring V2 Grafana, Prometheus, Alertmanager and operator presence
- `rancher-monitoring-dashboards` and an independent Prometheus stack
- Rancher UI proxy and upstream Grafana/Prometheus services
- Control-plane ServiceMonitor coverage

It does not modify the cluster or print Secrets. Default output is limited to warnings, failures, the detected mode and summary.

## Requirements and usage

Bash 4+, `kubectl`, and a kubeconfig with read access are required.

```bash
chmod +x rancher-observability-check.sh
./rancher-observability-check.sh
./rancher-observability-check.sh --all
./rancher-observability-check.sh --context downstream-prod
./rancher-observability-check.sh --mode dashboards
```

| Exit | Meaning |
|---:|---|
| 0 | Healthy |
| 1 | Warnings found |
| 2 | Failures found |
| 3 | Usage or dependency error |

The `dashboards` mode means Rancher 2.15+ `rancher-monitoring-dashboards` integrated with an external runtime, commonly `kube-prometheus-stack`. Missing control-plane ServiceMonitors are warnings because these exporters are disabled by default and may be intentionally absent. This is distinct from the commercial SUSE Observability server/agent/UI-extension product.
