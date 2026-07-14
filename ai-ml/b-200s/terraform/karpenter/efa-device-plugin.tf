# AL2023 GPU AMIs ship the EFA host-level components, but not the Kubernetes device plugin.
# Advertises EFA network interfaces as the vpc.amazonaws.com/efa extended resource.
resource "helm_release" "efa_device_plugin" {
  name             = "efa"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://aws.github.io/eks-charts"
  chart            = "aws-efa-k8s-device-plugin"
  version          = var.efa_device_plugin_version
  wait             = true
  cleanup_on_fail  = true
  replace          = true

  values = [
    yamlencode({
      # Static GPU NodePools taint nodes with nvidia.com/gpu:NoSchedule; without a matching
      # toleration the plugin's DaemonSet pods never schedule onto the GPU nodes.
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        },
      ]
    })
  ]

  depends_on = [module.eks]
}
