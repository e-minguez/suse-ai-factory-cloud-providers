# 007 - cost estimator

## Status
Accepted.

## Context
Before a deploy, users want a rough idea of what a configuration costs, for
all three providers. The inputs could be a Terraform plan, the state, the
labels of running resources or the tfvars. Providers differ in how prices are
published: aws has an authenticated Price List API, vultr a public plans API,
and evroc has no pricing API (the public calculator embeds the price list in
its web page). Currencies differ too (aws and vultr USD, evroc EUR).

## Decision
`tools/cost` estimates from tfvars only. It does not read a plan, state or
labels, so it runs before anything exists and never touches credentials. Module
defaults that live in `modules/<p>/locals.tf` are mirrored in
`internal/provider/<p>/defaults.go`; `TestDefaultsMatchLocals` parses
`locals.tf` and fails when the two diverge.

Price sources:
- aws: Price List API (`pricing:GetProducts`). It needs credentials and network
  access and fails with exit code 3 otherwise; the live path never falls back
  to cached prices. `--catalog` and `--no-network` serve offline use.
- evroc: checked-in `ratecard.json` with an `as_of` date, refreshed by
  `tools/cost/scripts/refresh-evroc-ratecard.sh`. Load balancer and snapshot
  rates are not published and are listed as not included.
- vultr: public plans API, cached. Load balancer, NAT gateway and snapshot
  rates are fixed values in the catalog.

Amounts stay in the provider's native currency; there is no conversion, so
there is no exchange-rate source to maintain. Resources that exist only while
the image is built are summed in a separate build-only subtotal and are not
part of the steady-state total. Traffic-dependent charges and VAT are
excluded. Every report states that it is an estimate, not a quote.

## Consequences
- A new provider adds `internal/provider/<p>` and registers it; the shared
  parser, pricing and rendering stay unchanged.
- The estimate follows the tfvars: a running cluster with other settings is not
  priced.
- The evroc rate card goes stale until someone refreshes it; the `as_of` date is
  printed in every report.
- Prices the tool cannot know (traffic, discounts, taxes) are never part of the
  total. Real numbers come from the provider.
