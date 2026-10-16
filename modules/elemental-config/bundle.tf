locals {
  # One delimiter for every heredoc; the output precondition rejects files
  # containing it as a line.
  config_bundle_delimiter = "__ELEMENTAL_CONFIG_EOF_7f3c__"

  # Heredoc bodies end with a newline, so a file lacking one gains it: the
  # only difference between a bundled file and the original content.
  config_bundle_files = {
    for path, content in local.elemental_files :
    path => endswith(content, "\n") ? content : "${content}\n"
  }

  config_bundle_script = templatefile("${path.module}/templates/config-bundle.sh.tftpl", {
    files     = local.config_bundle_files
    delimiter = local.config_bundle_delimiter
  })

  config_bundle_bad_paths = [
    for path in keys(local.elemental_files) :
    path if !can(regex("^[A-Za-z0-9._/-]+$", path)) || strcontains(path, "..")
  ]

  config_bundle_delimiter_files = nonsensitive([
    for path, content in local.elemental_files :
    path if can(regex("(?m)^${local.config_bundle_delimiter}$", content))
  ])
}

output "config_bundle_script" {
  description = "Self-extracting bash script that writes every elemental_files entry under the directory given as $1. Plain text; use config_bundle for delivery. Contains credentials."
  value       = local.config_bundle_script
  sensitive   = true

  precondition {
    condition     = length(local.config_bundle_bad_paths) == 0
    error_message = "Config file paths must match ^[A-Za-z0-9._/-]+$ and not contain '..': ${join(", ", local.config_bundle_bad_paths)}."
  }

  precondition {
    condition     = length(local.config_bundle_delimiter_files) == 0
    error_message = "Config files contain a line equal to the bundle heredoc delimiter ${local.config_bundle_delimiter}: ${join(", ", local.config_bundle_delimiter_files)}."
  }
}

output "config_bundle" {
  description = "base64gzip of config_bundle_script: all elemental_files as one compressed payload for cloud-init write_files (encoding gz+b64). Contains credentials."
  value       = base64gzip(local.config_bundle_script)
  sensitive   = true
}
