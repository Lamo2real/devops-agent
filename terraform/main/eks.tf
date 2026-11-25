# -----------------------------------------------------------------------------
# Read-only Kubernetes access (EKS access entries). AmazonEKSViewPolicy reads
# workloads, events and pods but not Secrets. For GitOps objects (Argo CD
# Applications, Argo Workflows) add a ClusterRole + binding for the group
# below in the cluster; see README.md.
# -----------------------------------------------------------------------------

resource "aws_eks_access_entry" "agent" {
  for_each          = toset(var.eks_cluster_names)
  cluster_name      = each.value
  principal_arn     = aws_iam_role.agentspace.arn
  kubernetes_groups = ["devops-agent-readers"]
  type              = "STANDARD"
}

resource "aws_eks_access_policy_association" "agent_view" {
  for_each      = toset(var.eks_cluster_names)
  cluster_name  = each.value
  principal_arn = aws_iam_role.agentspace.arn
  policy_arn    = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSViewPolicy"
  access_scope {
    type = "cluster"
  }
  depends_on = [aws_eks_access_entry.agent]
}
