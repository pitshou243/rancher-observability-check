#!/usr/bin/env bash
set -uo pipefail

VERSION="1.0.0"; NAMESPACE="cattle-monitoring-system"; CONTEXT=""; MODE="auto"
SHOW_ALL=false; TIMEOUT="15s"; PASS=0; WARN=0; FAIL=0

usage() {
  sed 's/^+//' <<'EOF'
+Usage: rancher-observability-check.sh [options]
+  -n, --namespace NAME   Monitoring namespace (default: cattle-monitoring-system)
+      --context NAME     kubectl context
+      --mode MODE        auto, v2, or dashboards (default: auto)
+      --all              Show successful checks
+      --timeout VALUE    kubectl request timeout (default: 15s)
+  -h, --help             Show help
+  -v, --version          Show version
+Exit codes: 0 healthy, 1 warnings, 2 failures, 3 usage/dependency error.
EOF
}

while (($#)); do
  case "$1" in
    -n|--namespace) [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value"; exit 3; }; NAMESPACE=$2; shift 2 ;;
    --context) [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value"; exit 3; }; CONTEXT=$2; shift 2 ;;
    --mode) [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value"; exit 3; }; MODE=$2; shift 2 ;;
    --all) SHOW_ALL=true; shift ;;
    --timeout) [[ $# -ge 2 ]] || { echo "ERROR: $1 requires a value"; exit 3; }; TIMEOUT=$2; shift 2 ;;
    -h|--help) usage; exit 0 ;; -v|--version) echo "rancher-observability-check.sh $VERSION"; exit 0 ;;
    *) echo "ERROR: unknown option: $1"; usage; exit 3 ;;
  esac
done
case "$MODE" in auto|v2|dashboards) ;; *) echo "ERROR: invalid --mode"; exit 3 ;; esac
command -v kubectl >/dev/null 2>&1 || { echo "ERROR: kubectl is required"; exit 3; }
K=(kubectl --request-timeout="$TIMEOUT"); [[ -n "$CONTEXT" ]] && K+=(--context "$CONTEXT")
k() { "${K[@]}" "$@"; }
emit() { case "$1" in PASS) ((PASS+=1)); $SHOW_ALL && printf '[PASS] %s\n' "$2";; WARN) ((WARN+=1)); printf '[WARN] %s\n' "$2";; FAIL) ((FAIL+=1)); printf '[FAIL] %s\n' "$2";; esac; return 0; }
exists() { if [[ -n "${3:-}" ]]; then k get "$1" "$2" -n "$3" -o name >/dev/null 2>&1; else k get "$1" "$2" -o name >/dev/null 2>&1; fi; }

check_cluster() {
  local server; server=$(k config view --minify -o jsonpath='{.clusters[0].cluster.server}' 2>/dev/null || true)
  [[ -n "$server" ]] || { emit FAIL "No active Kubernetes context"; return 1; }
  k get --raw=/readyz >/dev/null 2>&1 && emit PASS "Kubernetes API is ready ($server)" || { emit FAIL "Kubernetes API is not reachable or ready ($server)"; return 1; }
}
detect_mode() {
  local releases; releases=$(k get secrets -n "$NAMESPACE" -l owner=helm -o jsonpath='{range .items[*]}{.metadata.labels.name}{"\n"}{end}' 2>/dev/null || true)
  if grep -qx rancher-monitoring-dashboards <<<"$releases"; then DETECTED=dashboards
  elif grep -qx rancher-monitoring <<<"$releases"; then DETECTED=v2
  elif k get deploy -n "$NAMESPACE" -o name 2>/dev/null | grep -q rancher-monitoring-dashboards; then DETECTED=dashboards
  elif k get prometheus -n "$NAMESPACE" -o name 2>/dev/null | grep -q rancher-monitoring; then DETECTED=v2
  else DETECTED=unknown; fi
  [[ "$MODE" != auto ]] && DETECTED=$MODE
}
check_crds() {
  local missing=() crd
  for crd in prometheuses.monitoring.coreos.com alertmanagers.monitoring.coreos.com servicemonitors.monitoring.coreos.com podmonitors.monitoring.coreos.com prometheusrules.monitoring.coreos.com; do k get crd "$crd" >/dev/null 2>&1 || missing+=("$crd"); done
  ((${#missing[@]} == 0)) && emit PASS "Prometheus Operator CRDs are present" || emit FAIL "Missing Prometheus Operator CRDs: ${missing[*]}"
}
check_workloads() {
  local bad unavailable dsbad
  bad=$(k get pods -n "$NAMESPACE" --no-headers 2>/dev/null | awk '
    {split($2,r,"/")}
    $3 !~ /^(Running|Completed)$/ || r[1] != r[2] {print $1"("$2","$3",restarts="$4")"}
  ' | head -20)
  [[ -z "$bad" ]] && emit PASS "All monitoring pods are healthy" || emit FAIL "Unhealthy pods: ${bad//$'\n'/; }"
  unavailable=$(k get deploy -n "$NAMESPACE" -o jsonpath='{range .items[?(@.status.unavailableReplicas)]}{.metadata.name}={.status.unavailableReplicas}{" "}{end}' 2>/dev/null || true)
  [[ -z "$unavailable" ]] || emit FAIL "Unavailable deployment replicas: $unavailable"
  dsbad=$(k get ds -n "$NAMESPACE" -o jsonpath='{range .items[?(@.status.numberUnavailable)]}{.metadata.name}={.status.numberUnavailable}{" "}{end}' 2>/dev/null || true)
  [[ -z "$dsbad" ]] || emit FAIL "Unavailable DaemonSet pods: $dsbad"
}
check_storage() {
  local bad oom; bad=$(k get pvc -n "$NAMESPACE" --no-headers 2>/dev/null | awk '$2!="Bound"{print $1"="$2}' | head -20)
  [[ -z "$bad" ]] && emit PASS "Monitoring PVCs are Bound" || emit FAIL "Unbound PVCs: ${bad//$'\n'/; }"
  oom=$(k get pods -n "$NAMESPACE" -o jsonpath='{range .items[*]}{range .status.containerStatuses[*]}{.name}:{.lastState.terminated.reason}{"\n"}{end}{end}' 2>/dev/null | grep OOMKilled || true)
  [[ -z "$oom" ]] || emit FAIL "Recently OOMKilled: ${oom//$'\n'/ }"
}
check_endpoints() {
  local svc ip addresses; local empty=()
  while IFS= read -r svc; do
    [[ -n "$svc" ]] || continue; ip=$(k get svc "$svc" -n "$NAMESPACE" -o jsonpath='{.spec.clusterIP}' 2>/dev/null || true); [[ "$ip" == None ]] && continue
    addresses=$(k get endpointslice -n "$NAMESPACE" -l "kubernetes.io/service-name=$svc" -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready!=false)]}{.addresses[0]}{" "}{end}' 2>/dev/null || true)
    [[ -n "$addresses" ]] || empty+=("$svc")
  done < <(k get svc -n "$NAMESPACE" -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' 2>/dev/null)
  ((${#empty[@]} == 0)) && emit PASS "Services have ready endpoints" || emit WARN "Services without ready endpoints: ${empty[*]}"
}
check_v2() {
  local svc; local missing=()
  for svc in rancher-monitoring-grafana rancher-monitoring-prometheus rancher-monitoring-alertmanager; do exists service "$svc" "$NAMESPACE" || missing+=("$svc"); done
  ((${#missing[@]} == 0)) && emit PASS "Monitoring V2 UI services are present" || emit FAIL "Missing Monitoring V2 services: ${missing[*]}"
  k get deploy -n "$NAMESPACE" -o name 2>/dev/null | grep -q operator && emit PASS "Prometheus Operator deployment found" || emit FAIL "No Prometheus Operator deployment found"
}
check_dashboards() {
  local release svc endpoints; local disabled=()
  release=$(k get secrets -n "$NAMESPACE" -l owner=helm,name=rancher-monitoring-dashboards -o name 2>/dev/null || true)
  [[ -n "$release" ]] && emit PASS "rancher-monitoring-dashboards release found" || emit FAIL "rancher-monitoring-dashboards Helm release not found"
  release=$(k get secrets -n "$NAMESPACE" -l owner=helm,name=kube-prometheus-stack -o name 2>/dev/null || true)
  [[ -n "$release" ]] && emit PASS "kube-prometheus-stack release found" || emit WARN "kube-prometheus-stack release not found; verify the external Prometheus stack"
  for svc in rancher-monitoring-grafana rancher-monitoring-prometheus rancher-monitoring-alertmanager; do
    if ! exists service "$svc" "$NAMESPACE"; then emit FAIL "Rancher UI mirror service missing: $svc"; continue; fi
    endpoints=$(k get endpointslice -n "$NAMESPACE" -l "kubernetes.io/service-name=$svc" -o jsonpath='{range .items[*].endpoints[?(@.conditions.ready!=false)]}{.addresses[0]}{" "}{end}' 2>/dev/null || true)
    [[ -n "$endpoints" ]] && emit PASS "$svc proxy has ready endpoints" || emit FAIL "$svc proxy has no ready endpoints"
  done
  k get svc -n "$NAMESPACE" -l app.kubernetes.io/name=grafana -o name 2>/dev/null | grep -q . && emit PASS "Upstream Grafana service found" || emit FAIL "No upstream Grafana service found"
  k get svc -n "$NAMESPACE" -l app.kubernetes.io/name=prometheus -o name 2>/dev/null | grep -q . && emit PASS "Upstream Prometheus service found" || emit FAIL "No upstream Prometheus service found"
  for svc in kube-etcd kube-controller-manager kube-scheduler kube-proxy; do k get servicemonitor -A -o name 2>/dev/null | grep -qi "$svc" || disabled+=("$svc"); done
  ((${#disabled[@]} == 0)) || emit WARN "No matching ServiceMonitor: ${disabled[*]} (disabled by default in the new architecture)"
}
check_events() {
  local events; events=$(k get events -n "$NAMESPACE" --field-selector type=Warning --sort-by=.lastTimestamp -o custom-columns='REASON:.reason,OBJECT:.involvedObject.name,MESSAGE:.message' --no-headers 2>/dev/null | tail -10 || true)
  [[ -z "$events" ]] || emit WARN "Recent warning events: ${events//$'\n'/; }"
}

echo "Rancher Observability Check v$VERSION"
check_cluster || { echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"; exit 2; }
exists namespace "$NAMESPACE" && emit PASS "Namespace $NAMESPACE exists" || { emit FAIL "Namespace $NAMESPACE does not exist"; echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"; exit 2; }
detect_mode; echo "Mode: $DETECTED | Namespace: $NAMESPACE"
case "$DETECTED" in v2) check_crds; check_workloads; check_v2 ;; dashboards) check_crds; check_workloads; check_dashboards ;; *) emit FAIL "Could not detect Monitoring V2 or dashboards architecture; use --mode" ;; esac
check_storage; check_endpoints; check_events
echo "Summary: PASS=$PASS WARN=$WARN FAIL=$FAIL"
((FAIL > 0)) && exit 2; ((WARN > 0)) && exit 1; exit 0
