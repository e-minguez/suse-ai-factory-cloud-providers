# Exercises the exact case a hand-rolled parser gets wrong: optional()
# defaults declared in the TYPE expression, not in `default`. Trailing commas
# throughout, since real hand-edited tfvars carry them.
region = "ams"

gpu_bare_metal_pools = {
  gpu = {
    plan  = "vbm-6c-32gb-amd",
    count = 2,
  },
  # count omitted entirely -- must resolve to 1 (variables.tf:277's
  # `optional(number, 1)`).
  solo = {
    plan = "vbm-6c-32gb-amd",
  },
  # explicit zero, distinct from "solo" above: must stay 0, not be treated as
  # omitted.
  off = {
    plan  = "vbm-6c-32gb-amd",
    count = 0,
  },
}

gpu_cloud_pools = {
  cgpu = {
    plan     = "voc-c-4c-8gb-150s-amd",
    count    = 1,
    vpc_only = false,
  },
  # count AND vpc_only both omitted -- count must resolve to 1
  # (variables.tf:314) and vpc_only to true (variables.tf:316).
  bare = {
    plan = "voc-c-4c-8gb-150s-amd",
  },
}
