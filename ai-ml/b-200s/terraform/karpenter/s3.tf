locals {
  s3_models_sa_namespace = "default"
  s3_models_sa_name      = "model-storage-sa"
}

resource "aws_s3_bucket" "models" {
  bucket_prefix = "${local.name}-models-"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "models" {
  bucket                  = aws_s3_bucket.models.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_iam_role" "models" {
  name_prefix        = "${local.name}-models-"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy" "models" {
  name_prefix = "${local.name}-models-"
  role        = aws_iam_role.models.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "s3:GetObject",
        "s3:PutObject",
        "s3:ListBucket",
        "s3:DeleteObject",
      ]
      Resource = [
        aws_s3_bucket.models.arn,
        "${aws_s3_bucket.models.arn}/*",
      ]
    }]
  })
}

resource "kubernetes_service_account_v1" "models" {
  metadata {
    name      = local.s3_models_sa_name
    namespace = local.s3_models_sa_namespace
  }

  depends_on = [module.eks]
}

resource "aws_eks_pod_identity_association" "models" {
  cluster_name    = module.eks.cluster_name
  namespace       = local.s3_models_sa_namespace
  service_account = local.s3_models_sa_name
  role_arn        = aws_iam_role.models.arn
}

