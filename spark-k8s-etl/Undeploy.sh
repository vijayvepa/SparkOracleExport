#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="spark-etl-mysql"

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

info "Removing Spark ETL (MySQL) resources from namespace '${NAMESPACE}'..."

# Delete SparkApplication (if CRD/operator still present)
kubectl -n "${NAMESPACE}" delete sparkapplication mysql-fixedwidth-etl --ignore-not-found=true || true

# Delete Spark driver/executor pods (if any remain)
kubectl -n "${NAMESPACE}" delete pod -l spark-role=driver --ignore-not-found=true || true
kubectl -n "${NAMESPACE}" delete pod -l spark-role=executor --ignore-not-found=true || true

# Delete MySQL deployment, service, and init configmap
kubectl -n "${NAMESPACE}" delete deploy/mysql svc/mysql cm/mysql-init-sql --ignore-not-found=true || true

# Delete output-reader helper pod if present
kubectl -n "${NAMESPACE}" delete pod/output-reader --ignore-not-found=true || true

# Delete PV/PVC for MySQL and ETL output
kubectl -n "${NAMESPACE}" delete pvc/mysql-data-pvc pvc/etl-output-pvc --ignore-not-found=true || true
kubectl delete pv/mysql-data-pv pv/etl-output-pv --ignore-not-found=true || true

# Remove Spark Operator via Helm (release is namespaced)
if helm status spark-operator -n "${NAMESPACE}" >/dev/null 2>&1; then
  info "Uninstalling Spark Operator Helm release from namespace ${NAMESPACE}..."
  helm uninstall spark-operator -n "${NAMESPACE}" || warn "Helm uninstall spark-operator failed."
fi

# Finally, delete the namespace
kubectl delete namespace "${NAMESPACE}" --ignore-not-found=true || true

info "Undeploy complete. Some cluster-scoped resources (like the SparkApplication CRD) are intentionally left intact."

