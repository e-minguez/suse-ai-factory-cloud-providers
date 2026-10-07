# cost

**This is an estimate only.** `cost` is a helper that gives rough guidance
before a deploy. It is not a quote and not an invoice. For real numbers,
contact the provider directly or do your own math. Every text report starts
and ends with this statement, and the JSON report carries it in a top-level
`disclaimer` field.

`cost` reads the same tfvars files as `deploy.sh`, applies the module
defaults, prices the resources the module would create (aws, evroc, exoscale
or vultr), and prints a per-resource table for 1h, 8h, 24h, 7d and 30d. It
reads no plan, no state and no live resources, so it works before anything
exists. Credentials in the tfvars files are never read.

This is a separate Go module (`tools/cost/go.mod`); the repo root stays free
of Go files.

## Usage

```
make cost PROVIDER=<aws|evroc|exoscale|vultr> TFVARS="common-all.tfvars examples/<p>/terraform.tfvars"
tools/multicluster/cluster.sh cost <name> [cost args]
cd tools/cost && go run . --provider <p> --var-file F [--var-file F]... [flags]
```

`TFVARS` is a space-separated list; paths are relative to the repo root.
`cluster.sh cost` uses the cluster's provider and its var files.

| Flag | Default | Meaning |
|---|---|---|
| `--provider NAME` | required | `aws`, `evroc`, `exoscale` or `vultr` |
| `--var-file F` | none | tfvars file; repeatable, later wins |
| `--region R` | from tfvars or module default | override the region (required for aws and vultr when the tfvars set none; evroc and exoscale prices do not depend on it, and a null evroc region shows as `(evroc CLI context)`) |
| `--json` | off | print a JSON report instead of a table |
| `--catalog FILE` | none | use this provider catalog file instead of the network or cache |
| `--no-network` | off | never call the network; use `--catalog` or a warm cache |
| `--allow-unknown-plans` | off | price a rate missing from the catalog as 0 with a warning, instead of failing |
| `--durations LIST` | `1h,8h,24h,7d,30d` | durations to price (`h` and `d` units) |
| `--repo DIR` | walk up from the working directory | repo root (finds `modules/common/variables-common.tf`) |

### Var-file layering

Pass the files in the same order `deploy.sh` loads them, later wins:
`common-all.tfvars` (repo root), `examples/common-all.tfvars`,
`examples/common-<provider>.tfvars`, then the cluster's `terraform.tfvars`.
Variables not set in any file take the module defaults (`variables.tf` and the
`coalesce(var.X, "...")` defaults in `modules/<p>/locals.tf`).

### Exit codes

| Code | Meaning |
|---|---|
| 0 | estimate printed |
| 2 | config problem: flags, tfvars syntax or values, unreadable variables |
| 3 | pricing problem: catalog unavailable (including aws authentication), or a rate missing for a resource with quantity 1 or more |

## Output

Columns: `RESOURCE`, `ROLE`, `POOL`, `QTY`, `TYPE`, `<currency>/hr`, then one
column per duration. `ROLE` and `POOL` use the label vocabulary in
[docs/conventions.md](../../docs/conventions.md#labels).

- `TOTAL` is the steady-state cost of the running cluster.
- Rows marked `(build only)` exist only while the image is built (jumphost
  and builder VMs, build disks). They are summed in a separate `BUILD-ONLY`
  subtotal that is not part of `TOTAL`. Where `keep_build_artifacts`
  keeps a resource, it is priced as steady state.
- Rows with quantity 0 are omitted (nodes with `deploy_nodes = false`, pools
  with `count = 0`, disabled public IPs); a footer note says when node rows
  went.
- `*` marks a row capped at the monthly rate (vultr monthly-invoiced plans).
- Amounts are in the provider's native currency (aws and vultr USD, evroc EUR;
  exoscale EUR, one of the three currencies it publishes). There is no
  conversion.
- `Not included` lists resources that exist but are not priced, each with the
  reason.

## Price sources

### aws

Prices come from the AWS Price List API (`pricing:GetProducts`, served from
`us-east-1`, filtered by the cluster's region code): EC2 on-demand Linux
shared tenancy, gp3 and EBS snapshot per GB-month, NAT gateway, public IPv4
and network load balancer hours. Results are cached per region.

> **Gotcha: aws needs credentials and network.** You must be logged in with
> credentials that allow `pricing:GetProducts` (for example `aws sso login`,
> then `AWS_PROFILE=...`) and have network access. Without them `cost` exits
> with code 3 and does not fall back to stale prices.
> For offline use, run once while logged in, then use `--no-network` (reads
> the warm cache) or pass a saved catalog with `--catalog FILE` (a copy of the
> cache file `aws-pricing-<region>.json`).

Not included: data transfer, NLB capacity units (LCU), NAT gateway per-GB
processing, the raw image in S3.

### evroc

evroc provides no pricing API. Rates come from the public price calculator
(<https://evroc.com/cloud-services/virtual-machines/>) and are checked in as
`internal/provider/evroc/ratecard.json`, which records `currency`, `as_of`
(the date the rates were taken) and `source_url`. The report header shows the
`as_of` date. Prices are in EUR, excluding VAT, with 730 hours per month.

Refresh the rate card, then review the diff and commit it:

```
tools/cost/scripts/refresh-evroc-ratecard.sh -o tools/cost/internal/provider/evroc/ratecard.json
```

The script needs `bash`, `curl`, `jq` and `perl`. It downloads the page, finds
the web chunk that embeds the price list and rewrites the JSON. If evroc
changes the page structure the script fails and needs an update.

Not included: the load balancer and snapshots (no published rate), outbound
transfer (traffic-dependent; the first 100 GB are free, then billed per GB).

`--catalog FILE` takes a rate card in the same JSON format.

### exoscale

Prices come from the public price list
(<https://portal.exoscale.com/api/pricing/opencompute>, also behind
<https://www.exoscale.com/pricing/>). No API key is needed and nothing from
your account is read. The list has no zone dimension; the report uses its EUR
section (it also has CHF and USD). Cache and fallback work as for vultr: the
list is cached under the user cache directory and used when the URL is
unreachable or with `--no-network`; `--catalog FILE` takes a saved copy of the
list.

Instance types map to price keys by family and size (`standard.extra-large` →
`running_extra_large`, `gpu3.small` → `running_gpu3_small`). Instance prices
exclude the local disk, which is priced per GiB-hour (`volume`;
`volume_data` for the `storage` family). The template is priced per GiB-hour
on its virtual size (`image_disk_size`, at least 10 GiB) in the one zone. The
network load balancer is priced per hour. The public IPv4 of each instance,
the private network and security groups have no charge.

Not included: outbound traffic.

### vultr

Prices come from the public plans API (`/v2/plans` and `/v2/plans-metal`).
No API key is needed and nothing from your account is read. The decoded
catalog is cached under the user cache directory and is used when the API is
unreachable (the report header shows the cache age). Per-region price
overrides are applied. Monthly-invoiced plans are capped at the monthly rate.

The API does not list load balancer, NAT gateway or snapshot rates; the
catalog holds them as fixed rates (`lb`, `nat-gateway`, `storage:snapshot`)
and they need a manual update when the provider changes its prices.

Not included: bandwidth overage.

## Known limits

- Traffic-dependent charges are excluded for every provider.
- VAT and taxes are excluded.
- Regional availability and quota are not checked; `terraform plan` does that.
- Discounts, committed-use and credits are not applied.
- The estimate follows the tfvars: a cluster already running with different
  settings is not priced.

## Testing

```
make test-go        # gofmt, go vet, go test ./... (no network)
make cost-fixtures  # live tests (build tag `live`): network, aws needs credentials
```

`go test` never touches the network; catalogs come from fixtures and fakes.
Per provider, `TestDefaultsMatchLocals` parses `modules/<p>/locals.tf` and fails
when `defaults.go` diverges from it.

Golden outputs live in `testdata/golden/` and `internal/render/testdata/golden/`.
After an intended output change, regenerate and review the diff:

```
cd tools/cost
UPDATE_GOLDEN=1 go test .                 # testdata/golden
go test ./internal/render -update         # internal/render/testdata/golden
```
