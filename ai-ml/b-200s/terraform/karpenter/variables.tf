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
  default     = "1.14.0"
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

variable "efa_device_plugin_version" {
  description = "AWS EFA Kubernetes device plugin chart version (aws-efa-k8s-device-plugin, from eks-charts)."
  type        = string
  default     = "v0.5.29"
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


