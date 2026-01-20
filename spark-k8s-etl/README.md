# Spark-on-Kubernetes ETL (Docker Desktop Kubernetes + MySQL + Spark Operator)

This project runs a **local Spark ETL job on Docker Desktop’s built-in Kubernetes cluster** (no Kind) using:

- **MySQL** running inside the cluster (sample source data)
- **Spark Operator** (via Helm) to submit a `SparkApplication`
- A **custom Spark image** that includes the **MySQL JDBC driver** (placeholder in repo)
- A **PySpark ETL job** that reads MySQL via JDBC, transforms, and writes **fixed-width** output to a PVC-mounted directory.

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

- `k8s/`: namespace, MySQL deployment/service, PVC, SparkApplication CRD, operator values
- `docker/spark/`: custom Spark Dockerfile + JDBC driver placeholder
- `src/main/python/etl_job.py`: ETL job
- `config/layout.json`: fixed-width metadata
- `scripts/`: build/deploy/submit helpers

## 1) Enable Kubernetes (Docker Desktop)

In Docker Desktop:
- Settings → Kubernetes → **Enable Kubernetes** → Apply & Restart
- **!IMPORTANT** Settings → General → **Use containerd for pulling and storing images** → Apply & Restart

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
kubectl -n spark-etl-mysql get pv,pvc
```

## 4) Deploy MySQL

Deploy MySQL and wait for it to be ready:

```bash
./Deploy.sh mysql
./Deploy.sh mysql-wait
```

Check:

```bash
kubectl -n spark-etl-mysql get pods
kubectl -n spark-etl-mysql logs deploy/mysql -f
```

### Load sample SQL (table + inserts)

If you want to re-run the seed script (it also runs automatically on first start):

```bash
./Deploy.sh mysql-sql
```

## 5) Install Spark Operator (Helm)

Install the operator into the same namespace:

```bash
./scripts/deploy-spark-operator.sh
```

Verify:

```bash
kubectl -n spark-etl-mysql get pods -l app.kubernetes.io/name=spark-operator
kubectl -n spark-etl-mysql get crd | findstr SparkApplication
```

## 6) Build the custom Spark image (with MySQL JDBC)

**Important:** This repo includes a **placeholder** `mysql-connector-j.jar` text file. You must replace it with the real JDBC jar (or let `Deploy.sh image` auto-download from Maven Central):

- Place it at: `docker/spark/drivers/mysql-connector-j.jar`

Then build:

```bash
./Deploy.sh image
```

This builds: `spark-etl:local`

## 7) Submit the Spark job

```bash
kubectl apply -f k8s/spark-app.yaml
```

Watch:

```bash
kubectl -n spark-etl-mysql get sparkapplications
kubectl -n spark-etl-mysql describe sparkapplication mysql-fixedwidth-etl
kubectl -n spark-etl-mysql get pods -l spark-role=driver
kubectl -n spark-etl-mysql logs -l spark-role=driver -f
```

## 8) Retrieve output

The job writes to `/output/fixedwidth.txt` inside the driver/executor pods, backed by the output PVC.

To view via a temporary pod:

```bash
kubectl -n spark-etl-mysql apply -f k8s/storage/output-reader-pod.yaml
kubectl -n spark-etl-mysql exec -it pod/output-reader -- sh -lc "ls -lah /output && echo '---' && sed -n '1,20p' /output/fixedwidth.txt"
```

Cleanup:

```bash
kubectl -n spark-etl-mysql delete pod/output-reader
```

## Troubleshooting

- **MySQL pod failing**: check logs; ensure PVC permissions are corrected (initContainer handles chown) and Docker Desktop memory is sufficient (2–4 GB for MySQL is plenty).
- **Spark image not found**: ensure you built `spark-etl:local` in Docker Desktop’s Docker context.
- **JDBC errors**: confirm the real `mysql-connector-j.jar` is in the image (`/opt/bitnami/spark/jars/`), and the service DNS is correct.
- **PVC Pending**: ensure Docker Desktop Kubernetes supports `hostPath` on its node; check PV exists and matches PVC `storageClassName`.

## Notes

- MySQL service is **ClusterIP** (in-cluster access only).
- This setup avoids Kind and uses Docker Desktop’s built-in Kubernetes directly.

