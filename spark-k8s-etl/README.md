# Spark-on-Kubernetes ETL (Docker Desktop Kubernetes + Oracle XE + Spark Operator)

This project runs a **local Spark ETL job on Docker Desktop’s built-in Kubernetes cluster** (no Kind) using:

- **Oracle XE** running inside the cluster (for sample source data)
- **Spark Operator** (via Helm) to submit a `SparkApplication`
- A **custom Spark image** that includes the **Oracle JDBC driver** (placeholder in repo)
- A **PySpark ETL job** that reads Oracle via JDBC, transforms, and writes **fixed-width** output to a PVC-mounted directory.

## Prerequisites

- Docker Desktop (Windows) with **Kubernetes enabled**
- `kubectl` installed and pointing to Docker Desktop context
- Helm v3 installed

Verify:

```bash
kubectl config current-context
kubectl get nodes
helm version
```

## Project layout

`spark-k8s-etl/` contains:

- `k8s/`: namespace, Oracle deployment/service, PVC, SparkApplication CRD, operator values
- `docker/spark/`: custom Spark Dockerfile + JDBC driver placeholder
- `src/main/python/etl_job.py`: ETL job
- `config/layout.json`: fixed-width metadata
- `scripts/`: build/deploy/submit helpers

## 1) Enable Kubernetes (Docker Desktop)

In Docker Desktop:
- Settings → Kubernetes → **Enable Kubernetes** → Apply & Restart

Increase resources (Oracle is memory-hungry):
- Settings → Resources → **Memory 6–8GB** recommended

## 2) Create namespace

```bash
cd spark-k8s-etl
kubectl apply -f k8s/namespace.yaml
```

## 3) Create storage PVCs

This uses a simple `hostPath` PV compatible with Docker Desktop’s single-node setup.

```bash
kubectl apply -f k8s/storage/pvc.yaml
```

Check:

```bash
kubectl -n spark-etl get pv,pvc
```

## 4) Deploy Oracle XE

Deploy Oracle and wait for it to be ready:

```bash
./scripts/deploy-oracle.sh
```

Check:

```bash
kubectl -n spark-etl get pods
kubectl -n spark-etl logs deploy/oracle-xe -c oracle -f
```

### Load sample SQL (table + inserts)

Once the Oracle pod is Running/Ready:

```bash
kubectl -n spark-etl exec -it deploy/oracle-xe -c oracle -- bash -lc "sqlplus system/Oracle123@localhost:1521/XEPDB1 @/opt/oracle/init/sample-data.sql"
```

> If you see `ORA-01017` or connection errors, wait longer; Oracle XE initialization can take several minutes.

## 5) Install Spark Operator (Helm)

Install the operator into the same namespace:

```bash
./scripts/deploy-spark-operator.sh
```

Verify:

```bash
kubectl -n spark-etl get pods -l app.kubernetes.io/name=spark-operator
kubectl -n spark-etl get crd | findstr SparkApplication
```

## 6) Build the custom Spark image (with Oracle JDBC)

**Important:** This repo includes a **placeholder** `ojdbc8.jar` text file. You must replace it with the real JDBC jar:

- Download `ojdbc8.jar` (or a compatible Oracle JDBC jar) from Oracle
- Place it at: `docker/spark/drivers/ojdbc8.jar`

Then build:

```bash
./scripts/build-spark-image.sh
```

This builds: `spark-etl:local`

Docker Desktop Kubernetes can pull images directly from the local Docker daemon.

## 7) Submit the Spark job

```bash
kubectl apply -f k8s/spark-app.yaml
```

Watch:

```bash
kubectl -n spark-etl get sparkapplications
kubectl -n spark-etl describe sparkapplication oracle-fixedwidth-etl
kubectl -n spark-etl get pods -l spark-role=driver
kubectl -n spark-etl logs -l spark-role=driver -f
```

## 8) Retrieve output

The job writes to `/output/fixedwidth.txt` inside the driver/executor pods, backed by the output PVC.

To view via a temporary pod:

```bash
kubectl -n spark-etl apply -f k8s/storage/output-reader-pod.yaml
kubectl -n spark-etl exec -it pod/output-reader -- sh -lc "ls -lah /output && echo '---' && sed -n '1,20p' /output/fixedwidth.txt"
```

Cleanup:

```bash
kubectl -n spark-etl delete pod/output-reader
```

## Troubleshooting

- **Oracle pod OOMKilled**: increase Docker Desktop memory; Oracle XE needs headroom.
- **Spark image not found**: ensure you built `spark-etl:local` in Docker Desktop’s Docker context.
- **JDBC errors**: confirm the real `ojdbc8.jar` is in the image (`/opt/bitnami/spark/jars/`), and the service DNS is correct.
- **PVC Pending**: ensure Docker Desktop Kubernetes supports `hostPath` on its node; check PV exists and matches PVC `storageClassName`.

## Notes

- Oracle service is **ClusterIP** (in-cluster access only).
- This setup avoids Kind and uses Docker Desktop’s built-in Kubernetes directly.

