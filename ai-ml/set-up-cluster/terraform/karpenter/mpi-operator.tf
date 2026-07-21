# MPI Operator (Kubeflow) - manages distributed MPI jobs (MPIJob CRD), e.g. the NCCL EFA test.
# No official Helm chart; upstream recommends kubectl apply against the release manifest.
# https://github.com/kubeflow/mpi-operator
#
# Gated by var.enable_efa - MPIJob is primarily useful for EFA-based multi-node training/testing
# (see ../README.md). The operator's Deployment pod has no tolerations/nodeSelector, so it
# schedules onto the untainted `general-purpose` NodePool (nodepools.tf) rather than the tainted
# GPU or system nodes.
locals {
  mpi_operator_version = "v0.8.0"
}

data "http" "mpi_operator_manifest" {
  count = var.enable_efa ? 1 : 0

  url = "https://raw.githubusercontent.com/kubeflow/mpi-operator/${local.mpi_operator_version}/deploy/v2beta1/mpi-operator.yaml"
}

data "kubectl_file_documents" "mpi_operator" {
  count = var.enable_efa ? 1 : 0

  content = data.http.mpi_operator_manifest[0].response_body
}

resource "kubectl_manifest" "mpi_operator" {
  for_each = var.enable_efa ? data.kubectl_file_documents.mpi_operator[0].manifests : {}

  yaml_body = each.value

  server_side_apply = true

  depends_on = [module.eks]
}
