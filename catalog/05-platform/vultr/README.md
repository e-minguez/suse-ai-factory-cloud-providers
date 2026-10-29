# 05: Platform on Vultr

Shape overview: [../README.md](../README.md). Status: not yet verified end to end.
Four clusters from `examples/vultr`, run with `tools/multicluster/cluster.sh`. Replace
`aif.example.com` with a domain you control in all files and commands.

## Prerequisites

- The shared prerequisites: [../../README.md#shared-prerequisites](../../README.md#shared-prerequisites).
  This includes `clusters/common-all.tfvars` and `clusters/common-vultr.tfvars`
  with the credentials, the region and `admin_cidrs`. Application Collection
  credentials are required: every cluster uses `local-path-provisioner`, and
  the Observability charts come from Application Collection too.
- A DNS zone you control, where you can add four wildcard A records. This guide
  uses the zone `aif.example.com` and the names `*.mgmt`, `*.o11y`, `*.sec` and
  `*.gpu` in it. Use a low TTL (60 seconds): a record can change if a load
  balancer is replaced.
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
- Stock of the GPU plan in your region. The plan `vcg-a40-24c-120g-48vram` is a
  passthrough plan with a verified driver. Plan fails when it is not in stock.

  ```bash
  curl -s -H "Authorization: Bearer $VULTR_API_KEY" \
    "https://api.vultr.com/v2/regions/$REGION/availability" \
    | jq -r '.available_plans[]' | grep -E '^vcg-'
  ```

  All regions: `VULTR_API_KEY=... tools/vultr/passthrough-stock.sh`. The plan
  `vx1-g-8c-32g-480s` (the `obs` nodes) must be in stock too; plan checks it.
- Go, for the cost estimate.
- Network: all four clusters use the default `vpc_cidr` of `examples/vultr`. See
  [one VPC range for all clusters](../../README.md#vultr-one-vpc-range-for-all-clusters).

## How the DNS records work on Vultr

The wildcard record needs the IP of the ingress load balancer of that cluster.
Vultr creates the load balancer at the start of pass 1 of `deploy.sh`
(`modules/vultr/loadbalancer.tf`; the module waits until the address exists).
The `ingress_endpoint` output (`https://<ip>`) is available when pass 1 has
finished: the load balancers, jumphost, image build, snapshot import and nodes.
The address is also visible in the Vultr portal as soon as the load balancer
exists, while the image builds.

```bash
terraform -chdir=clusters/<name> output -raw ingress_endpoint   # https://<ip>
```

`deploy.sh` runs pass 2 right after pass 1, so read the output from a second
terminal while pass 2 runs, or after `deploy` ends. Create the record then:

| Cluster | Record in the zone `aif.example.com` |
|---|---|
| `obs` | `*.o11y  A  <obs ingress IP>` |
| `sec` | `*.sec  A  <sec ingress IP>` |
| `mgmt` | `*.mgmt  A  <mgmt ingress IP>` |
| `gpu` | `*.gpu  A  <gpu ingress IP>` |

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
3. After pass 1 of each cluster, point its name at the ingress IP. Read the
   token without echoing it, so it does not end up in the shell history:

   ```bash
   read -rs DUCKDNS_TOKEN; export DUCKDNS_TOKEN
   ip=$(terraform -chdir=clusters/obs output -raw ingress_endpoint); ip=${ip#https://}
   curl -s "https://www.duckdns.org/update?domains=aifb-o11y&token=$DUCKDNS_TOKEN&ip=$ip"; echo   # OK
   dig +short obs.aifb-o11y.duckdns.org                                                          # the IP
   ```

   Repeat with `sec`/`aifb-sec`, `mgmt`/`aifb-mgmt` and `gpu`/`aifb-gpu`.

The deploy does not wait for DNS. `deploy.sh`, the wait scripts and the plan
never resolve these names; they use the Vultr API and the jumphost address. The
ingress load balancer has no backends until pass 2 ends and stays unhealthy
until Traefik answers `/ping`. So a late record only delays the work that needs
the name:

- The agent setup Jobs on `mgmt`, `sec` and `gpu` wait in a loop until the API of
  `obs` answers, so they finish by themselves once the record, the ingress and
  the server exist.
- The `security-fed-join` CronJob of a member that starts before the primary
  joins within about 15 minutes after the primary is reachable.
- `register` and all browser access need the record of the cluster they use.

Create each record as soon as you can read its IP. A rebuilt or replaced ingress
load balancer gets a new IP: update the record.

## Steps

Run from the repo root. The order is `obs`, `sec`, `mgmt`, `gpu`: the Observability
CA exists only after `obs` is deployed, and all three others need it.

1. Create and edit the observability cluster. In the file, set the license key
   (`observability_license_key`) and replace the domain in `ingress_domain`,
   `observability_allowed_origins` and `security_primary_endpoint` if you do not
   use `aif.example.com`.

   ```bash
   tools/multicluster/cluster.sh new --empty vultr obs
   cp catalog/05-platform/vultr/obs.tfvars.example clusters/obs/terraform.tfvars
   $EDITOR clusters/obs/terraform.tfvars
   tools/multicluster/cluster.sh cost obs
   tools/multicluster/cluster.sh deploy obs
   ```

   `cp` onto the existing file keeps its mode 600. Each deploy runs two passes and
   takes tens of minutes. Follow the image build with `clusters/obs/build-logs.sh`.
   `obs` has no `observability_server_url`: it is the server.

2. Create the DNS record for `obs` as soon as the address is known (see above):
   `*.o11y  A  <obs ingress IP>`. Check that the server answers (it can take
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
     tools/multicluster/cluster.sh new --empty vultr "$c"
     cp "catalog/05-platform/vultr/$c.tfvars.example" "clusters/$c/terraform.tfvars"
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
   win over the auto file. Regenerate the files when `obs` is replaced.

5. Deploy `sec`, `mgmt` and `gpu`. They do not depend on each other, so you can
   run them one after the other or in parallel terminals. Check the cost first.

   ```bash
   for c in sec mgmt gpu; do tools/multicluster/cluster.sh cost "$c"; done
   tools/multicluster/cluster.sh deploy sec
   tools/multicluster/cluster.sh deploy mgmt
   tools/multicluster/cluster.sh deploy gpu
   ```

   After each pass 1 read the ingress IP and create the record:
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

   `register` checks that the `mgmt` `ingress_cidrs` include the egress addresses
   (NAT gateways) of the clusters. The default `0.0.0.0/0` passes. Clusters are
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
  each joined. A member can take about 15 minutes to join.
- `obs`, SUSE Observability: open `https://obs.o11y.aif.example.com`, log in as
  `admin`. The Kubernetes clusters list shows four clusters: `aif-obs`, `aif-mgmt`,
  `aif-sec`, `aif-gpu`. The `kubernetes-v2` instance of each remote cluster is
  created by its own setup Job.
- `mgmt`, Rancher: open `https://rancher.mgmt.aif.example.com`. The cluster
  `aif-gpu` is listed and `Active` (and `aif-sec` and `aif-obs` if you imported
  them). The Observability extension is installed and points at the server.
- `gpu`, GPU: fetch the kubeconfig to a file with mode 600.

  ```bash
  mkdir -p ~/.kube
  clusters/gpu/kubeconfig.sh --wait -o ~/.kube/aif-gpu.yaml
  KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get pods -n gpu-operator
  KUBECONFIG=~/.kube/aif-gpu.yaml kubectl get nodes \
    -o custom-columns='NODE:.metadata.name,GPU:.status.allocatable.nvidia\.com/gpu'
  ```

  The GPU node reports `1` once the operator is ready.

## Outputs to read

Run these in your terminal. The two credential outputs are sensitive.

```bash
terraform -chdir=clusters/sec output -json security            # role, url, federation_endpoint, ca_pem
terraform -chdir=clusters/obs output -json observability       # url, ca_pem, otlp endpoints
terraform -chdir=clusters/sec output -json security_credentials          # NeuVector admin password, join token
terraform -chdir=clusters/obs output -json observability_credentials     # admin password, bootstrap token
terraform -chdir=clusters/mgmt output -raw rancher_bootstrap_password    # until register --bootstrap replaces it
```

`security_credentials` exists on every cluster with a `security-*` component; each
cluster has its own NeuVector admin password. `join_token` is the shared one.

## Cost

Run `tools/multicluster/cluster.sh cost <name>` for each cluster before you
deploy. The estimate is not a quote. Each of the four clusters has:

- a jumphost, three control-plane nodes (`obs`: the larger plan
  `vx1-g-8c-32g-480s`) and, on `gpu`, the GPU node
- an API load balancer and an ingress load balancer
- a NAT gateway
- the image snapshot

Four clusters mean four sets of these. The GPU plan and the `obs` nodes are the
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
- Delete the four DNS records (or the four DuckDNS names).
- After a successful destroy, `deploy.sh` prints the leftovers check. It does not
  run it. Run it yourself after you export the API key:

  ```bash
  export VULTR_API_KEY=...
  for n in aif-gpu aif-mgmt aif-sec aif-obs; do tools/leftovers/vultr.sh "$n"; done
  ```

  It deletes nothing. Expect `0 live, 0 unknown`.
- To reuse the names, remove the old directories first: `cluster.sh new` refuses
  an existing one (`rm -rf clusters/gpu clusters/mgmt clusters/sec clusters/obs`).

## Variants on Vultr

- An HA Observability profile (`observability_sizing_profile = "150-ha"`) needs a
  bigger plan on `obs`, for example `vx1-g-16c-64g-960s`. Not tested here.

## Troubleshooting

- Plan fails with "Plans not available in region": no stock for a plan, or an
  invalid `vultr_api_key`. Check stock as above. This also applies to
  `vx1-g-8c-32g-480s`.
- The plan of `sec`, `mgmt` or `gpu` fails on `observability_ca_pem` or
  `observability_server_url`: step 4 was skipped, or the values are also set in
  `terraform.tfvars`.
- Agent Jobs wait for the API: the record of `obs` is missing or wrong, or
  `obs` restricts `ingress_cidrs` and does not admit the egress addresses of the
  other clusters (`terraform -chdir=clusters/<name> output egress_ips`). A change
  of `ingress_cidrs` updates the ingress load balancer firewall rules in place.
  Keep your admin and user CIDRs in the list, or the browser loses access.
- A member does not appear in Multiple Clusters: the record of that cluster
  (`*.<sub>`) is missing, the primary on `sec` is not reachable, or
  `ingress_cidrs` blocks the other side (federation needs both directions).
  The member's `security-fed-join` CronJob retries.
- `obs` was replaced: its CA changed. Regenerate step 4 and deploy `sec`, `mgmt`
  and `gpu` again. This rebuilds their images and replaces their nodes.
- `register` stops at the CIDR check: add the printed egress addresses to
  `ingress_cidrs` of `mgmt`, or pass `--skip-cidr-check` when you know the path is
  open.
- More: [tools/multicluster/README.md](../../../tools/multicluster/README.md),
  [examples/vultr/README.md#troubleshooting](../../../examples/vultr/README.md#troubleshooting),
  [docs/providers/vultr.md](../../../docs/providers/vultr.md),
  [docs/decisions/010-security-observability.md](../../../docs/decisions/010-security-observability.md).
