#!/usr/bin/env bash

set -euo pipefail

NAMESPACE="spark-etl-mysql"
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
  mysql            - deploy MySQL (ConfigMap, Deployment, Service)
  mysql-wait       - wait for MySQL deployment to be ready
  mysql-sql        - load sample SQL into MySQL
  operator         - install/upgrade Spark Operator (Helm)
  image            - build Spark image (${SPARK_IMAGE_TAG})
  spark-app        - apply SparkApplication manifest
  logs             - tail Spark driver logs

Examples:
  $(basename "$0")                    # full pipeline
  $(basename "$0") prereqs namespace  # only run first two steps
  $(basename "$0") mysql-sql          # reload sample data
EOF
}

check_prereqs() {
  info "Checking prerequisites (kubectl, helm, docker)..."
  command -v kubectl >/dev/null 2>&1 || { error "kubectl not found in PATH"; exit 1; }
  command -v helm >/dev/null 2>&1 || { error "helm not found in PATH"; exit 1; }
  command -v docker >/dev/null 2>&1 || { error "docker not found in PATH"; exit 1; }

  info "Current kubectl context:"
  kubectl config current-context || true
  info "Prerequisites check successful."
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

deploy_mysql() {
	info "Pull Docker image for MySQL..."
	docker pull mysql:8.0
	info "Docker image pulled successfully."

  info "Deploying MySQL resources..."
  kubectl apply -f "${SCRIPT_DIR}/k8s/mysql/init-configmap.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/mysql/deployment.yaml"
  kubectl apply -f "${SCRIPT_DIR}/k8s/mysql/service.yaml"
}

wait_for_mysql() {
  info "Waiting for MySQL deployment to become ready..."
  kubectl -n "${NAMESPACE}" rollout status deploy/mysql --timeout=10m
}

load_mysql_sql() {
  info "Loading sample SQL into MySQL..."

  local mysql_pod
  mysql_pod="$(kubectl -n "${NAMESPACE}" get pods -l app=mysql -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"

  if [[ -z "${mysql_pod}" ]]; then
    error "Could not find a MySQL pod in namespace ${NAMESPACE}."
    error "Check: kubectl -n ${NAMESPACE} get pods"
    exit 1
  fi

  info "MySQL pod found: ${mysql_pod}"

  local mysql_container
  mysql_container="$(kubectl -n "${NAMESPACE}" get pod "${mysql_pod}" -o jsonpath='{.spec.containers[0].name}' 2>/dev/null || true)"

  if [[ -z "${mysql_container}" ]]; then
    error "Could not determine MySQL container name for pod ${mysql_pod}."
    error "Inspect the pod with: kubectl -n ${NAMESPACE} get pod ${mysql_pod} -o yaml"
    exit 1
  fi

  info "Using MySQL container: ${mysql_container}"
  info "Executing SQL command..."

  kubectl -n "${NAMESPACE}" exec "${mysql_pod}" -c "${mysql_container}" -- bash -lc \
    "mysql -uroot -prootpassword etldb < /docker-entrypoint-initdb.d/sample-data.sql"

  info "SQL command executed successfully."
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
  info "Adding Spark Operator Helm repository..."
  if ! helm repo list | grep -q "^spark-operator"; then
    if ! helm repo add spark-operator https://kubeflow.github.io/spark-operator; then
      error "Failed to add Spark Operator Helm repository."
      exit 1
    fi
    info "Spark Operator repository added successfully."
  else
    info "Spark Operator repository already exists."
  fi

  info "Updating Helm repositories..."
  if ! helm repo update; then
    warn "Helm repo update had issues, but continuing..."
  fi

  # Install or upgrade into the same namespace used by the ETL job.
  # Ensure the operator watches our ETL namespace (by default it watches "default").
  info "Installing/upgrading Spark Operator..."
  helm upgrade --install spark-operator spark-operator/spark-operator \
    --namespace "${NAMESPACE}" \
    --create-namespace \
    --set sparkJobNamespace="${NAMESPACE}" \
    --set spark.jobNamespaces="{${NAMESPACE}}" \
    "${values_arg[@]}"

  info "Waiting for Spark Operator pods to be ready..."
  # The Spark Operator Helm chart may create a deployment with a different name
  # Try to find it by label selector first
  local operator_deployment
  operator_deployment="$(kubectl -n "${NAMESPACE}" get deploy -l app.kubernetes.io/name=spark-operator -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  
  if [[ -n "${operator_deployment}" ]]; then
    info "Found Spark Operator deployment: ${operator_deployment}"
    kubectl -n "${NAMESPACE}" rollout status "deploy/${operator_deployment}" --timeout=5m || \
      warn "Could not confirm Spark Operator deployment rollout; check pods manually."
  else
    # Fallback: try common deployment names
    if kubectl -n "${NAMESPACE}" get deploy spark-operator >/dev/null 2>&1; then
      kubectl -n "${NAMESPACE}" rollout status deploy/spark-operator --timeout=5m || \
        warn "Could not confirm Spark Operator deployment rollout; check pods manually."
    else
      warn "Could not find Spark Operator deployment. Listing all deployments in namespace:"
      kubectl -n "${NAMESPACE}" get deploy
      warn "Check pods manually: kubectl -n ${NAMESPACE} get pods -l app.kubernetes.io/name=spark-operator"
    fi
  fi
}

build_spark_image() {
	info "Building Spark image '${SPARK_IMAGE_TAG}'..."

  local driver_jar="${SCRIPT_DIR}/docker/spark/drivers/mysql-connector-j.jar"
  if [[ ! -f "${driver_jar}" ]]; then
    warn "MySQL JDBC driver not found at ${driver_jar}."
    warn "Attempting to download mysql-connector-j.jar from Maven Central using wget/curl..."

    local download_url="https://repo1.maven.org/maven2/com/mysql/mysql-connector-j/8.3.0/mysql-connector-j-8.3.0.jar"
    mkdir -p "$(dirname "${driver_jar}")"

    if command -v wget >/dev/null 2>&1; then
      info "Using wget to download MySQL JDBC driver..."
      if ! wget -O "${driver_jar}" "${download_url}"; then
        warn "wget failed to download JDBC driver from ${download_url}."
      fi
    elif command -v curl >/dev/null 2>&1; then
      info "Using curl to download MySQL JDBC driver..."
      if ! curl -L -o "${driver_jar}" "${download_url}"; then
        warn "curl failed to download JDBC driver from ${download_url}."
      fi
    else
      warn "Neither wget nor curl is available; cannot auto-download JDBC driver."
    fi

    if [[ ! -f "${driver_jar}" ]]; then
      error "MySQL JDBC driver is still missing after download attempt."
      error "Please download mysql-connector-j.jar manually and place it at: ${driver_jar}"
      exit 1
    fi
  fi

  docker build -t "${SPARK_IMAGE_TAG}" -f "${SCRIPT_DIR}/docker/spark/Dockerfile" "${SCRIPT_DIR}"
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
    deploy_mysql
    wait_for_mysql
    load_mysql_sql
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
      mysql)       deploy_mysql ;;
      mysql-wait)  wait_for_mysql ;;
      mysql-sql)   load_mysql_sql ;;
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

