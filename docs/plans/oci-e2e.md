# Plan: first end-to-end test of the OCI provider

Status: done, 2026-11-16: phases A to F passed in compartment `suse-ai`. Fixes
found on the way: the `done` marker upload (stdin is sent chunked, Object
Storage answers 501), the reserved IP `private_ip_id` drift, node replacement
on a new image (the provider swaps the boot volume in place), the cleanup
objects on rebuild, and the leftovers search paging and image state. Timings:
build about 6 min, upload 8 s, full rebuild with import and 4 nodes 19.5 min,
node Ready 2 to 4 min, GPU allocatable about 5 min after Ready, destroy 4 min.
Existing VCN (`vpc_id`, cluster `oci-net`): the swapped-subnet plan failed on
the route checks, the deploy created no network object, the node joined from
the existing private subnet, `egress_ips` matched the existing NAT gateway, and
destroy left the VCN and subnets in place.

## Context

- Branch `feat/oci-image-pipeline`, commit `d55df61` ("feat(oci): Oracle
  Cloud provider"), not pushed. The user pushes and opens the PR after this
  test passes (PR title = the same Conventional Commit; an admin adds
  `validate (oci)` to the ruleset's required checks).
- Design: `docs/decisions/012-oci-module.md`, platform notes and the "to
  verify on first deploy" list: `docs/providers/oci.md`, runbook:
  `examples/oci/README.md`.
- Tenancy facts (checked 2026-11-13): home region `eu-frankfurt-1`, ADs
  `KiWy:EU-FRANKFURT-1-AD-{1,2,3}`, AD-1 offers `VM.GPU.A10.1/2` and
  `VM.Standard.E5.Flex`; A10 limit 31 (1 used by someone else), E5 cores 4629;
  NLB limit 20, reserved IPs 50.
- **Sandbox:** the Claude session cannot read `~/.oci` (nor
  `~/.terraform.d`), and Terraform needs the API key, so **every deploy,
  `oci` and `kubectl` command runs in the user's own terminal**. The user
  pastes output back. Never ask for or print tfvars, state, kubeconfigs or
  `.deploy/` logs (CLAUDE.md security rules); ask for the failing lines only.

## Prerequisites (user's terminal)

```bash
cd ~/git/suse-ai-factory-cloud-providers && git switch feat/oci-image-pipeline
terraform version          # >= 1.16.5
jq --version; kubectl version --client; oci --version
oci iam region-subscription list --tenancy-id <tenancy-ocid> --output table   # API key works
```

Compartment: if `aif-test` does not exist yet:

```bash
oci iam compartment create -c <tenancy-ocid> --name aif-test \
  --description "SUSE AI Factory tests" --query 'data.id' --raw-output
```

## Setup (once)

1. Cluster directory (links to `examples/oci`, copies the tfvars example):

   ```bash
   tools/multicluster/cluster.sh new oci oci-e2e
   ```

2. `clusters/common-oci.tfvars` (mode 600; shared by every OCI cluster):

   ```hcl
   region               = "eu-frankfurt-1"
   oci_tenancy_ocid     = "ocid1.tenancy.oc1..aaaaaaaacmob5e5zpxmq25qwvpnvfaguig6ojsruhfd5hsptg6t4647t6xcq"
   oci_user_ocid        = "ocid1.user.oc1..<from ~/.oci/config>"
   oci_fingerprint      = "<from ~/.oci/config>"
   oci_private_key_path = "/Users/<you>/.oci/<key>.pem"   # absolute path
   oci_compartment_ocid = "ocid1.compartment.oc1..<aif-test>"
   ```

3. `clusters/oci-e2e/terraform.tfvars`: the copied example contains
   `REPLACE` placeholders for values that `clusters/common-all.tfvars`
   already sets (admin_cidrs, password hashes, ssh keys, registry
   credentials). **Delete those lines**: terraform.tfvars is loaded last and
   would override the real values with placeholders. Also delete the `oci_*`
   and `region` lines (they are in common-oci.tfvars). Keep only:

   ```hcl
   cluster_name        = "oci-e2e"
   deploy_nodes        = false   # phase A; changed per phase below
   control_plane_count = 1
   gpu_pools           = {}
   ```

   Check nothing is left: `grep -n REPLACE clusters/oci-e2e/terraform.tfvars`
   must print nothing. `admin_cidrs` must contain the workstation's public IP.

Optional cost preview: `tools/multicluster/cluster.sh cost oci-e2e`.

## Phases

Staged, so a failure costs little and points at one layer. Each phase is
the same command:

```bash
tools/multicluster/cluster.sh deploy oci-e2e
```

It plans, shows replacements/destroys and asks to confirm. Check the plan
summary before answering: a phase that only adds nodes must not replace the
image or the jumphost (if it does, stop and paste the replaced addresses).

### A. Network, jumphost, image (`deploy_nodes = false`)

Expected: ~30–60 min (build ~20 min, upload, import). Validates the dnf
factory path on Oracle Linux 9, PAR upload, image import, UEFI capability,
quota checks.

```bash
cd clusters/oci-e2e
terraform output -json image | jq .
oci compute image get --image-id "$(terraform output -json image | jq -r '.ids[]')" \
  --query 'data."lifecycle-state"'                                # AVAILABLE
oci compute image-capability-schema list -c <compartment-ocid> \
  --image-id "$(terraform output -json image | jq -r '.ids[]')" --all   # Compute.Firmware UEFI_64
./ssh.sh jumphost 'rpm -qf $(command -v curl); rpm -q podman qemu-img; tail -5 /var/log/elemental-factory.log'
```

If the build hangs: `./build-logs.sh` (follows the factory log on the
jumphost).

### B. One control plane, no GPU (`deploy_nodes = true`)

Validates: UEFI boot of the imported image, Ignition `oraclecloud` reading
user_data (IMDS v2), RKE2 init, NLB backends and health checks, hairpin
through the NAT gateway, Rancher.

```bash
terraform output -json nodes | jq .
./kubeconfig.sh --wait -o ~/.kube/oci-e2e.yaml
export KUBECONFIG=~/.kube/oci-e2e.yaml
kubectl get nodes -o wide
kubectl get pods -A | grep -v -E 'Running|Completed'
oci nlb backend-health get --network-load-balancer-id \
  "$(terraform output -json provider_details | jq -r .nlb_id)" \
  --backend-set-name kube-api --backend-name <from: oci nlb backend list ...>
curl -sk -o /dev/null -w '%{http_code}\n' "$(terraform output -raw rancher_url)"   # 200/302
./ssh.sh <node> 'ip -br addr; cat /sys/class/net/*/mtu'          # MTU 9000 expected
```

Node does not come up → serial console (no SSH needed):

```bash
ID=$(terraform output -json nodes | jq -r 'to_entries[0].value.id')
H=$(oci compute console-history capture --instance-id "$ID" --query data.id --raw-output)
sleep 30; oci compute console-history get-content --instance-console-history-id "$H" \
  --length 10000000 --file - | grep -iE 'ignition|uefi|rke2|error' | tail -50
```

### C. GPU pool

Set `gpu_pools = { gpu = { instance_type = "VM.GPU.A10.1", count = 1 } }`,
deploy. Validates: A10 shape compatibility with the imported image
(`oci_core_shape_management`), GPU quota check, precompiled driver,
GPU operator.

```bash
kubectl get nodes -L nvidia.com/gpu.product
kubectl run smi --rm -it --restart=Never --image=nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04 \
  --overrides='{"spec":{"containers":[{"name":"smi","image":"nvcr.io/nvidia/cuda:12.4.1-base-ubuntu22.04","command":["nvidia-smi"],"resources":{"limits":{"nvidia.com/gpu":1}}}]}}'
```

"Out of host capacity" is a platform capacity error, not a bug: retry later
or set `zones = ["ad-2"]` on the pool.

### D. HA control plane

Set `control_plane_count = 3`, deploy. Validates: joins through the NLB
(9345) from the private subnet, fault-domain spread, etcd between control
planes.

```bash
kubectl get nodes -o wide
terraform output -json provider_details | jq .fault_domains
```

### E. Rebuild (optional)

`tools/multicluster/cluster.sh deploy oci-e2e --rebuild`: new image, jumphost
and nodes replaced; cluster comes back.

### F. Destroy and leftovers

```bash
tools/multicluster/cluster.sh destroy oci-e2e
```

Run the leftovers command `deploy.sh --destroy` prints (verifies the Search
query syntax), plus:

```bash
oci os preauth-request list --bucket-name oci-e2e-build 2>&1 | tail -3   # bucket gone
oci compute image list -c <compartment-ocid> --display-name oci-e2e --all --query 'length(data)'
```

## Also record during the test

From `docs/providers/oci.md` "to verify on first deploy":

- Expired PARs after 24 h (only if the cluster stays up that long):
  `oci os preauth-request list --bucket-name oci-e2e-build` — still listed or
  gone; does the next plan want to recreate them?
- NLB health-check source address inside the public subnet (backend-health
  OK = yes).
- sslip.io hostnames resolve for Rancher and `rke2-<ip>.sslip.io`.
- Metadata size with all components (plan precondition did not fire).
- Phase durations (build, import, first node Ready).

## After the test

- Fix failures on the same branch (new commits; squash-merge later).
- Update `docs/providers/oci.md` (verified items, timings), ADR 012 status
  → Accepted, `docs/e2e-checklist.md` OCI rows, `docs/plans/oci.md`, the
  OCI memory note.
- User pushes `feat/oci-image-pipeline`, opens the PR, admin adds
  `validate (oci)` to the ruleset.

## Prompt for the fresh session

> Read docs/plans/oci-e2e.md and help me run the OCI end-to-end test, phase by
> phase. I run every command in my own terminal and paste the output.
