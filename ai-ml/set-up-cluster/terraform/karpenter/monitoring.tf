locals {
  monitoring_namespace             = "monitoring"
  amp_remote_write_service_account = "amp-remote-writer"
  grafana_service_account          = "grafana-sa"
}

#---------------------------------------------------------------
# AMP remote write permissions
#---------------------------------------------------------------

resource "aws_prometheus_workspace" "amp" {
  count = var.enable_amazon_prometheus ? 1 : 0

  alias = local.name
}

data "aws_iam_policy_document" "amp_remote_write" {
  count = var.enable_amazon_prometheus ? 1 : 0

  statement {
    effect    = "Allow"
    actions   = ["aps:RemoteWrite"]
    resources = [aws_prometheus_workspace.amp[0].arn]
  }
}

resource "aws_iam_policy" "amp_remote_write" {
  count = var.enable_amazon_prometheus ? 1 : 0

  name   = "${local.name}-amp-remote-write"
  policy = data.aws_iam_policy_document.amp_remote_write[0].json
}

resource "aws_iam_role" "amp_remote_write" {
  count = var.enable_amazon_prometheus ? 1 : 0

  name               = "${local.name}-amp-remote-write"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "amp_remote_write" {
  count = var.enable_amazon_prometheus ? 1 : 0

  role       = aws_iam_role.amp_remote_write[0].name
  policy_arn = aws_iam_policy.amp_remote_write[0].arn
}

resource "aws_eks_pod_identity_association" "amp_remote_write" {
  count = var.enable_amazon_prometheus ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = local.monitoring_namespace
  service_account = local.amp_remote_write_service_account
  role_arn        = aws_iam_role.amp_remote_write[0].arn
}

#---------------------------------------------------------------
# Grafana query permissions
#---------------------------------------------------------------

data "aws_iam_policy_document" "amp_query" {
  count = var.enable_amazon_prometheus ? 1 : 0

  statement {
    effect = "Allow"
    actions = [
      "aps:QueryMetrics",
      "aps:GetSeries",
      "aps:GetLabels",
      "aps:GetMetricMetadata",
      "aps:DescribeWorkspace",
    ]
    resources = [aws_prometheus_workspace.amp[0].arn]
  }
}

resource "aws_iam_policy" "amp_query" {
  count = var.enable_amazon_prometheus ? 1 : 0

  name   = "${local.name}-amp-query"
  policy = data.aws_iam_policy_document.amp_query[0].json
}

resource "aws_iam_role" "grafana" {
  count = var.enable_amazon_prometheus ? 1 : 0

  name               = "${local.name}-grafana"
  assume_role_policy = data.aws_iam_policy_document.pod_identity_assume.json
}

resource "aws_iam_role_policy_attachment" "grafana" {
  count = var.enable_amazon_prometheus ? 1 : 0

  role       = aws_iam_role.grafana[0].name
  policy_arn = aws_iam_policy.amp_query[0].arn
}

resource "aws_eks_pod_identity_association" "grafana" {
  count = var.enable_amazon_prometheus ? 1 : 0

  cluster_name    = module.eks.cluster_name
  namespace       = local.monitoring_namespace
  service_account = local.grafana_service_account
  role_arn        = aws_iam_role.grafana[0].arn
}

#---------------------------------------------------------------
# kube-prometheus-stack
#---------------------------------------------------------------

resource "helm_release" "kube_prometheus_stack" {
  count = var.enable_amazon_prometheus ? 1 : 0

  name             = "kube-prometheus-stack"
  namespace        = local.monitoring_namespace
  create_namespace = true
  repository       = "https://prometheus-community.github.io/helm-charts"
  chart            = "kube-prometheus-stack"
  version          = var.kube_prometheus_stack_version
  cleanup_on_fail  = true
  replace          = true

  values = [
    templatefile("${path.module}/helm-values/kube-prometheus.yml", {
      region                     = var.region
      amp_endpoint               = aws_prometheus_workspace.amp[0].prometheus_endpoint
      remote_write_url           = "${aws_prometheus_workspace.amp[0].prometheus_endpoint}api/v1/remote_write"
      prometheus_service_account = local.amp_remote_write_service_account
      grafana_service_account    = local.grafana_service_account
    })
  ]

  depends_on = [
    module.eks,
    aws_eks_pod_identity_association.amp_remote_write,
    aws_eks_pod_identity_association.grafana,
  ]
}

#---------------------------------------------------------------
# DCGM exporter (GPU metrics)
#---------------------------------------------------------------

resource "helm_release" "dcgm_exporter" {
  count = var.enable_amazon_prometheus && var.enable_dcgm_exporter ? 1 : 0

  name            = "dcgm-exporter"
  namespace       = local.monitoring_namespace
  repository      = "https://nvidia.github.io/dcgm-exporter/helm-charts"
  chart           = "dcgm-exporter"
  version         = var.dcgm_exporter_version
  cleanup_on_fail = true
  replace         = true

  values = [
    templatefile("${path.module}/helm-values/dcgm-exporter.yml", {})
  ]

  depends_on = [module.eks, helm_release.kube_prometheus_stack]
}