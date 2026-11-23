package azure

// defaults mirrors the `coalesce(var.X, literal)` defaults in
// modules/azure/locals.tf, keyed by variable name. TestDefaultsMatchLocals
// fails when the two diverge.
var defaults = map[string]string{
	"region":                      "westeurope",
	"vpc_cidr":                    "10.20.0.0/20",
	"vpc_mtu":                     "1500",
	"control_plane_instance_type": "Standard_D8s_v5",
	"control_plane_disk_size_gb":  "100",
	"jumphost_instance_type":      "Standard_D4s_v5",
	"jumphost_disk_size_gb":       "100",
	"jumphost_image":              "SUSE:sles-16-0-x86-64:gen2:latest",
}

// agentDiskGB mirrors the constant `agent_disk_gb` local, the pool disk size
// when a pool sets none. Checked by TestDefaultsMatchLocals.
const agentDiskGB = 200.0
