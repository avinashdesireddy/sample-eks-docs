output "region" {
  description = "AWS region the deployment was applied to."
  value       = var.region
}

output "cluster_name" {
  description = "EKS cluster name."
  value       = module.eks.cluster_name
}

output "configure_kubectl" {
  description = "Command to point kubectl at the cluster."
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name} --alias ${module.eks.cluster_name}"
}

output "node_iam_role_name" {
  description = "Karpenter node IAM role name. Plug into the reserved-capacity EC2NodeClass when applying it manually."
  value       = module.karpenter.node_iam_role_name
}

output "model_bucket" {
  description = "S3 bucket for model weights."
  value       = aws_s3_bucket.models.id
}

output "configure_model_bucket" {
  description = "Command to export the model bucket name for the guide steps."
  value       = "export MODEL_BUCKET=${aws_s3_bucket.models.id}"
}
