# Layer 3 of 3 (per-cluster terraform.tfvars shape). Fabricated secrets.
cluster_name            = "redact-test"
admin_cidrs             = ["203.0.113.0/24"]
root_password_hash      = "$6$rounds=656000$aVeryFakeSaltStr$fakehashfakehashfakehash"
node_user_password_hash = "$6$rounds=656000$anotherFakeSalt$fakehashfakehashfakehash"
