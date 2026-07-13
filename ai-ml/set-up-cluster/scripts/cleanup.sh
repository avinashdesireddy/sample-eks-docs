#!/bin/bash

set -euo pipefail

[[ -f main.tf && -f eks.tf ]] || { echo "Run from terraform/auto-mode/ or terraform/karpenter/" >&2; exit 1; }

options=()
[[ "${1:-}" == "--auto-approve" ]] && options=(-input=false -auto-approve)

deployment_name=$(terraform output -raw cluster_name 2>/dev/null || true)
region=$(terraform output -raw region 2>/dev/null || true)

kubeconfig_cmd=$(terraform output -raw configure_kubectl 2>/dev/null || true)
[[ -n "$kubeconfig_cmd" ]] && eval "$kubeconfig_cmd" >/dev/null 2>&1 || true

echo "Draining PDBs"
kubectl delete pdb -A --all 2>/dev/null || true

echo "Draining Karpenter NodeClaims"
kubectl delete nodeclaim --all --wait=true --timeout=900s 2>/dev/null || true

echo "Draining Karpenter NodePools"
kubectl delete nodepool --all --wait=true --timeout=120s 2>/dev/null || true

echo "Draining Karpenter EC2NodeClasses"
kubectl delete ec2nodeclass --all --wait=true --timeout=120s 2>/dev/null || true

echo "Running terraform destroy"
terraform destroy ${options[@]+"${options[@]}"}

echo "Sweeping orphan EBS volumes"
if [[ -n "$deployment_name" && -n "$region" ]]; then
  while IFS= read -r vol_id; do
    [[ -n "$vol_id" ]] && AWS_REGION="$region" aws ec2 delete-volume --volume-id "$vol_id" || true
  done < <(AWS_REGION="$region" aws ec2 describe-volumes \
    --filters "Name=tag:kubernetes.io/cluster/${deployment_name},Values=owned" \
    --query 'Volumes[].VolumeId' --output text 2>/dev/null | tr '\t' '\n')
fi

echo "Cleanup complete"
