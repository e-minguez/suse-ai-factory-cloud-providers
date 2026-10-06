# Architecture

Diagrams of the deploy flow, the image pipeline, the passes per provider and the
network per provider. They show roles (see [conventions](conventions.md#labels))
and the main resource types; exact resource names, conditions and the reasons
behind each step are in the [provider notes](providers/aws.md) and the
[decision records](decisions/README.md).

## Deploy flow

`deploy.sh` defines the passes; `scripts/lib/tf.sh` runs each one the same way.

```mermaid
flowchart TD
    vars["Var files, later wins:<br/>common-all.tfvars → common-#lt;provider#gt;.tfvars → terraform.tfvars"]
    rebuild["--rebuild: image_rebuild + 1<br/>in rebuild.auto.tfvars.json"]
    vars --> deploy["deploy.sh"]
    rebuild -.-> deploy
    deploy --> plan["terraform plan -out"]
    plan --> report["List replacements and destroys"]
    report --> confirm{"Confirm<br/>(skipped with --yes)"}
    confirm -- no --> stop["Exit, nothing applied"]
    confirm -- yes --> apply["terraform apply -json #lt;saved plan#gt;<br/>rendered by jq, logs in .deploy/logs/#lt;ts#gt;/"]
    apply --> more{"More passes?"}
    more -- yes --> plan
    more -- no --> next["next_steps output:<br/>Rancher URL, kubeconfig.sh, ssh.sh"]
    deploy -->|"--destroy"| destroy["plan -destroy → confirm → apply"]
    destroy --> leftovers["Suggest tools/leftovers/#lt;provider#gt;.sh<br/>(printed, not run)"]
```

## Image pipeline

Every node boots one Elemental image built for the cluster. The image is rebuilt
only when `build_hash` changes; roles and hostnames go in per-node Ignition, so
changing the node set does not rebuild it.

```mermaid
flowchart TD
    subgraph plan_time ["Plan time (workstation)"]
        inputs["tfvars, AI Factory release manifest (http),<br/>elemental_image, core_platform_override,<br/>sysext overrides, image_rebuild"]
        ec["modules/elemental-config<br/>Elemental, RKE2 and Helm files"]
        ign["modules/elemental-config<br/>per-node Ignition (user_data)"]
        hash["build_hash → build_id"]
        fac["modules/image-factory<br/>build script + provider hooks"]
        inputs --> ec
        ec --> hash
        fac -- "script_hash" --> hash
        inputs --> ign
    end

    subgraph build_host ["Build host (jumphost; evroc: one per zone)"]
        ud["cloud-init user_data:<br/>config files + build script inline"]
        cust["podman: elemental customize --type raw"]
        raw["raw image"]
        ud --> cust --> raw
    end

    ec --> ud
    fac --> ud
    hash -. "changed: new build,<br/>new image, nodes replaced" .-> ud

    raw -- "deliver hook" --> deliver

    subgraph deliver ["Image import (Terraform)"]
        aws["aws: upload to aws_s3_bucket →<br/>aws_ebs_snapshot_import → aws_ami"]
        vultr["vultr: HTTP on jumphost :80 →<br/>vultr_snapshot_from_url"]
        evroc["evroc: dd to evroc_disk (image target) →<br/>detach → evroc_snapshot per zone"]
        exoscale["exoscale: qemu-img convert to qcow2 (≥ 10 GiB),<br/>HTTP on jumphost :80 → exoscale_template"]
    end

    deliver --> nodes["Nodes: boot from the image,<br/>Ignition sets role, hostname, node-ip"]
    ign --> nodes
    nodes --> rke2["RKE2 joins through the API address →<br/>Helm: Rancher, GPU operator, AI Factory operator, ..."]
```

Terraform waits for the build from the workstation: aws polls S3
(`wait-for-raw.sh`), vultr and exoscale poll the served URL
(`wait-for-image.sh`), evroc polls the build-status relay on the jumphost
(`wait-for-image.sh`).
`scripts/build-logs.sh` follows the build log on the build host over SSH.

## Passes

What each `deploy.sh` pass creates. Why the number differs:
[README](../README.md#deployment-flow).

### aws: one pass

The internal NLB address is fixed at plan time and target group attachments
are separate resources, so everything fits in one apply.

```mermaid
flowchart TD
    subgraph p1 ["Pass 1: Deploy"]
        net["network: aws_vpc, aws_subnet (public + private per zone),<br/>aws_internet_gateway, aws_nat_gateway + aws_eip,<br/>aws_route_table, aws_vpc_endpoint (S3)"]
        iam["iam: aws_iam_role jumphost + vmimport,<br/>aws_iam_instance_profile"]
        sg["aws_security_group per role"]
        lb["lb: aws_lb api (internal, static IP) + public,<br/>aws_lb_target_group, aws_lb_listener"]
        jh["jumphost: aws_instance (builds the image)"]
        img["image: aws_s3_bucket, aws_ebs_snapshot_import, aws_ami"]
        nodes["control_plane, worker, gpu: aws_instance"]
        att["aws_lb_target_group_attachment"]
        net --> lb
        net --> jh
        iam --> jh
        sg --> jh
        lb -- "API address in the image config" --> jh
        jh --> img --> nodes --> att
    end
```

### vultr: two passes

The load balancer address is in the image and the backends are inline fields of
`vultr_load_balancer`, so the backends are attached in a second apply
([ADR 006](decisions/006-vultr-two-passes.md)).

```mermaid
flowchart TD
    subgraph p1 ["Pass 1: Create infrastructure"]
        net["network: vultr_vpc, vultr_nat_gateway"]
        fw["vultr_firewall_group + vultr_firewall_rule<br/>(incl. tcp/80 for the image import)"]
        lb["lb: vultr_load_balancer api + ingress<br/>(no backends)"]
        jh["jumphost: vultr_instance<br/>(builds and serves the image)"]
        img["image: vultr_snapshot_from_url"]
        nodes["control_plane: vultr_instance (vpc_only)<br/>worker, gpu: vultr_instance or vultr_bare_metal_server"]
        net --> lb
        net --> jh
        fw --> jh
        lb -- "LB addresses in the image config" --> jh
        jh --> img --> nodes
    end

    nodes --> pin["deploy.sh: provider_details →<br/>pass2.auto.tfvars.json"]

    subgraph p2 ["Pass 2: Attach load balancer backends"]
        att["vultr_load_balancer: attached_instances = control planes,<br/>9345 also from worker and GPU node addresses"]
        fwclose["vultr_firewall_rule: tcp/80 import rule removed,<br/>agent firewall admits the NAT gateway addresses"]
    end

    pin --> att
    pin --> fwclose
```

### evroc: two passes plus an optional third

A disk cannot be attached and detached in one apply, and snapshots are zonal,
so pass 1 writes the image to one disk per zone and pass 2 snapshots them.

```mermaid
flowchart TD
    subgraph p1 ["Pass 1: Build image (image_ready=false)"]
        net["network: evroc_vpc, evroc_subnet per zone,<br/>evroc_security_group per role"]
        vip["lb: evroc_public_ip (API VIP),<br/>evroc_loadbalancer, evroc_lb_l4_route,<br/>evroc_lb_backend_service, evroc_lb_backend_pool (empty)"]
        jh["jumphost (zones[0], public IP) +<br/>builder per other zone: evroc_virtual_machine + boot evroc_disk"]
        tgt["image: evroc_disk (image target) per zone<br/>+ evroc_hotswap_disk_attachment"]
        net --> vip
        net --> jh
        vip -- "VIP in the image config" --> jh
        tgt --> jh
        jh -- "dd raw image" --> tgt
    end

    subgraph p2 ["Pass 2: Create nodes (image_ready=true, keep_build_artifacts=true)"]
        det["destroy attachments and builders<br/>(jumphost stays)"]
        snap["image: evroc_snapshot per zone"]
        nodes["control_plane, worker, gpu:<br/>evroc_disk cloned from the zone's snapshot,<br/>evroc_virtual_machine, evroc_placement_group,<br/>optional evroc_public_ip"]
        pool["evroc_lb_backend_pool: control planes"]
        det --> snap --> nodes --> pool
    end

    subgraph p3 ["Pass 3: Reclaim build disks (optional)"]
        rm["delete the image-target disks<br/>(kept with keep_build_artifacts = true)"]
    end

    p1 --> p2 --> p3
```

Once the snapshots are in state, `deploy.sh` runs one apply with
`image_ready=true`; `--rebuild` goes through all passes again.

### exoscale: two passes

The NLB targets instance pools only and a pool has one `user_data`, so the
control plane pool starts with one init member and switches to the join
configuration in a second apply ([ADR 008](decisions/008-exoscale-module.md)).

```mermaid
flowchart TD
    subgraph p1 ["Pass 1: Bootstrap control plane (cp_initialized=false)"]
        net["network: exoscale_private_network,<br/>exoscale_security_group per role<br/>(incl. tcp/80 for the image import)"]
        lb["lb: exoscale_nlb"]
        jh["jumphost: exoscale_compute_instance<br/>(builds and serves the qcow2)"]
        img["image: exoscale_template"]
        pool["control_plane: exoscale_instance_pool, size 1,<br/>init configuration + exoscale_nlb_service"]
        ag["worker, gpu: exoscale_compute_instance"]
        wait["cp_init_ready: API answers through the NLB"]
        net --> lb
        net --> jh
        lb -- "NLB address in the image config" --> jh
        jh --> img --> pool --> wait
        img --> ag
    end

    wait --> pin["deploy.sh: cp_initialized=true,<br/>image_import_port_open=false"]

    subgraph p2 ["Pass 2: Scale control plane"]
        scale["exoscale_instance_pool: join configuration,<br/>size = control_plane_count (in place)"]
        fwclose["tcp/80 import rule removed"]
    end

    pin --> scale
    pin --> fwclose
```

Once the pool is in state, `deploy.sh` runs one apply with the pins; a new
template reopens tcp/80 and a second apply closes it.

## Network

Main traffic paths. SSH always goes through the jumphost (`ProxyJump`,
`scripts/ssh.sh`); `admin_cidrs` filters the jumphost, `api_cidrs` the public
Kubernetes API, `ingress_cidrs` ports 80/443.

### aws

```mermaid
flowchart LR
    admin(["Admin"])
    users(["Users / kubectl"])
    inet(["Internet"])

    subgraph vpc ["aws_vpc"]
        subgraph pub ["Public subnets"]
            jh["jumphost<br/>aws_instance"]
            nat["aws_nat_gateway"]
            nlbp["aws_lb public<br/>80/443, 6443"]
        end
        subgraph priv ["Private subnets"]
            nlbi["aws_lb api (internal)<br/>6443, 9345"]
            cp["control_plane<br/>aws_instance"]
            ag["worker, gpu<br/>aws_instance"]
        end
        s3e["aws_vpc_endpoint (S3)"]
    end
    s3[("aws_s3_bucket<br/>raw image")]

    admin -- "SSH (admin_cidrs)" --> jh
    jh -- "SSH" --> cp
    jh -- "SSH" --> ag
    users -- "80/443 (ingress_cidrs)<br/>6443 (api_cidrs)" --> nlbp --> cp
    ag -- "6443, 9345" --> nlbi --> cp
    cp --> nat
    ag --> nat
    nat --> inet
    jh -- "upload" --> s3e --> s3
```

### vultr

```mermaid
flowchart LR
    admin(["Admin"])
    users(["Users / kubectl"])
    inet(["Internet"])

    subgraph vpc ["vultr_vpc"]
        jh["jumphost<br/>vultr_instance (public IP)"]
        nat["vultr_nat_gateway"]
        cp["control_plane<br/>vultr_instance (vpc_only)"]
        ag["worker, gpu<br/>vultr_instance or vultr_bare_metal_server<br/>(bare metal: public IP)"]
    end
    lba["vultr_load_balancer api<br/>6443, 9345"]
    lbi["vultr_load_balancer ingress<br/>80/443"]
    snap[("vultr_snapshot_from_url")]

    admin -- "SSH (admin_cidrs)" --> jh
    jh -- "SSH" --> cp
    jh -- "SSH" --> ag
    users -- "6443 (api_cidrs)" --> lba --> cp
    users -- "80/443 (ingress_cidrs)" --> lbi --> cp
    cp -- "9345 via NAT" --> nat --> lba
    ag -- "6443, 9345<br/>(public IP or via NAT)" --> lba
    nat --> inet
    snap -- "fetch over HTTP :80 (pass 1)" --> jh
```

### evroc

```mermaid
flowchart LR
    admin(["Admin"])
    users(["Users / kubectl"])
    inet(["Internet"])

    subgraph vpc ["evroc_vpc (one evroc_subnet per zone)"]
        jh["jumphost (zones[0])<br/>evroc_virtual_machine + evroc_public_ip"]
        bld["builder per other zone<br/>(pass 1 only, private)"]
        cp["control_plane<br/>evroc_virtual_machine"]
        ag["worker, gpu<br/>evroc_virtual_machine"]
    end
    lb["evroc_loadbalancer on evroc_public_ip (API VIP)<br/>6443, 9345, 80/443"]
    pnat["Platform NAT<br/>(no public IP on the node)"]

    admin -- "SSH, build status (admin_cidrs)" --> jh
    jh -- "SSH" --> bld
    jh -- "SSH" --> cp
    jh -- "SSH" --> ag
    users -- "80/443 (ingress_cidrs)<br/>6443 (api_cidrs)" --> lb --> cp
    ag -- "6443, 9345" --> lb
    cp --> pnat
    ag --> pnat
    pnat --> inet
```

### exoscale

```mermaid
flowchart LR
    admin(["Admin"])
    users(["Users / kubectl"])
    inet(["Internet"])

    subgraph pn ["exoscale_private_network (security groups do not apply)"]
        jh["jumphost<br/>exoscale_compute_instance (static lease)"]
        cp["control_plane<br/>exoscale_instance_pool"]
        ag["worker, gpu<br/>exoscale_compute_instance"]
    end
    nlb["exoscale_nlb<br/>6443, 9345, 80/443"]
    hc(["public-nlb-healthcheck-sources"])
    tpl[("exoscale_template")]

    admin -- "SSH (admin_cidrs)" --> jh
    jh -- "SSH (private network)" --> cp
    jh -- "SSH (private network)" --> ag
    users -- "80/443 (ingress_cidrs)<br/>6443 (api_cidrs)" --> nlb --> cp
    cp -- "9345 joins (public IP)" --> nlb
    ag -- "6443, 9345 (public IP)" --> nlb
    hc -- "healthchecks" --> cp
    cp -- "public IP" --> inet
    ag -- "public IP" --> inet
    tpl -- "fetch over HTTP :80 (pass 1)" --> jh
```
