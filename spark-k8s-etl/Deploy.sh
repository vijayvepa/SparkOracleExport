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

	info "Pulling busybox image..."
	docker pull busybox:1.36
	info "Busybox image pulled successfully."

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
  local operator_ns="spark-operator"
  local release_name="spark-operator"

  info "Adding Kubeflow Spark Operator Helm repository..."
  if ! helm repo list | grep -q "^spark-operator"; then
    helm repo add spark-operator https://kubeflow.github.io/spark-operator \
      || { error "Failed to add Kubeflow Spark Operator repo"; exit 1; }
  else
    info "Helm repo 'spark-operator' already exists."
  fi

  info "Updating Helm repositories..."
  helm repo update || warn "Helm repo update encountered issues, continuing..."

  info "Installing or upgrading Spark Operator via Helm..."
  helm upgrade --install "${release_name}" spark-operator/spark-operator \
    --namespace "${operator_ns}" \
    --create-namespace \
		--set sparkJobNamespace=${NAMESPACE} \
    --set spark.jobNamespaces="{${NAMESPACE}}" \
		--set enableWebhook=true \
    --set webhook.enable=true \
    || { error "Helm install/upgrade failed"; exit 1; }


  info "Waiting for Spark Operator deployments to become ready..."

  # Controller
  if kubectl -n "${operator_ns}" get deploy spark-operator-controller >/dev/null 2>&1; then
    kubectl rollout status deploy/spark-operator-controller \
      -n "${operator_ns}" --timeout=5m \
      || warn "Spark Operator controller rollout not confirmed."
  else
    warn "Controller deployment not found in namespace ${operator_ns}."
  fi

  # Webhook
  if kubectl -n "${operator_ns}" get deploy spark-operator-webhook >/dev/null 2>&1; then
    kubectl rollout status deploy/spark-operator-webhook \
      -n "${operator_ns}" --timeout=5m \
      || warn "Spark Operator webhook rollout not confirmed."
  else
    warn "Webhook deployment not found in namespace ${operator_ns}."
  fi

  info "Checking for required CRDs..."

  local crds=(
    "sparkapplications.sparkoperator.k8s.io"
    "scheduledsparkapplications.sparkoperator.k8s.io"
  )

  for crd in "${crds[@]}"; do
    until kubectl get crd "${crd}" >/dev/null 2>&1; do
      info "Waiting for CRD: ${crd} ..."
      sleep 2
    done
    info "CRD available: ${crd}"
  done

  info "Spark Operator installation complete and ready."
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
	info "Adding Spark account..."
	kubectl apply -f "${SCRIPT_DIR}/k8s/spark-account.yaml"


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

