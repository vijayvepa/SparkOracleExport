#!/bin/bash

# CleanPV.sh
# Utility script to fix stuck PVC/PV resources on Docker Desktop Kubernetes
# by removing finalizers and cleaning hostPath directories inside the VM.

NAMESPACE=$1
PVC_NAME=$2

if [ -z "$NAMESPACE" ] || [ -z "$PVC_NAME" ]; then
  echo "Usage: ./CleanPV.sh <namespace> <pvc-name>"
  exit 1
fi

echo "🔍 Fetching PV name for PVC: $PVC_NAME in namespace: $NAMESPACE"
PV_NAME=$(kubectl -n "$NAMESPACE" get pvc "$PVC_NAME" -o jsonpath='{.spec.volumeName}')

if [ -z "$PV_NAME" ]; then
  echo "❌ Could not find PV for PVC $PVC_NAME"
  exit 1
fi

echo "📦 PVC is bound to PV: $PV_NAME"

echo "🧽 Removing PVC finalizers..."
kubectl -n "$NAMESPACE" patch pvc "$PVC_NAME" -p '{"metadata":{"finalizers":null}}' --type=merge

echo "🧽 Removing PV finalizers..."
kubectl patch pv "$PV_NAME" -p '{"metadata":{"finalizers":null}}' --type=merge

echo "📁 Checking hostPath directory for PV..."
HOSTPATH=$(kubectl get pv "$PV_NAME" -o jsonpath='{.spec.hostPath.path}')

if [ -z "$HOSTPATH" ]; then
  echo "⚠️ No hostPath found on PV. Skipping VM cleanup."
else
  echo "🖥  Entering Docker Desktop VM to remove hostPath directory: $HOSTPATH"
  docker run --rm -it --privileged --pid=host justincormack/nsenter1 sh -c "rm -rf $HOSTPATH"
  echo "✔️  hostPath directory removed."
fi

echo "🗑  Forcing deletion of PVC and PV..."
kubectl -n "$NAMESPACE" delete pvc "$PVC_NAME" --force --grace-period=0
kubectl delete pv "$PV_NAME" --force --grace-period=0

echo "🎉 Cleanup complete. PVC and PV should now be removed."