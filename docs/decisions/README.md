# Architecture decisions

Short ADRs for choices that need rationale and history kept out of code
comments (see `CLAUDE.md`, "Writing style"). Code comments link back here
with `# see docs/decisions/NNN-title.md`.

## Format

- File name: `NNN-title.md`, zero-padded, sequential, kebab-case title.
- Sections: `Status` (proposed / accepted / superseded by NNN),
  `Context`, `Decision`, `Consequences`.
- Keep it short: a paragraph or two per section is usually enough.
- Neutral tone about cloud providers and tools, as everywhere else in this
  repo (state platform behaviour as fact, then the resulting choice).

## Index

- [001](001-elemental-config-rationale.md) elemental-config rationale
- [002](002-aws-factory-hooks.md) aws image-factory hooks
- [003](003-rebuild-counter.md) rebuild counter
- [004](004-evroc-module-rationale.md) evroc module rationale
- [005](005-state-secrets.md) secrets in Terraform state
- [006](006-vultr-two-passes.md) vultr deploys in two passes
- [007](007-cost-estimator.md) cost estimator
