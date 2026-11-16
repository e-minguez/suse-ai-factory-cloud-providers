package oci

// defaults mirrors the `coalesce(var.X, literal)` defaults in
// modules/oci/locals.tf, keyed by variable name. TestDefaultsMatchLocals
// fails when the two diverge.
var defaults = map[string]string{
	"region":                      "eu-frankfurt-1",
	"vpc_cidr":                    "10.20.0.0/20",
	"vpc_mtu":                     "9000",
	"control_plane_instance_type": "VM.Standard.E5.Flex:4x32",
	"control_plane_disk_size_gb":  "100",
	"jumphost_instance_type":      "VM.Standard.E5.Flex:2x16",
	"jumphost_disk_size_gb":       "100",
}

// agentDiskGB mirrors the constant `agent_disk_gb` local, the pool disk size
// when a pool sets none. Checked by TestDefaultsMatchLocals.
const agentDiskGB = 200.0
