output "script" {
  description = "Complete build-host script: common steps with the hook bodies inlined. May contain whatever the hooks contain."
  value       = local.script
}

output "script_stripped" {
  description = "The script without comment lines (\"#!\" lines kept) and with blank runs collapsed."
  value       = local.script_stripped
}

output "script_hash" {
  description = "SHA-256 of script_stripped. Hashes exactly what is delivered, so pass placeholders for values derived from the build hash and substitute them afterwards."
  value       = sha256(local.script_stripped)
}
