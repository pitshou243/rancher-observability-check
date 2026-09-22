# Rancher Observability Check

`rancher-observability-check.sh` is a read-only diagnostic tool for SUSE Rancher Support. It detects and validates both Rancher Monitoring V2 and the Rancher 2.15+ decoupled monitoring architecture.

By default, the script prints only the detected architecture, warnings, failures, and a final summary. It can be used with `--all` to print every successful check.

## Why?

Starting with Rancher 2.15, two monitoring architectures can exist:

1. **Monitoring V2** — the legacy `rancher-monitoring` chart manages Prometheus, Grafana, Alertmanager, exporters, and Rancher UI integration.
2. **Rancher Monitoring Dashboards** — `rancher-monitoring-dashboards` provides dashboards and Rancher UI integration, while the monitoring runtime—normally `kube-prometheus-stack`—is installed and managed separately.

The Rancher UI provides a useful high-level view, but it does not always identify whether a problem originates from the UI integration, proxy services, external Prometheus stack, Prometheus Operator resources, Kubernetes endpoints, storage, or resource pressure.

Without this tool, Support may need to request and interpret many individual commands differently for each architecture. This tool provides one consistent first-pass assessment whose output can be pasted into a support case.

### Support benefits

- Automatically identifies the monitoring architecture.
- Reduces the number of commands requested from customers.
- Separates Rancher UI integration failures from monitoring-runtime failures.
- Detects partially ready pods such as `1/2 Running`.
- Highlights unavailable workloads, unbound PVCs, OOM kills, missing endpoints, and warning events.
- Treats missing control-plane exporters in the new architecture as warnings because they are disabled by default.
- Provides stable exit codes for automation and GitOps validation.
- Does not modify the cluster or print Secret contents.

## What?

### Supported architectures

| Mode | Architecture | Typical components |
|---|---|---|
| `v2` | Rancher Monitoring V2 | `rancher-monitoring`, Prometheus, Grafana, Alertmanager, Prometheus Operator |
| `dashboards` | Rancher 2.15+ decoupled monitoring | `rancher-monitoring-dashboards` and an independent runtime such as `kube-prometheus-stack` |
| `auto` | Automatic detection | Selects `v2` or `dashboards` using Helm and Kubernetes resource evidence |

> The `dashboards` mode is not the commercial SUSE Observability server, agent, or Rancher UI extension. It refers to the Rancher 2.15+ dashboards-only monitoring integration.

### Checks performed

All modes check:

- Kubernetes API connectivity and the monitoring namespace
- Architecture detection
- Prometheus Operator CRDs
- Pod phase and container readiness
- Unavailable Deployment and DaemonSet replicas
- Unbound persistent volume claims
- Containers previously terminated with `OOMKilled`
- Services without ready EndpointSlice addresses
- Recent warning events in the monitoring namespace

Monitoring V2 additionally checks:

- `rancher-monitoring-grafana`
- `rancher-monitoring-prometheus`
- `rancher-monitoring-alertmanager`
- Prometheus Operator deployment presence

Rancher 2.15+ additionally checks:

- `rancher-monitoring-dashboards` Helm release
- `kube-prometheus-stack` Helm release
- Rancher UI mirror/proxy services and endpoints
- Upstream Grafana and Prometheus services
- ServiceMonitor coverage for etcd, controller-manager, scheduler, and kube-proxy

### Result meanings

| Result | Meaning |
|---|---|
| `PASS` | Check succeeded; printed only with `--all` |
| `WARN` | Review recommended; condition may be intentional or non-blocking |
| `FAIL` | Required resource or healthy condition was not found |

| Exit code | Meaning |
|---:|---|
| `0` | No warnings or failures |
| `1` | One or more warnings |
| `2` | One or more failures |
| `3` | Invalid usage or missing `kubectl` |

## How?

### Requirements

- Bash 4 or newer
- `kubectl`
- Valid kubeconfig
- Read access to the monitoring namespace and cluster-scoped Prometheus Operator resources

The script runs from a support or administrator workstation. It does not need to be installed inside the cluster.

### Install

```bash
git clone https://github.com/pitshou243/rancher-observability-check.git
cd rancher-observability-check
chmod +x rancher-observability-check.sh
```

### Basic usage

Run against the current `kubectl` context. The default namespace is `cattle-monitoring-system` and the default mode is `auto`:

```bash
./rancher-observability-check.sh
```

Print successful checks as well as warnings and failures:

```bash
./rancher-observability-check.sh --all
```

Run against a specific cluster:

```bash
./rancher-observability-check.sh --context downstream-production
```

Select a namespace:

```bash
./rancher-observability-check.sh --namespace cattle-monitoring-system
```

Force a particular architecture when auto-detection is unavailable:

```bash
./rancher-observability-check.sh --mode v2
./rancher-observability-check.sh --mode dashboards
```

Increase the Kubernetes request timeout:

```bash
./rancher-observability-check.sh --timeout 30s
```

Combine options:

```bash
./rancher-observability-check.sh \
  --context downstream-production \
  --namespace cattle-monitoring-system \
  --mode dashboards \
  --timeout 30s \
  --all
```

### Complete option reference

| Option | Description | Default |
|---|---|---|
| `-n NAME`, `--namespace NAME` | Monitoring namespace | `cattle-monitoring-system` |
| `--context NAME` | Kubernetes context | Current context |
| `--mode auto` | Automatically detect the architecture | Default mode |
| `--mode v2` | Force Monitoring V2 checks | — |
| `--mode dashboards` | Force Rancher 2.15+ checks | — |
| `--all` | Include successful checks | Disabled |
| `--timeout VALUE` | Timeout for each `kubectl` request | `15s` |
| `-h`, `--help` | Display help | — |
| `-v`, `--version` | Display version | — |

## Example output and interpretation

Healthy Monitoring V2:

```text
Rancher Observability Check v1.0.0
Mode: v2 | Namespace: cattle-monitoring-system
Summary: PASS=7 WARN=0 FAIL=0
```

Rancher 2.15+ with default control-plane scraping behavior:

```text
Rancher Observability Check v1.0.0
Mode: dashboards | Namespace: cattle-monitoring-system
[WARN] No matching ServiceMonitor: kube-etcd kube-controller-manager kube-scheduler kube-proxy (disabled by default in the new architecture)
Summary: PASS=11 WARN=1 FAIL=0
```

The warning does not necessarily mean monitoring is broken. Confirm whether the customer expects those control-plane metrics before recommending changes.

Failed Prometheus integration:

```text
Rancher Observability Check v1.0.0
Mode: dashboards | Namespace: cattle-monitoring-system
[FAIL] rancher-monitoring-prometheus proxy has no ready endpoints
[FAIL] No upstream Prometheus service found
Summary: PASS=8 WARN=0 FAIL=2
```

Review the Prometheus release, service names, dashboard chart service overrides, pod readiness, and EndpointSlices.

## Recommended Support workflow

1. Confirm the intended downstream cluster is selected in `kubectl`.
2. Run the script in automatic mode.
3. If detection fails, verify RBAC and rerun with an explicit `--mode`.
4. Investigate `FAIL` results first.
5. Interpret warnings against the intended architecture.
6. Rerun with `--all` when a full validation record is needed.
7. Paste or attach the output to the support case.

To intentionally save the output:

```bash
./rancher-observability-check.sh --all 2>&1 | tee rancher-observability-check-output.txt
```

The script itself writes nothing to disk; `tee` is optional.

## Safety and limitations

- Uses read-only `kubectl get` operations.
- Does not modify Helm releases, workloads, CRDs, services, or configuration.
- Does not print Secret data.
- Restricted Secret-list permissions may prevent Helm-based auto-detection.
- A missing ServiceMonitor does not prove a target is not scraped another way.
- This is first-pass triage; it does not replace Prometheus target inspection, PromQL analysis, or component logs.

## License

See [LICENSE](LICENSE).
