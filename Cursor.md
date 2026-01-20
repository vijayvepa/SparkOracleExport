You are my project generator. Create a complete Spark-on-Kubernetes ETL project designed specifically for Docker Desktop’s built‑in Kubernetes cluster. The project must run entirely on my local machine without Kind.

PROJECT GOAL:
Build a local Spark-on-Kubernetes ETL pipeline that:
1. Uses Docker Desktop’s Kubernetes cluster (no Kind).
2. Deploys Oracle XE (or Oracle-compatible DB) inside the cluster.
3. Deploys the Spark Operator via Helm.
4. Builds a custom Spark Docker image with the Oracle JDBC driver.
5. Runs a Spark job that:
   - Reads data from Oracle via JDBC.
   - Applies transformations.
   - Generates fixed-width output using metadata-driven padding rules.
   - Writes the output to a mounted directory or PVC.

FOLDER STRUCTURE:
Create the following structure with real content where appropriate:

spark-k8s-etl/
│
├── charts/
│   └── spark-operator/                # Helm chart reference or instructions
│
├── k8s/
│   ├── namespace.yaml
│   ├── spark-operator-values.yaml
│   ├── spark-app.yaml                 # SparkApplication CRD
│   ├── oracle/
│   │   ├── deployment.yaml            # Oracle XE deployment for Docker Desktop K8s
│   │   ├── service.yaml
│   │   └── init/
│   │       └── sample-data.sql        # Sample table + inserts
│   └── storage/
│       └── pvc.yaml                   # Persistent volume for Oracle
│
├── docker/
│   └── spark/
│       ├── Dockerfile                 # Spark image with JDBC driver
│       └── drivers/
│           └── ojdbc8.jar             # Placeholder text
│
├── src/
│   └── main/
│       └── python/
│           └── etl_job.py             # Spark ETL job
│
├── config/
│   └── layout.json                    # Fixed-width metadata
│
├── scripts/
│   ├── build-spark-image.sh
│   ├── deploy-oracle.sh
│   ├── deploy-spark-operator.sh
│   └── submit.sh                      # Optional local spark-submit
│
└── README.md                          # Full instructions

CONTENT REQUIREMENTS:

1. **Oracle sample SQL**
   - Create CUSTOMERS table
   - Insert 3–5 rows

2. **Spark ETL job (Python)**
   - Reads from Oracle using JDBC
   - Loads layout.json
   - Applies lpad/rpad based on metadata
   - Concatenates into fixed-width record
   - Writes to /output (PVC-backed)

3. **layout.json**
   - ID (10, num)
   - NAME (30, char)
   - STATE (2, char)
   - BALANCE (12, num)

4. **SparkApplication CRD**
   - Uses custom Spark image
   - Points to etl_job.py
   - 1 driver, 2 executors
   - Mounts PVC for output

5. **Dockerfile**
   - Based on bitnami/spark
   - Copies JDBC driver into jars/

6. **Docker Desktop Kubernetes specifics**
   - Use hostPath or local-path storage class
   - No Kind config
   - No nodePort hacks unless needed
   - Use ClusterIP for Oracle service
   - Ensure Oracle pod has enough memory (Docker Desktop defaults are low)

7. **README.md**
   Include step-by-step instructions:
   - Enable Kubernetes in Docker Desktop
   - Install kubectl + Helm
   - Deploy namespace
   - Deploy Oracle XE
   - Load sample SQL
   - Deploy Spark Operator
   - Build Spark image
   - Submit Spark job
   - Retrieve fixed-width output from PVC

STYLE:
- Use clean, production-quality YAML, Python, and Bash.
- Add comments explaining key sections.
- Avoid unnecessary complexity.
- Everything must run locally on Docker Desktop Kubernetes with minimal dependencies.

Generate the entire project now.