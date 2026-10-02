package aws

// defaults mirrors the `coalesce(var.X, literal)` defaults in
// modules/aws/locals.tf, keyed by variable name (numbers as decimal text).
// TestDefaultsMatchLocals fails when the two diverge.
var defaults = map[string]string{
	"vpc_cidr":                    "10.20.0.0/20",
	"vpc_mtu":                     "9001",
	"control_plane_instance_type": "m7i.xlarge",
	"control_plane_disk_size_gb":  "100",
	"jumphost_instance_type":      "c6i.xlarge",
	"jumphost_disk_size_gb":       "100",
}

// poolDiskGB mirrors `coalesce(p.disk_size_gb, 200)` for worker and GPU
// pools in locals.tf.
const poolDiskGB = 200

// defaultZones mirrors `min(3, ...)` in locals.tf: without var.zones the
// module spans the first three Availability Zones of the region.
const defaultZones = 3
