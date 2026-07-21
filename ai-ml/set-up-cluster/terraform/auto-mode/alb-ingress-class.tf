# EKS Auto Mode has an ALB controller built into the control plane - no Helm install or IAM
# policy needed (unlike the karpenter/ variant). Creating an Ingress is enough to provision an
# ALB; this just sets up a default IngressClass so Ingress resources don't need to specify one.
# See https://docs.aws.amazon.com/eks/latest/userguide/auto-configure-alb.html
resource "kubectl_manifest" "alb_ingress_class_params" {
  yaml_body = yamlencode({
    apiVersion = "eks.amazonaws.com/v1"
    kind       = "IngressClassParams"
    metadata = {
      name = "alb"
    }
    spec = {
      scheme = "internet-facing"
    }
  })

  depends_on = [module.eks]
}

resource "kubectl_manifest" "alb_ingress_class" {
  yaml_body = yamlencode({
    apiVersion = "networking.k8s.io/v1"
    kind       = "IngressClass"
    metadata = {
      name = "alb"
      annotations = {
        "ingressclass.kubernetes.io/is-default-class" = "true"
      }
    }
    spec = {
      controller = "eks.amazonaws.com/alb"
      parameters = {
        apiGroup = "eks.amazonaws.com"
        kind     = "IngressClassParams"
        name     = "alb"
      }
    }
  })

  depends_on = [kubectl_manifest.alb_ingress_class_params]
}
