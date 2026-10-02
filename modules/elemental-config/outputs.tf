output "elemental_files" {
  description = "Elemental config dir contents keyed by relative path, comments stripped, including release_manifest.yaml. Contains credentials."
  value       = local.elemental_files
  sensitive   = true
}

output "elemental_file_names" {
  description = "Relative paths in elemental_files; not sensitive, usable as for_each keys."
  value       = nonsensitive(keys(local.elemental_files))
}

output "elemental_files_documented" {
  description = "elemental_files with comments and without release_manifest.yaml. Documentation aid only: nothing should consume it."
  value       = local.elemental_files_documented
  sensitive   = true
}

output "node_runtime_ignition" {
  description = "Per-node Ignition user data (JSON) keyed by hostname. Fails the plan when a node exceeds user_data_max_bytes."
  value       = local.node_runtime_ignition

  precondition {
    condition     = length(local.oversized_nodes) == 0
    error_message = "Per-node Ignition exceeds user_data_max_bytes (${var.user_data_max_bytes}): ${join(", ", local.oversized_nodes)}."
  }
}

output "build_hash" {
  description = "SHA-256 of every build input: rendered files, release manifest, elemental image, core platform override, sysext overrides and extra_build_inputs. Rebuild the image only when it changes."
  value       = local.build_hash
}

output "build_id" {
  description = "First 12 characters of build_hash, for resource names and labels."
  value       = substr(local.build_hash, 0, 12)
}

output "enabled_components" {
  description = "Enabled components in canonical order."
  value       = local.enabled_components
}

output "enabled_sysexts" {
  description = "systemd extensions required by the enabled components."
  value       = local.enabled_sysexts
}

output "effective_sysext_overrides" {
  description = "sysext_image_overrides narrowed to extensions that are enabled."
  value       = local.effective_sysext_overrides
}

output "dockerconfigjson_b64" {
  description = "Base64 dockerconfigjson for the Application Collection pull secret; null without appco credentials."
  value       = local.dockerconfigjson_b64
  sensitive   = true
}

output "rancher_bootstrap_password" {
  description = "Rancher bootstrap password: the input when set, else a generated one."
  value       = local.rancher_bootstrap_password
  sensitive   = true
}

output "release_manifest" {
  description = "Release manifest for the build host, rewritten in Terraform when beta overrides apply. Same content as release_manifest.yaml in elemental_files."
  value       = local.release_manifest

  precondition {
    condition     = length(local.unknown_sysext_overrides) == 0
    error_message = "sysext_image_overrides names extension(s) absent from the release manifest: ${join(", ", local.unknown_sysext_overrides)}. The manifest declares: ${join(", ", local.manifest_extension_names)}. Fix the name or set sysext_image_overrides = {}."
  }
}

output "release_manifest_url" {
  description = "URL the release manifest was fetched from."
  value       = local.release_manifest_url
}

output "write_node_ip_script" {
  description = "Rendered write-node-ip.sh, for providers that deliver it another way."
  value       = local.write_node_ip_script
}
