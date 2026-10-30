# 05: Platform on evroc

Shape overview: [../README.md](../README.md). Status: not run end to end on evroc yet. The plan of each file is checked by `make test-catalog`.

Four clusters from `examples/evroc`, run with `tools/multicluster/cluster.sh`. Replace
`aif.example.com` with a domain you control in all files and commands.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` with `admin_cidrs`, the SSH keys
  and the password hashes. Application Collection credentials are required:
  every cluster uses `local-path-provisioner`, and the Observability charts
  come from Application Collection too.
- `evroc login`. It writes `~/.evroc/config.yaml`. The provider reads the
  credentials, the region and the project from that file, so there is no API key
  in the tfvars files. `deploy.sh` stops if the file is missing.
  `clusters/common-evroc.tfvars` is optional. It may hold `region` (for example
  `"se-sto"`) and `project`.
- A DNS zone you control, where you can add four wildcard A records. This guide
  uses the zone `aif.example.com` and the names `*.mgmt`, `*.o11y`, `*.sec` and
  `*.gpu` in it. Use a low TTL (60 seconds): a record changes if you destroy and
  create a cluster again.
  For tests without a zone, use four free DuckDNS names instead (see
  [Using DuckDNS](#using-duckdns)).
- A SUSE Observability license key. It goes only in `clusters/obs/terraform.tfvars`.
- Two shared tokens, the same on all clusters. Append them to
  `clusters/common-all.tfvars` without printing them:

  ```bash
  grep -q '^security_join_token' clusters/common-all.tfvars || \
    printf '\nsecurity_join_token = "%s"\nobservability_bootstrap_token = "%s"\n' \
      "$(uuidgen | tr 'A-Z' 'a-z')" "$(openssl rand -hex 24)" >> clusters/common-all.tfvars
  chmod 600 clusters/common-all.tfvars
  ```

  The guard keeps a second run from adding the keys twice. If only one of the two
  keys exists in the file, add the other by hand.

  Every provider declares both variables, so `common-all.tfvars` may hold them.
  If you leave them out, each cluster generates its own tokens and the clusters
  do not agree.
- Quota, raised before step 1. evroc quotas are organization-wide. A default
  project has 20 vCPU, 160 GB of memory, 3 public IPs and one L40S of GPU quota.
  This shape needs more:

  | Cluster | vCPU | Memory (GB) | Public IPs | GPU |
  |---|---|---|---|---|
  | `mgmt` | 16 | 48 | 2 | - |
  | `sec` | 16 | 48 | 2 | - |
  | `gpu` | 16 | 48 | 2 | 1 L40S |
  | `obs` | 36 | 80 | 2 | - |
  | Total | 84 | 224 | 8 | 1 L40S |

  The footprint of a cluster is the larger of two passes. Pass 1 is the build
  hosts (one jumphost-size VM per zone). Pass 2 is the jumphost plus the control
  planes plus any worker nodes. For `mgmt`: a jumphost `a1a.m` (4 vCPU, 16 GB) and
  three `c1a.m` (4 vCPU, 8 GB each), so pass 2 is 16 vCPU and 40 GB and pass 1
  (three `a1a.m`, 48 GB) sets the memory peak. For `obs`: the jumphost plus one `c1a.2xl`
  (32 vCPU, 64 GB). GPU VMs draw no vCPU or memory quota. Each cluster uses two
  public IPs.

  `obs` alone needs 36 vCPU, so its plan fails on a default project. The plan
  checks the footprint of the cluster you plan against the organization limit.
  It does not count the other clusters: a later cluster can pass plan and be
  denied at apply. Ask evroc to raise the quota to the total above (plus what
  you already use). After a destroy, the quota is released with a delay.
- GPU quota and zone. The pool uses the `gn-l40s.s` profile (1x L40S 48 GB,
  15 vCPU, 190 GB). Only zone `a` admits GPU VMs, and the plan checks it. The
  plan cannot see the GPU quota. `provider_details.gpu_quota_request` shows the
  demand. See [GPUs](../../../docs/providers/evroc.md#gpus) and
  [Quota](../../../docs/providers/evroc.md#quota).
- Go, for the cost estimate.
- `evroc` CLI logged in, for the DNS address (next section) and the leftovers
  check.

## How the DNS records work on evroc

The wildcard record needs the ingress address of that cluster. On evroc this is
the API VIP: a public IP named `<cluster_name>-api-vip` (for example
`aif-obs-api-vip`). `deploy.sh` creates it at the very start of pass 1, before
the load balancer, the build hosts and the image. It stays the same across
rebuilds (`deploy.sh --rebuild`) and load balancer replacement. It changes only
when you destroy the cluster. See [API VIP](../../../docs/providers/evroc.md#api-vip)
and [Load balancer](../../../docs/providers/evroc.md#load-balancer).

So you can create the record a few minutes after the deploy starts, long before
the nodes exist. Read the address from the evroc CLI (use the address in the
output):

```bash
evroc networking publicip get aif-obs-api-vip   # YAML output
```

After pass 1 has finished, the Terraform output has it too. Outputs are written
only when an apply ends:

```bash
terraform -chdir=clusters/<name> output -raw api_vip   # the address; ingress_endpoint is https://<it>
```

Create the records:

| Cluster | Record in the zone `aif.example.com` |
|---|---|
| `obs` | `*.o11y  A  <obs API VIP>` |
| `sec` | `*.sec  A  <sec API VIP>` |
| `mgmt` | `*.mgmt  A  <mgmt API VIP>` |
| `gpu` | `*.gpu  A  <gpu API VIP>` |

Public IPs are recycled across clusters. A cluster that you create again gets a
new address: update the record.

### Using DuckDNS

[DuckDNS](https://www.duckdns.org) is a free dynamic DNS service. Every name
below `<name>.duckdns.org` resolves to the address of `<name>`, so one DuckDNS
name per cluster replaces the wildcard record. A free account has up to five
names; this shape needs four. The nodes use public DNS for the cross-cluster
names, so a local `/etc/hosts` entry does not work.

1. Log in at <https://www.duckdns.org>, note the account token (a secret) and
   create four names, for example `aifb-mgmt`, `aifb-o11y`, `aifb-sec` and
   `aifb-gpu`.
2. Put them in the four files instead of the `aif.example.com` names (run it
   after step 3 below, when all four files exist):

   ```bash
   M=aifb-mgmt.duckdns.org O=aifb-o11y.duckdns.org S=aifb-sec.duckdns.org G=aifb-gpu.duckdns.org
   for c in obs sec mgmt gpu; do
     sed -i.bak -e "s/mgmt\.aif\.example\.com/$M/g" -e "s/o11y\.aif\.example\.com/$O/g" \
       -e "s/sec\.aif\.example\.com/$S/g" -e "s/gpu\.aif\.example\.com/$G/g" "clusters/$c/terraform.tfvars"
     rm -f "clusters/$c/terraform.tfvars.bak"
   done
   ```

   The Observability server is then `https://obs.aifb-o11y.duckdns.org`, the
   federation endpoint `fed-neuvector.aifb-sec.duckdns.org` and Rancher
   `https://rancher.aifb-mgmt.duckdns.org`.
3. As soon as the API VIP of a cluster exists, point its name at it. Read the
   token without echoing it, so it does not end up in the shell history. Put the
   address from `evroc networking publicip get` in `ip`:

   ```bash
   read -rs DUCKDNS_TOKEN; export DUCKDNS_TOKEN
   ip=<obs API VIP>
   curl -s "https://www.duckdns.org/update?domains=aifb-o11y&token=$DUCKDNS_TOKEN&ip=$ip"; echo   # OK
   dig +short obs.aifb-o11y.duckdns.org                                                          # the IP
   ```

   Repeat with `sec`/`aifb-sec`, `mgmt`/`aifb-mgmt` and `gpu`/`aifb-gpu`.

The deploy does not wait for DNS. `deploy.sh`, the wait scripts and the plan
never resolve these names. The load balancer has no backends until pass 2
creates the nodes, and its health check (`/ping` on port 8080 with Traefik)
fails until Traefik answers. So a late record only delays the work that needs
the name:

- The agent setup Jobs on `mgmt`, `sec` and `gpu` wait in a loop until the API of
  `obs` answers, so they finish by themselves once the record, the ingress and
  the server exist.
- The `security-fed-join` CronJob of a member that starts before the primary
  usually joins within about 15 minutes after the primary is reachable (not yet
  verified). The retries are capped at 6 controller restarts; see
  [Troubleshooting](../../../docs/observability-and-security.md#troubleshooting)
  for the window and the reset.
- `register` and all browser access need the record of the cluster they use.

Create each record as soon as you can read its address.

## Steps

Run from the repo root. The order is `obs`, `sec`, `mgmt`, `gpu`: the Observability
CA exists only after `obs` is deployed, and all three others need it.

1. Create and edit the observability cluster. In the file, set the license key
   (`observability_license_key`) and replace the domain in `ingress_domain`,
   `observability_allowed_origins` and `security_primary_endpoint` if you do not
   use `aif.example.com`.

   ```bash
   tools/multicluster/cluster.sh new --empty evroc obs
   cp catalog/05-platform/evroc/obs.tfvars.example clusters/obs/terraform.tfvars
   $EDITOR clusters/obs/terraform.tfvars
   tools/multicluster/cluster.sh cost obs
   tools/multicluster/cluster.sh deploy obs
   ```

   `cp` onto the existing file keeps its mode 600. Each deploy runs two passes
   (and a third that reclaims the build disks) and takes tens of minutes. Follow
   the image build with `clusters/obs/build-logs.sh`: evroc has no serial
   console, so the jumphost relays the build progress over HTTP
   ([There is no console](../../../docs/providers/evroc.md#there-is-no-console)).
   `obs` has no `observability_server_url`: it is the server.

2. Create the DNS record for `obs` as soon as the API VIP exists (see above):
   `*.o11y  A  <obs API VIP>`. Check that the server answers (it can take
   several minutes after the nodes are up):

   ```bash
   terraform -chdir=clusters/obs output -json observability | jq -r .ca_pem > /tmp/aif-obs-ca.crt
   curl --cacert /tmp/aif-obs-ca.crt -s -o /dev/null -w '%{http_code}\n' https://obs.o11y.aif.example.com/api/server/info
   ```

   The `ca_pem` is a certificate, not a secret. The API needs a token, so a
   `401` or `403` also shows that the server and the certificate work.

3. Create the other three clusters, copy the files and edit them. Do not deploy yet.

   ```bash
   for c in sec mgmt gpu; do
     tools/multicluster/cluster.sh new --empty evroc "$c"
     cp "catalog/05-platform/evroc/$c.tfvars.example" "clusters/$c/terraform.tfvars"
   done
   $EDITOR clusters/sec/terraform.tfvars clusters/mgmt/terraform.tfvars clusters/gpu/terraform.tfvars
   ```

   Change the domains if you do not use `aif.example.com`. They are in
   `ingress_domain`, `observability_server_url`, `security_primary_endpoint` and
   (on `sec` only) `security_rancher_url`.

4. Write the Observability CA for the three clusters. The file is loaded by
   Terraform on its own; the CA is an image input.

   ```bash
   for c in sec mgmt gpu; do
     ( umask 077
       terraform -chdir=clusters/obs output -json observability \
         | jq '{observability_ca_pem: .ca_pem}' > "clusters/$c/addons.auto.tfvars.json" )
     chmod 600 "clusters/$c/addons.auto.tfvars.json"
   done
   ```

   Keep `observability_ca_pem` out of the `terraform.tfvars` files: values there
   win over the auto file. Regenerate the files when `obs` is destroyed and
   deployed again (a new CA). A rebuild of `obs` keeps the CA but needs the
   [token reconnect](../../../docs/observability-and-security.md#reconnect-remote-clusters-after-a-server-rebuild).

5. Deploy `sec`, `mgmt` and `gpu`. They do not depend on each other, so you can
   run them one after the other or in parallel terminals. Check the cost first.
   Running them in parallel adds their footprints: see the quota table.

   ```bash
   for c in sec mgmt gpu; do tools/multicluster/cluster.sh cost "$c"; done
   tools/multicluster/cluster.sh deploy sec
   tools/multicluster/cluster.sh deploy mgmt
   tools/multicluster/cluster.sh deploy gpu
   ```

   As soon as each deploy starts, read the API VIP and create the record:
   `*.sec`, `*.mgmt`, `*.gpu`. `sec` needs its record for the NeuVector Manager
   and for the federation join of the other three. Each of `obs`, `mgmt` and `gpu`
   needs its record so that `sec` can reach the managed endpoint.

6. Import the clusters into the management Rancher. `gpu` is required; `sec` and
   `obs` are optional (see [Register decision](../README.md#register-decision)).

   ```bash
   tools/multicluster/cluster.sh register --bootstrap mgmt gpu sec obs
   ```

   `rancher.mgmt.aif.example.com` must resolve and Rancher must be up. `--bootstrap`
   is needed once, because a new Rancher has no API token. It logs in with the
   bootstrap password, creates an admin token and replaces the admin password with
   a random one. The token is kept in `clusters/.register/mgmt/`. That directory is
   a secret. Read the new admin password from the repo root:

   ```bash
   TF_DATA_DIR="$PWD/clusters/.register/mgmt/.terraform" \
     terraform -chdir=tools/multicluster/register output -raw admin_password
   ```

   On evroc the egress addresses of a cluster are not exposed (`egress_ips` is
   empty), so `register` warns "reports no egress_ips" and continues. Clusters are
   imported under their `cluster_name`: `aif-gpu`, `aif-sec`, `aif-obs`.

## Verify

```bash
tools/multicluster/cluster.sh list
```

- Trust the CAs in your browser first: the `obs` CA and the `sec` CA
  (`terraform -chdir=clusters/sec output -json security | jq -r .ca_pem`). See
  [docs/security.md](../../../docs/security.md#trusting-the-cluster-ca-in-the-browser).
  Rancher uses its own certificate; accept it once.
- `sec`, NeuVector: open `https://neuvector.sec.aif.example.com`, log in as `admin`
  and open Multiple Clusters. The members are `aif-mgmt`, `aif-obs` and `aif-gpu`,
  each joined. A member can take about 15 minutes to join; if it does not, see
  [Troubleshooting](../../../docs/observability-and-security.md#troubleshooting).
- `obs`, SUSE Observability: open `https://obs.o11y.aif.example.com`, log in as
  `admin`. The Kubernetes clusters list shows four clusters: `aif-obs`, `aif-mgmt`,
  `aif-sec`, `aif-gpu`. The `kubernetes-v2` instance of each remote cluster is
  created by its own setup Job. Open `aif-gpu` to see its nodes, and the SUSE AI
  GPU Nodes view to see the GPU, its driver and CUDA versions (one NVIDIA L40S).
- `mgmt`, Rancher: open `https://rancher.mgmt.aif.example.com`. The cluster
  `aif-gpu` is listed and `Active` (and `aif-sec` and `aif-obs` if you imported
  them). The Observability extension is installed and points at the server. With
  it, each imported cluster's dashboard shows its SUSE Observability health.
- `mgmt`, AI Factory: in Rancher open SUSE AI Factory, Apps, pick an app and
  Install. In Target Cluster, choose Fleet Bundle: the imported clusters are
  listed, and `aif-gpu` shows its GPU.
- `gpu`, GPU: fetch the kubeconfig to a file with mode 600.

  ```bash
  mkdir -p ~/.kube
  clusters/gpu/kubeconfig.sh --wait -o ~/.kube/aif-gpu.yaml
  KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get pods -n gpu-operator
  KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get nodes \
    -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
  ```

  The GPU node reports `1` once the operator is ready. The driver is an
  experimental precompiled build ([docs/workarounds.md](../../../docs/workarounds.md)).

Cluster-level checks: [examples/evroc/README.md#post-deploy-checks](../../../examples/evroc/README.md#post-deploy-checks).

## Outputs to read

Run these in your terminal. The two credential outputs are sensitive.

```bash
terraform -chdir=clusters/sec output -json security            # role, url, federation_endpoint, ca_pem
terraform -chdir=clusters/obs output -json observability       # url, ca_pem, otlp endpoints
terraform -chdir=clusters/sec output -json security_credentials          # NeuVector admin password, join token
terraform -chdir=clusters/obs output -json observability_credentials     # admin password, bootstrap token
terraform -chdir=clusters/mgmt output -raw rancher_bootstrap_password    # until register --bootstrap replaces it
terraform -chdir=clusters/gpu output -json provider_details              # includes gpu_quota_request
```

`security_credentials` exists on every cluster with a `security-*` component; each
cluster has its own NeuVector admin password. `join_token` is the shared one.

## Cost

Run `tools/multicluster/cluster.sh cost <name>` for each cluster before you
deploy. The estimate is not a quote. It prices the VMs, the disks and the public
IPs from a rate card (EUR, without VAT). The load balancer, the snapshots and
the traffic are not included. See
[Cost estimate](../../../docs/providers/evroc.md#cost-estimate). Each of the four
clusters has:

- a jumphost, three control-plane nodes (`obs`: one node, `c1a.2xl` with a
  1000 GB disk) and, on `gpu`, the GPU node
- two public IPs
- one load balancer (API and ingress listeners on the API VIP)
- one image snapshot per zone (`obs`: one zone)

Four clusters mean four sets of these. The L40S node and the `obs` node are the
main costs.

## Destroy

Destroy in reverse order: `gpu`, `mgmt`, `sec`, `obs`.

```bash
tools/multicluster/cluster.sh destroy gpu
tools/multicluster/cluster.sh destroy mgmt
tools/multicluster/cluster.sh destroy sec
tools/multicluster/cluster.sh destroy obs
```

- Deleting a cluster does not remove its entry in Rancher. In the Rancher UI,
  delete the imported clusters, then remove them from
  `clusters/.register/mgmt/downstream.list`.
- When `mgmt` is destroyed, `clusters/.register/mgmt/` is stale. Delete the
  directory before you deploy a new `mgmt`, and use `--bootstrap` again.
- Delete the four DNS records (or the four DuckDNS names). The API VIPs are
  released with the clusters.
- After a successful destroy, `deploy.sh` prints the leftovers check. It does not
  run it. Run it yourself, logged in with the `evroc` CLI:

  ```bash
  for n in aif-gpu aif-mgmt aif-sec aif-obs; do tools/leftovers/evroc.sh "$n"; done
  ```

  It is read-only. Exit code 0 means nothing is left, 1 means resources are left
  and 3 means the check is inconclusive. See
  [Leftover check](../../../docs/providers/evroc.md#leftover-check).
- The quota is released with a delay after a destroy. Wait before you deploy
  again if the plan or apply reports a quota error.
- To reuse the names, remove the old directories first: `cluster.sh new` refuses
  an existing one (`rm -rf clusters/gpu clusters/mgmt clusters/sec clusters/obs`).

## Variants on evroc

- `obs` on `m1a.xl` (16 vCPU, 128 GB): enough for `20-nonha` (9.5 vCPU,
  27.2 GiB) or `trial`, not for `50-nonha`, which needs about 16.5 vCPU with
  RKE2 and the agent. `c1a.xl` (16 vCPU, 32 GB) has the CPU but little memory:
  RKE2, NeuVector and the agent add about 9 GB to the profile's request (42 GB
  measured for `50-nonha`), so 32 GB is tight even for `trial`. Lower
  `control_plane_disk_size_gb` to match the profile's storage.
- An HA Observability profile (`observability_sizing_profile = "150-ha"`) needs
  at least three `obs` nodes and 49.8 vCPU in total, with `suse-storage`. Not
  tested here. Check the quota first: it is far above this shape's table.

## Troubleshooting

- `kubectl` returns `Error from server (Timeout)` and `rke2-server` restarts
  in a loop with `failed to reconcile with local datastore` on a single-node
  cluster (`obs`): an etcd stall made rke2 exit and etcd now blocks. Recovery:
  [rke2-server restart loop](../../01-inference-in-a-box/evroc/README.md#rke2-server-restart-loop-after-the-first-boot).
- Plan fails on quota: the footprint of this cluster is above the organization
  limit. For `obs` this is the case on a default project. Raise the quota (see
  Prerequisites). Plan does not count the other clusters, so apply can still be
  denied when the clusters together exceed the limit. After a destroy, the
  quota is released with a delay.
- Plan fails on the GPU zone or profile: only zone `a` admits GPU VMs, so keep
  `zones` at the default on `gpu`. The GPU quota is not visible to plan; see
  `provider_details.gpu_quota_request` and
  [GPUs](../../../docs/providers/evroc.md#gpus).
- The plan of `sec`, `mgmt` or `gpu` fails on `observability_ca_pem` or
  `observability_server_url`: step 4 was skipped, or the values are also set in
  `terraform.tfvars`.
- Agent Jobs wait for the API: the record of `obs` is missing or wrong (the
  address must be the API VIP of `obs`), or the cluster is not up yet.
  Nodes have no public IP and go out through a platform NAT whose addresses are
  not exposed. Keep `ingress_cidrs` of `obs`, `sec` and `mgmt` at the default
  `0.0.0.0/0`: the flows from the nodes (agents to `obs`, federation in both
  directions, the cattle agent to Rancher) cannot be limited to known
  addresses.
- A member does not appear in Multiple Clusters: the record of that cluster
  (`*.<sub>`) is missing, or the primary on `sec` is not reachable. The member's
  `security-fed-join` CronJob retries.
- `obs` was replaced: its CA changed. Regenerate step 4 and deploy `sec`, `mgmt`
  and `gpu` again. This rebuilds their images and replaces their nodes.
- A deploy is slow and shows no node: there is no console. Follow the build with
  `clusters/<name>/build-logs.sh`.
- `register` warns "reports no egress_ips": expected on evroc, it continues.
- More: [tools/multicluster/README.md](../../../tools/multicluster/README.md),
  [examples/evroc/README.md#troubleshooting](../../../examples/evroc/README.md#troubleshooting),
  [docs/providers/evroc.md](../../../docs/providers/evroc.md),
  [docs/decisions/010-security-observability.md](../../../docs/decisions/010-security-observability.md).
