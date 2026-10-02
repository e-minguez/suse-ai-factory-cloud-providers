package evroc

// defaults mirrors the `coalesce(var.X, literal)` defaults in
// modules/evroc/locals.tf, keyed by variable name. TestDefaultsMatchLocals
// fails when the two diverge.
var defaults = map[string]string{
	"vpc_cidr":                    "10.20.0.0/16",
	"vpc_mtu":                     "8900",
	"control_plane_instance_type": "c1a.m",
	"control_plane_disk_size_gb":  "200",
	"jumphost_instance_type":      "a1a.m",
	"jumphost_disk_size_gb":       "200",
}

// defaultZones mirrors `length(var.zones) > 0 ? var.zones : ["a", "b", "c"]`.
// Checked by TestDefaultsMatchLocals.
var defaultZones = []string{"a", "b", "c"}

// defaultImageTargetDiskGB mirrors variable "image_target_disk_gb" in
// modules/evroc/variables.tf. Checked by TestDefaultsMatchLocals.
const defaultImageTargetDiskGB = 32.0

// regionCLIContext labels the report when region is null in the tfvars.
const regionCLIContext = "(evroc CLI context)"
