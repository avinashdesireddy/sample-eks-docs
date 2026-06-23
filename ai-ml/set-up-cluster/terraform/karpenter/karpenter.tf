module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.20.0"

  cluster_name = module.eks.cluster_name
  namespace    = "kube-system"

  iam_role_name      = "${local.name}-karpenter-controller"
  node_iam_role_name = "${local.name}-karpenter-node"

  # Bundled controller policy exceeds the 6144-char managed-policy limit — inline policies allow up to 10240.
  # See https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_iam-quotas.html.
  enable_inline_policy = true

  create_pod_identity_association = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
    # Authenticate to public ECR (public.ecr.aws) so image pulls aren't anonymous and rate-limited.
    AmazonElasticContainerRegistryPublicReadOnly = "arn:aws:iam::aws:policy/AmazonElasticContainerRegistryPublicReadOnly"
  }
}

# CRDs ship in a separate chart from the controller — install first so the controller release can reference them.
resource "helm_release" "karpenter_crd" {
  name             = "karpenter-crd"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter-crd"
  version          = var.karpenter_version
  wait             = true
  take_ownership   = true
  cleanup_on_fail  = true
  replace          = true

  depends_on = [module.eks, module.karpenter]
}

resource "helm_release" "karpenter" {
  name             = "karpenter"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "oci://public.ecr.aws/karpenter"
  chart            = "karpenter"
  version          = var.karpenter_version
  wait             = true
  skip_crds        = true
  cleanup_on_fail  = true
  replace          = true

  values = [
    yamlencode({
      nodeSelector = {
        "node-role" = "system"
      }
      tolerations = [
        {
          key      = "CriticalAddonsOnly"
          operator = "Exists"
        },
        {
          key      = "karpenter.sh/controller"
          operator = "Exists"
          effect   = "NoSchedule"
        },
      ]
      settings = {
        clusterName       = module.eks.cluster_name
        clusterEndpoint   = module.eks.cluster_endpoint
        interruptionQueue = module.karpenter.queue_name
        featureGates = {
          nodeRepair = var.enable_karpenter_node_repair
        }
      }
      webhook = {
        enabled = false
      }
    })
  ]

  depends_on = [module.eks, helm_release.karpenter_crd]
}
