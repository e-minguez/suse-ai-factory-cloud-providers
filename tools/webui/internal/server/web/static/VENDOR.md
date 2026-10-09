# Vendored assets

| File | Source | Version | SHA-256 |
|------|--------|---------|---------|
| htmx.min.js | https://unpkg.com/htmx.org@2.0.11/dist/htmx.min.js | htmx 2.0.11 | d6fdc75f204e6bdefa99b69bf1e6d4ac69b8a364f77929f45c13476b4000f717 |
| sse.js | https://unpkg.com/htmx-ext-sse@2.2.4/sse.js | htmx-ext-sse 2.2.4 | 3b5992a541619babefc4c169505af474df5c3039da51e59b96ccf9241ecd61d2 |

Both are BSD 0-clause / 2-clause licensed upstream (bigskysoftware). Update by re-downloading a pinned version and recording it here.

## SUSE font

- `fonts/suse-latin.woff2` (sha256 bdc06c71ae150def7115efd8a03dd98fbd4ce58810d0ade9c35af863ae6153e2) and
  `fonts/suse-latin-ext.woff2` (sha256 b52bffe11d34ba7ea365236cb6ca61d332b1daded54be38fdd7dba1fb1aa7257):
  variable font (weights 100-800), Google Fonts `SUSE` v4, from https://github.com/SUSE/suse-font.
- License: SIL Open Font License 1.1, `fonts/OFL.txt`. Self-hosted so the strict CSP and offline use work.

## Provider marks

`providers.svg` (sha256 5d683a74a6d3e8f02095d9abfa65b532f94c7f12ae12cda9bf9671061a808184): one `<symbol>` per provider,
path coordinates rounded to 1 decimal and colours removed so CSS sets them.
- evroc: https://evroc.com/favicon.svg
- Exoscale, Vultr: Simple Icons 16.34.0 path data (CC0), `icons/exoscale.svg`, `icons/vultr.svg`.
- AWS: Simple Icons 13.0.0 `icons/amazonwebservices.svg` (removed from later releases).

The marks are trademarks of their owners, used only to identify the provider.
