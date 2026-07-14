# AL2023 NVIDIA AMI ships drivers, but not the device plugin.
resource "helm_release" "nvidia_device_plugin" {
  name             = "nvidia-device-plugin"
  namespace        = "kube-system"
  create_namespace = false
  repository       = "https://nvidia.github.io/k8s-device-plugin"
  chart            = "nvidia-device-plugin"
  version          = var.nvidia_device_plugin_version
  disable_webhooks = true
  wait             = true
  cleanup_on_fail  = true
  replace          = true

  values = [
    yamlencode({
      # Disable the Mellanox OFED (InfiniBand) check — AWS does not use it.
      mofedEnabled = false

      nodeSelector = {
        amiFamily = "al2023"
      }
      tolerations = [
        {
          key      = "nvidia.com/gpu"
          operator = "Exists"
          effect   = "NoSchedule"
        },
      ]

      # DaemonSet — target al2023 GPU nodes only
      gfd = {
        enabled = true
        nodeSelector = {
          amiFamily = "al2023"
        }
        tolerations = [
          {
            key      = "nvidia.com/gpu"
            operator = "Exists"
            effect   = "NoSchedule"
          },
        ]
      }

      nfd = {
        # Target system MNG (CriticalAddonsOnly-tainted)
        master = {
          nodeSelector = {
            "node-role" = "system"
          }
          tolerations = [
            {
              key      = "CriticalAddonsOnly"
              operator = "Exists"
            },
          ]
        }

        # Target system MNG (CriticalAddonsOnly-tainted)
        gc = {
          nodeSelector = {
            "node-role" = "system"
          }
          tolerations = [
            {
              key      = "CriticalAddonsOnly"
              operator = "Exists"
            },
          ]
        }

        # DaemonSet — target al2023 GPU nodes only
        worker = {
          nodeSelector = {
            amiFamily = "al2023"
          }
          tolerations = [
            {
              key      = "nvidia.com/gpu"
              operator = "Exists"
              effect   = "NoSchedule"
            },
          ]
        }
      }
    })
  ]

  depends_on = [module.eks]
}
