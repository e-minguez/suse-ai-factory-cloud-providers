# Cost-relevant subset of an azure terraform.tfvars; the golden tests use it
# so provider-credential variables do not leak into the output.
region       = "westeurope"
cluster_name = "suse-ai-factory"
deploy_nodes = false
