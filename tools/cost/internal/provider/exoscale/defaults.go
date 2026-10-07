package exoscale

// defaults mirrors the `coalesce(var.X, literal)` defaults in
// modules/exoscale/locals.tf, keyed by variable name. TestDefaultsMatchLocals
// fails when the two diverge.
var defaults = map[string]string{
	"region":                      "de-fra-1",
	"vpc_cidr":                    "10.20.0.0/20",
	"vpc_mtu":                     "1500",
	"control_plane_instance_type": "standard.extra-large",
	"control_plane_disk_size_gb":  "100",
	"jumphost_instance_type":      "standard.large",
	"jumphost_disk_size_gb":       "50",
	"jumphost_image":              "OpenSUSE Leap 16.0 64-bit",
}

// agentDiskGB mirrors the constant `agent_disk_gb` local, the pool disk size
// when a pool sets none. Checked by TestDefaultsMatchLocals.
const agentDiskGB = 200.0

// templateMinGiB mirrors the constant `template_min_gib` local: the jumphost
// grows the qcow2 virtual size to at least this. Checked by
// TestDefaultsMatchLocals.
const templateMinGiB = 10.0
