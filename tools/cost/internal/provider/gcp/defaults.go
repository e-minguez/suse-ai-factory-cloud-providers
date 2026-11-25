package gcp

// defaults mirrors the `coalesce(var.X, literal)` defaults in
// modules/gcp/locals.tf, keyed by variable name. TestDefaultsMatchLocals
// fails when the two diverge.
var defaults = map[string]string{
	"region":                      "europe-west4",
	"vpc_cidr":                    "10.20.0.0/20",
	"vpc_mtu":                     "1460",
	"control_plane_instance_type": "n2-standard-4",
	"control_plane_disk_size_gb":  "100",
	"jumphost_instance_type":      "e2-standard-4",
	"jumphost_disk_size_gb":       "100",
	"jumphost_image":              "projects/opensuse-cloud/global/images/family/opensuse-leap",
}

// agentDiskGB mirrors the constant `agent_disk_gb` local, the pool disk size
// when a pool sets none. Checked by TestDefaultsMatchLocals.
const agentDiskGB = 200.0
