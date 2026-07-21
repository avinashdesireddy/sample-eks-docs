variable "region" {
  description = "AWS region the deployment lands in."
  type        = string
  nullable    = false
  default     = "us-east-2"
}

variable "cluster_name" {
  description = "Name of the EKS cluster. Also used as the prefix for related resource names and the value of the PartOf tag."
  type        = string
  default     = "ai-eks-docs"
}

variable "kubernetes_version" {
  description = "Kubernetes minor version for the EKS control plane."
  type        = string
  default     = "1.36"
}

variable "karpenter_version" {
  description = "Karpenter chart version (CRD + controller releases)."
  type        = string
  default     = "1.13.0"
}

variable "enable_karpenter_node_repair" {
  description = "Enable Karpenter's nodeRepair feature gate (alpha as of chart 1.12.0). Replaces unhealthy Karpenter-launched nodes based on eks-node-monitoring-agent signals."
  type        = bool
  default     = true
}

variable "nvidia_device_plugin_version" {
  description = "NVIDIA k8s-device-plugin chart version."
  type        = string
  default     = "0.19.1"
}

variable "allowed_cidrs" {
  description = "CIDRs allowed to reach any publicly accessible endpoint this stack creates (EKS API, ALB)."
  type        = list(string)
  default     = ["0.0.0.0/0"]
}

variable "enable_amazon_prometheus" {
  description = "Provision an Amazon Managed Prometheus workspace and IAM for the scraper."
  type        = bool
  default     = true
}

variable "kube_prometheus_stack_version" {
  description = "kube-prometheus-stack chart version."
  type        = string
  default     = "85.0.1"
}

variable "enable_dcgm_exporter" {
  description = "Install the NVIDIA DCGM exporter on GPU nodes for Prometheus scraping."
  type        = bool
  default     = true
}

variable "dcgm_exporter_version" {
  description = "NVIDIA dcgm-exporter chart version."
  type        = string
  default     = "4.8.2"
}

variable "nodepools" {
  description = <<-EOT
    GPU NodePool strategies to enable, keyed by folder name under nodepools/. Defaults to
    { "spot-ondemand" = {} }. Set `reservation` on a strategy to have Terraform create a
    tagged On-Demand Capacity Reservation (ODCR) for it; the NodeClass selects it by the
    nodepool=<key> tag. An ODCR bills immediately until destroyed.

    spot-ondemand and reserved-spot-ondemand both manage the gpu-inf pool and are
    mutually exclusive. To add a strategy: create nodepools/<name>/ and add <name> to the validation list.
  EOT
  type = map(object({
    reservation = optional(object({
      instance_type  = optional(string, "g6e.4xlarge")
      instance_count = optional(number, 1)
      az             = optional(string, "") # defaults to the first cluster AZ
    }))
  }))
  default = { "spot-ondemand" = {} }

  validation {
    condition = alltrue([
      for k in keys(var.nodepools) : contains([
        "spot-ondemand",
        "reserved-spot-ondemand",
        "static-spot-ondemand",
      ], k)
    ])
    error_message = "Each key must be an existing strategy folder under nodepools/."
  }

  validation {
    condition = length(setintersection(keys(var.nodepools), [
      "spot-ondemand",
      "reserved-spot-ondemand",
      "static-spot-ondemand",
    ])) <= 1
    error_message = "Enable at most one GPU inference strategy (spot-ondemand, reserved-spot-ondemand, static-spot-ondemand); each is a complete solution for the gpu-inf workload."
  }

  validation {
    condition = alltrue([
      for k, v in var.nodepools :
      contains(["reserved-spot-ondemand", "static-spot-ondemand"], k) ? v.reservation != null : true
    ])
    error_message = "reserved-spot-ondemand and static-spot-ondemand require a `reservation` (their reserved nodes run on an ODCR)."
  }
}
