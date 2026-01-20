#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="spark-etl"
SPARK_IMAGE_TAG="spark-etl:local"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"

info() {
  echo "[INFO] $*"
}

warn() {
  echo "[WARN] $*" >&2
}

error() {
  echo "[ERROR] $*" >&2
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [step ...]

No args  : run full flow (all steps in order).
Steps you can run individually:
  prereqs          - check kubectl/helm/docker and show context
  namespace        - create/ensure namespace
  storage          - create PV/PVC resources
  oracle           - deploy Oracle (ConfigMap, Deployment, Service)
  oracle-wait      - wait for Oracle deployment to be ready
  oracle-sql       - load sample SQL into Oracle
  operator         - install/upgrade Spark Operator (Helm)
  image            - build Spark image (${SPARK_IMAGE_TAG})
  spark-app        - apply SparkApplication manifest
  logs             - tail Spark driver logs

Examples:
  $(basename "$0")                    # full pipeline
  $(basename "$0") prereqs namespace  # only run first two steps
  $(basename "$0") oracle-sql         # reload sample data
EOF
}

check_prereqs() {
  info "Checking prerequisites (kubectl, helm, docker)..."
  command -v kubectl >/dev/null 2>&1 || { error "kubectl not found in PATH"; exit 1; }
  command -v helm >/dev/null 2>&1 || { error "helm not found in PATH"; exit 1; }
  command -v docker >/dev/null 2>&1 || { error "docker not found in PATH"; exit 1; }

  info "Current kubectl context:"
  kubectl config current-context || true
}

create_namespace() {
  info "Creating/ensuring namespace '${NAMESPACE}'..."
  kubectl apply -f "${SCRIPT_DIR}/k8s/namespace.yaml"
}

apply_storage() {
  info "Applying storage PVs/PVCs..."
  kubectl apply -f "${SCRIPT_DIR}/k8s/storage/pvc.yaml"
  info "Current PV/PVC status:"
  kubectl -n "${NAMESPACE}" get pv,pvc || kubectl get pv,pvc
}

deploy_oracle() {
  info "Deploying Oracle XE resources..."
  # Oracle manifests live under k8s/oracle.
  kubectl apply -f "${SCRIPT_DIR}/k8s/oracle/init-configmap.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/oracle/deployment.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/oracle/service.yaml"
}

wait_for_oracle() {
  info "Waiting for Oracle XE deployment to become ready (this can take several minutes)..."
  kubectl -n "${NAMESPACE}" rollout status deploy/oracle-xe --timeout=15m
}

load_sample_sql() {
  info "Loading sample SQL into Oracle XE..."
  # This mirrors the command documented in README.md.
  kubectl -n "${NAMESPACE}" exec deploy/oracle-xe -c oracle -- bash -lc \
    "sqlplus system/Oracle123@localhost:1521/XEPDB1 @/opt/oracle/init/sample-data.sql"
}

deploy_spark_operator() {
  info "Installing/ensuring Spark Operator via Helm..."

  # Allow user to pre-create a values file as described in the project spec.
  local values_file="${SCRIPT_DIR}/k8s/spark-operator-values.yaml"
  local values_arg=()
  if [[ -f "${values_file}" ]]; then
    values_arg=(-f "${values_file}")
    info "Using Spark Operator values file: ${values_file}"
  else
    warn "Spark Operator values file not found at ${values_file}; proceeding with chart defaults."
  fi

  # Add repo if missing; ignore error if it already exists.
  helm repo add spark-operator https://googlecloudplatform.github.io/spark-on-k8s-operator >/dev/null 2>&1 || true
  helm repo update >/dev/null 2>&1 || true

  # Install or upgrade into the same namespace used by the ETL job.
  helm upgrade --install spark-operator spark-operator/spark-operator \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    "${values_arg[@]}"

  info "Waiting for Spark Operator pods to be ready..."
  kubectl -n "${NAMESPACE}" rollout status deploy/spark-operator --timeout=5m || \
    warn "Could not confirm Spark Operator deployment rollout; check pods manually."
}

build_spark_image() {
  info "Building Spark image '${SPARK_IMAGE_TAG}'..."

  local driver_jar="${SCRIPT_DIR}/docker/spark/drivers/ojdbc8.jar"
  if [[ ! -f "${driver_jar}" ]]; then
    warn "Oracle JDBC driver not found at ${driver_jar}."
    warn "You must download ojdbc8.jar (or compatible) and place it there before running the job."
  fi

  docker build -t "${SPARK_IMAGE_TAG}" "${SCRIPT_DIR}/docker/spark"
}

submit_spark_app() {
  info "Submitting SparkApplication CRD..."
  kubectl apply -f "${SCRIPT_DIR}/k8s/spark-app.yaml"

  info "Current SparkApplications:"
  kubectl -n "${NAMESPACE}" get sparkapplications || \
    warn "SparkApplication CRD may not be installed yet; verify Spark Operator installation."
}

tail_spark_driver_logs() {
  info "Tailing Spark driver logs (Ctrl+C to stop)..."
  # Wait briefly for driver pod to appear
  sleep 10
  local driver_pod
  driver_pod="$(kubectl -n "${NAMESPACE}" get pods -l spark-role=driver -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -z "${driver_pod}" ]]; then
    warn "No Spark driver pod detected yet. You can check later with:"
    warn "  kubectl -n ${NAMESPACE} get pods -l spark-role=driver"
    return 0
  fi

  info "Streaming logs from driver pod: ${driver_pod}"
  kubectl -n "${NAMESPACE}" logs -f "${driver_pod}" || \
    warn "Failed to stream logs from driver pod."
}

main() {
  if [[ $# -eq 0 ]]; then
    # Default: run full pipeline
    check_prereqs
    create_namespace
    apply_storage
    deploy_oracle
    wait_for_oracle
    load_sample_sql
    deploy_spark_operator
    build_spark_image
    submit_spark_app
    tail_spark_driver_logs

    info "Deployment flow complete."
    info "To inspect output, you can run (from spark-k8s-etl/):"
    echo "  kubectl -n ${NAMESPACE} apply -f k8s/storage/output-reader-pod.yaml"
    echo "  kubectl -n ${NAMESPACE} exec -it pod/output-reader -- sh -lc \"ls -lah /output && sed -n '1,20p' /output/fixedwidth.txt\""
    return 0
  fi

  # If args are provided, treat each as a step name and run in order.
  for step in "$@"; do
    case "${step}" in
      prereqs)     check_prereqs ;;
      namespace)   create_namespace ;;
      storage)     apply_storage ;;
      oracle)      deploy_oracle ;;
      oracle-wait) wait_for_oracle ;;
      oracle-sql)  load_sample_sql ;;
      operator)    deploy_spark_operator ;;
      image)       build_spark_image ;;
      spark-app)   submit_spark_app ;;
      logs)        tail_spark_driver_logs ;;
      help|-h|--help)
        usage
        return 0
        ;;
      *)
        error "Unknown step: ${step}"
        usage
        return 1
        ;;
    esac
  done
}

main "$@"

