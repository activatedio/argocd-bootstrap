# Cluster Resources
This directory holds cluster-scoped resources applied to cluster `in-cluster`
(the cluster Argo CD runs in) — for example shared `Namespace`s or `CRD`s used
by multiple applications. The `cluster-resources` ApplicationSet syncs everything
here; drop a manifest in and commit.
