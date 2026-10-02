# Same fabricated secrets as redact_valid.tfvars, but with an unterminated
# string literal on root_password_hash -- HCL's own parser diagnostic for
# this includes whatever it managed to scan of the token before EOF, which
# is exactly the case FromHCLDiagnostics must redact: Subject is inside this
# file, so Detail must never reach stdout/stderr.
region = "ams"

vultr_api_key = "F3C9A18B2D6E4F0A9B7C5D3E1F0A2B4C6D8E1F3A5B7C9D0E2F4A6B8C0D2E4F6A"

root_password_hash = "$6$rounds=656000$aVeryFakeSaltStr$q1w2e3r4t5y6u7i8o9p0AsDfGhJkLzXcVbNmQwErTyUiOpAsDfGhJkLz

node_user_password_hash = "$6$rounds=656000$anotherFakeSalt$z9x8c7v6b5n4m3l2k1j0HgFdSaPoIuYtReWqZxCvBnMlKjHgFdSa"

ssh_authorized_keys = ["ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIPlaceholderFakeKeyMaterialDoesNotDecodeToAnythingReal fake@example"]

nvidia_api_key = "nvapi-FAKEkQ1w2E3r4T5y6U7i8O9p0AsDfGhJkLzXcVbNmQwErTyUiOpAsDfGhJk"
