# syntax=docker/dockerfile:1
# Build context: repository root (docker build -f tools/webui/Dockerfile .).
# Base images are pinned by tag; dependabot (docker ecosystem) bumps them.
# Unofficial community image, not an official SUSE product.

# ---------------------------------------------------------------- build
# Runs on the build platform and cross-compiles, so multi-arch builds do not
# emulate the Go toolchain.
FROM --platform=$BUILDPLATFORM registry.suse.com/bci/golang:1.27 AS build
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV CGO_ENABLED=0 GOFLAGS=-trimpath GOOS=linux
ARG TARGETARCH
WORKDIR /src/tools/webui
COPY tools/webui/go.mod tools/webui/go.sum ./
COPY tools/cost/go.mod tools/cost/go.sum /src/tools/cost/
RUN go mod download
WORKDIR /src/tools/cost
RUN go mod download
COPY tools/cost /src/tools/cost
RUN GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o /out/cost .
COPY tools/webui /src/tools/webui
WORKDIR /src/tools/webui
RUN GOARCH=${TARGETARCH} go build -ldflags="-s -w" -o /out/webui .

# ------------------------------------------------------------ terraform
# Downloads Terraform for the build platform (runs the provider mirror) and for
# the target platform (copied into the image).
FROM --platform=$BUILDPLATFORM registry.suse.com/bci/bci-base:16.0 AS terraform
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TF_VERSION=1.16.5
ARG BUILDARCH
ARG TARGETARCH
# HashiCorp release signing key, https://www.hashicorp.com/trust/security
ARG HASHICORP_SIGNER_FPR=C874011F0AB405110D02105534365D9472D7468F
RUN zypper --non-interactive install --no-recommends unzip gpg2 curl ca-certificates && zypper clean --all
WORKDIR /tf
RUN set -eu; \
    base="https://releases.hashicorp.com/terraform/${TF_VERSION}"; \
    sums="terraform_${TF_VERSION}_SHA256SUMS"; \
    curl -fsSL --retry 5 --retry-all-errors -O "${base}/${sums}"; \
    curl -fsSL --retry 5 --retry-all-errors -O "${base}/${sums}.sig"; \
    curl -fsSL --retry 5 --retry-all-errors https://www.hashicorp.com/.well-known/pgp-key.txt -o hashicorp.asc; \
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
    gpg --batch --import hashicorp.asc; \
    status="$(gpg --batch --status-fd 1 --verify "${sums}.sig" "${sums}")"; \
    printf '%s\n' "${status}" | grep -q "^\[GNUPG:\] VALIDSIG .* ${HASHICORP_SIGNER_FPR}\$"; \
    for arch in "${BUILDARCH}" "${TARGETARCH}"; do \
      zip="terraform_${TF_VERSION}_linux_${arch}.zip"; \
      [ -f "${zip}" ] || curl -fsSL --retry 5 --retry-all-errors -O "${base}/${zip}"; \
      grep " ${zip}\$" "${sums}" | sha256sum -c -; \
    done; \
    mkdir -p /out/build /out/target; \
    unzip -q "terraform_${TF_VERSION}_linux_${BUILDARCH}.zip" terraform -d /out/build; \
    unzip -q "terraform_${TF_VERSION}_linux_${TARGETARCH}.zip" terraform -d /out/target

# Mirror every provider the example and tool roots need; the runtime has only
# filesystem_mirror (tools/webui/terraformrc). `terraform get` installs the
# local modules first, so their provider requirements are included.
COPY modules /work/modules
COPY examples /work/examples
COPY tools/multicluster /work/tools/multicluster
RUN set -eu; \
    export TF_CLI_CONFIG_FILE=/dev/null; \
    mkdir -p /out/plugins; \
    for d in /work/examples/*/ /work/tools/multicluster/register; do \
      [ -f "${d}/main.tf" ] || continue; \
      /out/build/terraform -chdir="${d}" get >/dev/null; \
      /out/build/terraform -chdir="${d}" providers mirror -platform="linux_${TARGETARCH}" /out/plugins; \
      rm -rf "${d}/.terraform"; \
    done

# ----------------------------------------------------------------- clis
# aws and evroc CLIs for the aws precheck and the leftovers checks. Nothing is
# executed here, so the stage runs on the build platform.
FROM --platform=$BUILDPLATFORM registry.suse.com/bci/bci-base:16.0 AS clis
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG AWSCLI_VERSION=2.37.10
ARG TARGETARCH
# AWS CLI team key, https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
# The keyserver copy can carry an older expiry date; VALIDSIG still checks the fingerprint.
ARG AWSCLI_SIGNER_FPR=FB5DB77FD5C118B80511ADA8A6310ACC4672475C
RUN zypper --non-interactive install --no-recommends unzip gpg2 curl ca-certificates && zypper clean --all
WORKDIR /clis
RUN set -eu; \
    case "${TARGETARCH}" in amd64) a=x86_64 ;; arm64) a=aarch64 ;; *) exit 1 ;; esac; \
    zip="awscli-exe-linux-${a}-${AWSCLI_VERSION}.zip"; \
    curl -fsSL --retry 5 --retry-all-errors -O "https://awscli.amazonaws.com/${zip}"; \
    curl -fsSL --retry 5 --retry-all-errors -O "https://awscli.amazonaws.com/${zip}.sig"; \
    curl -fsSL --retry 5 --retry-all-errors "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x${AWSCLI_SIGNER_FPR}" -o awscli.asc; \
    GNUPGHOME="$(mktemp -d)"; export GNUPGHOME; \
    gpg --batch --import awscli.asc; \
    status="$(gpg --batch --status-fd 1 --verify "${zip}.sig" "${zip}" || true)"; \
    printf '%s\n' "${status}" | grep -q "^\[GNUPG:\] VALIDSIG .* ${AWSCLI_SIGNER_FPR}\$"; \
    unzip -q "${zip}"; \
    mkdir -p /out/bin; \
    mv aws/dist /out/aws-cli; \
    ln -s /usr/local/aws-cli/aws /out/bin/aws
# evroc publishes only a "latest" download with a checksum file next to it, so
# the version is whatever is current at build time.
RUN set -eu; \
    url="https://downloads.cloud.evroc.com/evroc-cli/latest/linux_${TARGETARCH}/evroc"; \
    curl -fsSL --retry 5 --retry-all-errors "${url}" -o evroc; \
    curl -fsSL --retry 5 --retry-all-errors "${url}.sha256" -o evroc.sha256; \
    echo "$(cut -d' ' -f1 evroc.sha256)  evroc" | sha256sum -c -; \
    install -m 0755 evroc /out/bin/evroc

# --------------------------------------------------------------- rootfs
FROM registry.suse.com/bci/bci-micro:16.0 AS micro

FROM registry.suse.com/bci/bci-base:16.0 AS rootfs
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --from=micro / /rootfs
# micro already has bash and coreutils-single (GNU coreutils, conflicts with coreutils).
# --gpg-auto-import-keys: the copied micro rpm database has no repository key yet
# (pattern from https://opensource.suse.com/bci-docs/guides/deploy-using-zypper/).
RUN zypper --installroot /rootfs --non-interactive --gpg-auto-import-keys install --no-recommends \
      jq openssh-clients openssl curl ca-certificates sed grep gawk findutils gzip tar && \
    zypper --non-interactive --installroot /rootfs clean --all && \
    rm -rf /rootfs/var/cache/zypp /rootfs/var/log/* /rootfs/usr/share/doc /rootfs/usr/share/man && \
    echo 'aif:x:1000:1000:aif:/opt/aif/clusters/.home:/bin/bash' >> /rootfs/etc/passwd && \
    echo 'aif:x:1000:' >> /rootfs/etc/group && \
    mkdir -p /rootfs/opt/aif/clusters /rootfs/tmp && \
    chown -R 1000:1000 /rootfs/opt/aif/clusters && chmod 1777 /rootfs/tmp

# ----------------------------------------------------------------- repo
# Repository content the scripts need at runtime; no Go sources.
FROM registry.suse.com/bci/bci-base:16.0 AS repo
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
WORKDIR /opt/aif
COPY modules ./modules
COPY examples ./examples
COPY scripts ./scripts
COPY tools ./tools
COPY common-all.tfvars.example version.txt ./
RUN rm -rf tools/cost tools/webui
# Only ui.yaml of tools/webui is read at runtime.
COPY tools/webui/ui.yaml ./tools/webui/ui.yaml

# ---------------------------------------------------------------- final
FROM scratch
ARG VERSION=dev
ARG REVISION=unknown
LABEL org.opencontainers.image.title="suse-ai-factory-cloud-providers" \
      org.opencontainers.image.description="Alpha. Unofficial community web UI to deploy SUSE AI Factory on cloud providers with Terraform. Not an official SUSE product." \
      org.opencontainers.image.source="https://github.com/e-minguez/suse-ai-factory-cloud-providers" \
      org.opencontainers.image.url="https://github.com/e-minguez/suse-ai-factory-cloud-providers" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.vendor="community" \
      org.opencontainers.image.version="${VERSION}" \
      org.opencontainers.image.revision="${REVISION}"
COPY --from=rootfs /rootfs/ /
COPY --from=terraform /out/target/terraform /usr/local/bin/terraform
COPY --from=terraform /out/plugins /usr/share/terraform/plugins
COPY tools/webui/terraformrc /etc/terraformrc
COPY --from=build /out/webui /out/cost /usr/local/bin/
COPY --from=clis /out/aws-cli /usr/local/aws-cli
COPY --from=clis /out/bin/ /usr/local/bin/
COPY --from=repo /opt/aif /opt/aif
# -upgrade: the mirror has one version per provider; older lock files move to it.
ENV HOME=/opt/aif/clusters/.home \
    PATH=/usr/local/bin:/usr/bin:/bin \
    TF_CLI_CONFIG_FILE=/etc/terraformrc \
    TF_CLI_ARGS_init=-upgrade \
    TF_IN_AUTOMATION=1 \
    WEBUI_ADDR=0.0.0.0:8080 \
    WEBUI_REPO=/opt/aif \
    WEBUI_COST_BIN=/usr/local/bin/cost
USER 1000:1000
WORKDIR /opt/aif
VOLUME /opt/aif/clusters
EXPOSE 8080
# Works with --read-only --tmpfs /tmp: only /tmp and the volume are written.
# The webui is PID 1; run with --init to reap child processes.
ENTRYPOINT ["/usr/local/bin/webui"]
