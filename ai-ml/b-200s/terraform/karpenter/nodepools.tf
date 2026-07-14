# General-purpose, untainted NodePool/NodeClass for non-GPU workloads (e.g. MPI Operator) so they
# don't need to tolerate the gpu-static NodePool's taint or the system MNG's CriticalAddonsOnly
# taint. Named to match EKS Auto Mode's built-in "general-purpose" node pool. GPU NodePools for
# this guide (nodeclass-gpu-static.yaml, nodepool-gpu-static.yaml) are applied manually with
# kubectl - see ../../README.md.

resource "kubectl_manifest" "general_purpose_nodeclass" {
  yaml_body = templatefile("${path.module}/nodepools/nodeclass-general-purpose.yaml", {
    cluster_name       = local.name
    node_iam_role_name = module.karpenter.node_iam_role_name
  })

  depends_on = [module.eks]
}

resource "kubectl_manifest" "general_purpose_nodepool" {
  yaml_body = file("${path.module}/nodepools/nodepool-general-purpose.yaml")

  depends_on = [kubectl_manifest.general_purpose_nodeclass, module.eks]
}
