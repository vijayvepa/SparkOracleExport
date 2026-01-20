# 📘 **README.md — Cleaning Stuck PVC/PV on Docker Desktop Kubernetes**

## Overview
Docker Desktop’s built‑in Kubernetes frequently leaves **PersistentVolumeClaims (PVCs)** and **PersistentVolumes (PVs)** stuck in a `Terminating` state. This happens because:

- Kubernetes adds **protection finalizers** to PVCs and PVs  
- Docker Desktop uses a hidden Linux VM  
- `hostPath` volumes create directories inside that VM  
- Those directories remain even after workloads are deleted  
- Kubernetes refuses to finalize the PV/PVC until the directory is removed  

This creates a deadlock:

- PVC cannot delete because PV is stuck  
- PV cannot delete because hostPath still exists  
- Both have finalizers blocking cleanup  

This project includes a script, **CleanPV.sh**, that resolves this safely and consistently.

---

## Symptoms
You’ll see something like:

```
PVC: Terminating
PV: Bound
PVC status: Lost
```

Or:

```
kubectl delete pvc <name>
persistentvolumeclaims "<name>" is forbidden: PVC is being deleted
```

Or:

```
kubectl delete pv <name>
persistentvolume "<name>" is forbidden: PV is being deleted
```

---

## Root Cause
Your PV YAML will show:

```yaml
finalizers:
- kubernetes.io/pv-protection
```

Your PVC YAML will show:

```yaml
finalizers:
- kubernetes.io/pvc-protection
```

And the PV will reference a hostPath:

```yaml
hostPath:
  path: /var/lib/<something>
```

That directory still exists inside Docker Desktop’s VM, so Kubernetes refuses to finalize deletion.

---

## Solution Summary
To fully clean up a stuck PVC/PV pair, you must:

1. **Remove the PVC finalizer**
2. **Remove the PV finalizer**
3. **Delete the hostPath directory inside the Docker Desktop VM**
4. **Force delete the PVC and PV**

The included script automates all of this.

---

## Usage

```
chmod +x CleanPV.sh
./CleanPV.sh <namespace> <pvc-name>
```

Example:

```
./CleanPV.sh spark-etl-mysql etl-output-pvc
```

The script will:

- Detect the PV bound to the PVC  
- Remove PVC finalizers  
- Remove PV finalizers  
- Enter the Docker Desktop VM  
- Delete the hostPath directory  
- Force delete both PVC and PV  

---

## After Cleanup
You can safely recreate:

- The PVC  
- The PV  
- Any Spark jobs or workloads that use them  

This ensures your local Kubernetes environment stays clean and avoids future deadlocks.

---

If you want, I can also generate:

- A version of the script that logs actions to a file  
- A Makefile wrapper  
- A Kubernetes Job that performs cleanup automatically  
- A Helm hook to clean PVs before uninstalling a chart
