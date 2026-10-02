# 006 - vultr deploys in two passes

## Status
Accepted.

## Context
`vultr_load_balancer` carries its backends (`attached_instances`) and forwarding
and firewall rules as inline fields; the provider has no separate attachment
resource. The load balancer address is part of the image (`api_vip`,
`api_host`, Rancher hostname), the nodes boot from the snapshot of that image,
and the backend list references the nodes. In one apply that is a dependency
cycle.

The snapshot import also needs a tcp/80 rule on the jumphost
(`vultr_firewall_rule`), which has to be removed after the import; a resource
cannot be created and destroyed in the same apply.

Alternatives considered:
- Pass the load balancer address to nodes through per-node `user_data` instead
  of the image. The cycle remains: the address and the backend list are fields
  of the same resource.
- Attach backends with a script calling the Vultr API. Terraform would no
  longer track the backends, and drift would go unnoticed.

## Decision
Keep two passes ([docs/providers/vultr.md](../providers/vultr.md#passes-2-and-why)).
Pass 1 creates the load balancers with no backends, the jumphost, the image and
the nodes. Pass 2 attaches the backends from `provider_details` through
`pass2.auto.tfvars.json` and sets `image_import_port_open = false`.

## Consequences
- Pass 1 keeps the pinned values unless its plan replaces a node, the NAT
  gateway or the snapshot, or creates a load balancer; only then are the
  backends detached until pass 2.
- `deploy.sh` is the supported entry point; a bare `terraform apply` after pass 2
  keeps the pinned values, but a replaced node needs `./deploy.sh` to be
  re-attached.
- Revisit when the vultr provider offers a separate load balancer attachment
  resource.
