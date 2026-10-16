# Add-on components (SUSE Observability, SUSE Security). They are baked into the
# image as *-priority.yaml manifests, never through release.yaml, so no chart job
# can delay them (docs/decisions/001-elemental-config-rationale.md).

locals {
  addon_order = ["observability-server", "observability-plugin", "observability-agent", "security-management", "security-downstream"]

  # observability-server always runs an agent for its own cluster.
  addon_requested = distinct(concat(
    [for c in var.components : c if contains(local.addon_order, c)],
    contains(var.components, "observability-server") ? ["observability-agent"] : [],
  ))
  enabled_addons = [for c in local.addon_order : c if contains(local.addon_requested, c)]

  obs_server   = contains(local.enabled_addons, "observability-server")
  obs_agent    = contains(local.enabled_addons, "observability-agent")
  obs_plugin   = contains(local.enabled_addons, "observability-plugin")
  sec_mgmt     = contains(local.enabled_addons, "security-management")
  sec_down     = contains(local.enabled_addons, "security-downstream")
  sec_enabled  = local.sec_mgmt || local.sec_down
  rancher_on   = contains(var.components, "rancher")
  tls_needed   = local.obs_server || local.sec_mgmt
  tools_image  = "registry.opensuse.org/home/eminguez/containers/leap16/sts-tools:3.9.2"
  rancher_url  = "https://${var.rancher_hostname}"
  local_router = "http://suse-observability-router.suse-observability.svc.cluster.local:8080"

  # Chart and image versions, the single place to bump.
  addon_versions = {
    neuvector_ui_ext     = "2.2.1"
    observability_server = "2.10.3"
    observability_agent  = "1.5.40"
    observability_ext    = "2.2.0"
    otel_collector       = "0.175.1"
    observability_plugin = "2.4.2"
    # neuvector chart by Rancher minor
    neuvector_by_rancher = {
      "2.13" = "108.0.9+up2.11.2"
      "2.14" = "109.0.6+up2.11.2"
      "2.15" = "110.0.2+up2.11.2"
    }
  }

  # The neuvector chart tracks the Rancher release in the AIF manifest.
  rancher_chart_versions = local.sec_enabled ? try([
    for c in yamldecode(local.manifest_body).components.helm.charts : tostring(c.version) if c.chart == "rancher"
  ], []) : []
  rancher_chart_version   = try(local.rancher_chart_versions[0], null)
  rancher_minor           = try(regex("^v?([0-9]+\\.[0-9]+)\\.", local.rancher_chart_version)[0], null)
  neuvector_chart_version = try(lookup(local.addon_versions.neuvector_by_rancher, local.rancher_minor, null), null)

  # Hostnames. Defaults need ingress_domain or ingress_address; guarded in terraform_data.addon_guards.
  ingress_ip = var.ingress_address == null ? "" : var.ingress_address
  obs_host   = local.obs_server ? coalesce(var.observability_hostname, var.ingress_domain == null ? null : "obs.${var.ingress_domain}", "obs-${local.ingress_ip}.sslip.io") : ""
  otlp_host  = local.obs_server ? "otlp-${local.obs_host}" : ""
  otlp_http  = local.obs_server ? "otlp-http-${local.obs_host}" : ""
  nv_host    = local.sec_enabled ? coalesce(var.security_hostname, var.ingress_domain == null ? null : "neuvector.${var.ingress_domain}", "neuvector-${local.ingress_ip}.sslip.io") : ""
  fed_host   = local.sec_enabled ? "fed-${local.nv_host}" : ""

  needs_ingress_address = (
    var.ingress_domain == null && (
      (local.obs_server && var.observability_hostname == null) ||
      (local.sec_enabled && var.security_hostname == null)
    )
  )

  ingress_hosts = concat(
    local.obs_server ? [local.obs_host, local.otlp_host, local.otlp_http] : [],
    local.sec_mgmt ? [local.nv_host] : [],
  )
  backend_hosts = [for s in ["", ".cattle-neuvector-system", ".cattle-neuvector-system.svc", ".cattle-neuvector-system.svc.cluster.local"] : "neuvector-service-webui${s}"]

  # Federation primary: own host on the management cluster, the variable on downstream.
  primary_parts  = local.sec_down ? split(":", coalesce(var.security_primary_endpoint, "unset")) : []
  primary_server = local.sec_mgmt ? local.fed_host : (local.sec_down ? local.primary_parts[0] : "")
  primary_port   = local.sec_mgmt ? 443 : (local.sec_down ? (length(local.primary_parts) > 1 ? tonumber(local.primary_parts[1]) : 443) : 443)

  # Rancher URL for NeuVector SSO, ending with exactly one slash.
  security_rancher_base = var.security_rancher_url != null ? var.security_rancher_url : (local.rancher_on ? local.rancher_url : "")
  security_rancher_url  = local.security_rancher_base == "" ? "" : "${replace(local.security_rancher_base, "/\\/+$/", "")}/"

  # Remote server: URL without trailing slash and its OTLP gRPC host.
  remote_url       = var.observability_server_url == null ? "" : trimsuffix(var.observability_server_url, "/")
  remote_host      = try(regex("^https?://([^/:]+)", local.remote_url)[0], "")
  agent_local      = local.obs_server
  allowed_origins  = distinct(concat(local.rancher_on ? ["${local.rancher_url}/"] : [], var.observability_allowed_origins))
  appco_dockerjson = local.dockerconfigjson_b64 == null ? "" : local.dockerconfigjson_b64
}

# Preconditions that the per-variable validations cannot express.
resource "terraform_data" "addon_guards" {
  lifecycle {
    precondition {
      condition     = !local.needs_ingress_address || var.ingress_address != null
      error_message = "ingress_address is null but a hostname default (obs-<ip>.sslip.io or neuvector-<ip>.sslip.io) is needed. Set ingress_address, or observability_hostname and security_hostname."
    }

    precondition {
      condition     = !local.sec_enabled || local.neuvector_chart_version != null
      error_message = "No neuvector chart is mapped to the Rancher version in the release manifest (${coalesce(local.rancher_chart_version, "none")}). Known minors: ${join(", ", keys(local.addon_versions.neuvector_by_rancher))}; extend addon_versions in addons.tf."
    }

    precondition {
      condition     = !local.sec_down || (nonsensitive(var.security_join_token != null) && var.security_primary_endpoint != null)
      error_message = "security-downstream needs security_join_token and security_primary_endpoint."
    }

    precondition {
      condition     = !(local.obs_agent || local.obs_plugin) || local.obs_server || (var.observability_server_url != null && var.observability_ca_pem != null && nonsensitive(var.observability_bootstrap_token != null))
      error_message = "observability-agent and observability-plugin without observability-server need observability_server_url, observability_ca_pem and observability_bootstrap_token."
    }
  }
}

resource "random_password" "security_admin" {
  count   = local.sec_enabled && var.security_admin_password == null ? 1 : 0
  length  = 24
  special = false
}

resource "random_uuid" "security_join" {
  count = local.sec_mgmt && var.security_join_token == null ? 1 : 0
}

resource "random_password" "observability_admin" {
  count   = local.obs_server && var.observability_admin_password == null ? 1 : 0
  length  = 24
  special = false
}

resource "random_password" "observability_bootstrap" {
  count   = local.obs_server && var.observability_bootstrap_token == null ? 1 : 0
  length  = 32
  special = false
}

locals {
  # Conditionals, not coalesce(): see rancher_bootstrap_password.
  security_admin_password       = !local.sec_enabled ? null : (var.security_admin_password != null ? var.security_admin_password : random_password.security_admin[0].result)
  security_join_token           = !local.sec_enabled ? null : (var.security_join_token != null ? var.security_join_token : (local.sec_mgmt ? random_uuid.security_join[0].result : ""))
  observability_admin_password  = !local.obs_server ? null : (var.observability_admin_password != null ? var.observability_admin_password : random_password.observability_admin[0].result)
  observability_bootstrap_token = local.obs_server ? (var.observability_bootstrap_token != null ? var.observability_bootstrap_token : random_password.observability_bootstrap[0].result) : (var.observability_bootstrap_token == null ? "" : var.observability_bootstrap_token)
}

# One CA per cluster, one leaf for every enabled ingress host, and an RSA leaf
# for the NeuVector Manager backend (its Java keystore wants PKCS#1).
resource "tls_private_key" "ca" {
  count       = local.tls_needed ? 1 : 0
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_self_signed_cert" "ca" {
  count                 = local.tls_needed ? 1 : 0
  private_key_pem       = tls_private_key.ca[0].private_key_pem
  is_ca_certificate     = true
  validity_period_hours = 87600
  allowed_uses          = ["cert_signing", "crl_signing"]

  subject {
    common_name  = "${var.cluster_name} SUSE AI Factory CA"
    organization = "SUSE AI Factory"
  }
}

resource "tls_private_key" "ingress" {
  count       = local.tls_needed ? 1 : 0
  algorithm   = "ECDSA"
  ecdsa_curve = "P256"
}

resource "tls_cert_request" "ingress" {
  count           = local.tls_needed ? 1 : 0
  private_key_pem = tls_private_key.ingress[0].private_key_pem
  dns_names       = local.ingress_hosts

  subject {
    common_name = local.ingress_hosts[0]
  }
}

resource "tls_locally_signed_cert" "ingress" {
  count              = local.tls_needed ? 1 : 0
  cert_request_pem   = tls_cert_request.ingress[0].cert_request_pem
  ca_private_key_pem = tls_private_key.ca[0].private_key_pem
  ca_cert_pem        = tls_self_signed_cert.ca[0].cert_pem
  # 820 days: Apple platforms reject server certificates valid for more than 825.
  validity_period_hours = 19680
  early_renewal_hours   = 720
  allowed_uses          = ["server_auth", "digital_signature", "key_encipherment"]
}

resource "tls_private_key" "neuvector_backend" {
  count     = local.sec_mgmt ? 1 : 0
  algorithm = "RSA"
  rsa_bits  = 2048
}

resource "tls_cert_request" "neuvector_backend" {
  count           = local.sec_mgmt ? 1 : 0
  private_key_pem = tls_private_key.neuvector_backend[0].private_key_pem
  dns_names       = local.backend_hosts

  subject {
    common_name = local.backend_hosts[0]
  }
}

resource "tls_locally_signed_cert" "neuvector_backend" {
  count                 = local.sec_mgmt ? 1 : 0
  cert_request_pem      = tls_cert_request.neuvector_backend[0].cert_request_pem
  ca_private_key_pem    = tls_private_key.ca[0].private_key_pem
  ca_cert_pem           = tls_self_signed_cert.ca[0].cert_pem
  validity_period_hours = 43800
  allowed_uses          = ["server_auth", "digital_signature", "key_encipherment"]
}

locals {
  ca_pem           = local.tls_needed ? tls_self_signed_cert.ca[0].cert_pem : ""
  ingress_cert_pem = local.tls_needed ? tls_locally_signed_cert.ingress[0].cert_pem : ""
  ingress_key_pem  = local.tls_needed ? tls_private_key.ingress[0].private_key_pem : ""
  backend_cert_pem = local.sec_mgmt ? tls_locally_signed_cert.neuvector_backend[0].cert_pem : ""
  backend_key_pem  = local.sec_mgmt ? tls_private_key.neuvector_backend[0].private_key_pem : ""
  manifests_dir    = "${path.module}/templates/elemental/kubernetes/manifests"

  addon_manifests = merge(
    !local.sec_enabled ? {} : {
      "kubernetes/manifests/security-priority.yaml" = templatefile("${local.manifests_dir}/security.yaml.tftpl", {
        role                 = local.sec_mgmt ? "management" : "downstream"
        chart_version        = local.neuvector_chart_version
        cluster_name         = var.cluster_name
        rancher_url          = local.security_rancher_url
        rancher_cluster_name = local.rancher_on ? "local" : var.cluster_name
        manager_hostname     = local.sec_mgmt ? local.nv_host : ""
        federation_hostname  = local.fed_host
        primary_server       = local.primary_server
        primary_port         = local.primary_port
        join_token           = local.security_join_token
        admin_password       = local.security_admin_password
        ca_pem               = local.ca_pem
        manager_tls_cert_pem = local.ingress_cert_pem
        manager_tls_key_pem  = local.ingress_key_pem
        backend_cert_pem     = local.backend_cert_pem
        backend_key_pem      = local.backend_key_pem
        tools_image          = local.tools_image
      })
    },
    !(local.sec_mgmt && local.rancher_on) ? {} : {
      "kubernetes/manifests/security-ui-extension-priority.yaml" = templatefile("${local.manifests_dir}/security-ui-extension.yaml.tftpl", {
        version = local.addon_versions.neuvector_ui_ext
      })
    },
    !local.obs_server ? {} : {
      "kubernetes/manifests/observability-server-priority.yaml" = templatefile("${local.manifests_dir}/observability-server.yaml.tftpl", {
        versions             = { server = local.addon_versions.observability_server, extension = local.addon_versions.observability_ext }
        license_key          = var.observability_license_key == null ? "" : var.observability_license_key
        admin_password       = local.observability_admin_password
        bootstrap_token      = local.observability_bootstrap_token
        sizing_profile       = var.observability_sizing_profile
        hostname             = local.obs_host
        otlp_hostname        = local.otlp_host
        otlp_http_hostname   = local.otlp_http
        allowed_origins      = local.allowed_origins
        ca_pem               = local.ca_pem
        tls_cert_pem         = local.ingress_cert_pem
        tls_key_pem          = local.ingress_key_pem
        cluster_name         = var.cluster_name
        dockerconfigjson_b64 = local.appco_dockerjson
        appco_registry       = var.appco_registry
        tools_image          = local.tools_image
      })
    },
    !local.obs_agent ? {} : {
      "kubernetes/manifests/observability-agent-priority.yaml" = templatefile("${local.manifests_dir}/observability-agent.yaml.tftpl", {
        versions             = { agent = local.addon_versions.observability_agent, collector = local.addon_versions.otel_collector }
        cluster_name         = var.cluster_name
        local_server         = local.agent_local
        api_url              = local.agent_local ? local.local_router : local.remote_url
        receiver_url         = "${local.agent_local ? local.local_router : local.remote_url}/receiver/stsAgent"
        topology_endpoint    = local.agent_local ? local.local_router : local.remote_url
        otlp_exporter        = local.agent_local ? "otlp_http/suse-observability" : "otlp_grpc/suse-observability"
        otlp_endpoint        = local.agent_local ? "http://suse-observability-otel-collector.suse-observability.svc.cluster.local:4318" : "otlp-${local.remote_host}:443"
        ca_pem               = local.agent_local || var.observability_ca_pem == null ? "" : var.observability_ca_pem
        bootstrap_token      = local.observability_bootstrap_token
        suse_ai_namespace    = var.observability_suse_ai_namespace
        opensearch_username  = try(var.observability_opensearch_credentials.username, "")
        opensearch_password  = try(var.observability_opensearch_credentials.password, "")
        dockerconfigjson_b64 = local.appco_dockerjson
        appco_registry       = var.appco_registry
        tools_image          = local.tools_image
      })
    },
    !local.obs_plugin ? {} : {
      "kubernetes/manifests/observability-plugin-priority.yaml" = templatefile("${local.manifests_dir}/observability-plugin.yaml.tftpl", {
        version         = local.addon_versions.observability_plugin
        external_url    = local.obs_server ? "https://${local.obs_host}" : local.remote_url
        api_url         = local.obs_server ? local.local_router : local.remote_url
        ca_pem          = local.obs_server || var.observability_ca_pem == null ? "" : var.observability_ca_pem
        bootstrap_token = local.observability_bootstrap_token
        tools_image     = local.tools_image
      })
    },
  )

  security_output = !local.sec_enabled ? null : {
    role                = local.sec_mgmt ? "management" : "downstream"
    url                 = local.sec_mgmt ? "https://${local.nv_host}" : null
    federation_endpoint = "${local.fed_host}:443"
    ca_pem              = local.sec_mgmt ? tls_self_signed_cert.ca[0].cert_pem : null
  }

  security_credentials_output = !local.sec_enabled ? null : {
    admin_password = local.security_admin_password
    join_token     = local.security_join_token
  }

  observability_output = !local.obs_server ? null : {
    url                = "https://${local.obs_host}"
    ca_pem             = local.ca_pem
    otlp_grpc_endpoint = "${local.otlp_host}:443"
    otlp_http_endpoint = "https://${local.otlp_http}"
  }

  observability_credentials_output = !local.obs_server ? null : {
    admin_password  = local.observability_admin_password
    bootstrap_token = local.observability_bootstrap_token
  }
}
