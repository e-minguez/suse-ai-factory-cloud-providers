package vultr

// defaults mirrors the `coalesce(var.X, "literal")` defaults in
// modules/vultr/locals.tf, keyed by variable name. TestDefaultsMatchLocals
// fails when the two diverge.
var defaults = map[string]string{
	"vpc_cidr":                    "10.20.0.0/20",
	"vpc_mtu":                     "1450",
	"control_plane_instance_type": "vx1-g-4c-16g-240s",
	"jumphost_instance_type":      "vc2-6c-16gb",
	"jumphost_image":              "2656",
}

// lbNodes mirrors the constant `lb_nodes` local: every load balancer has one
// node. Checked by TestDefaultsMatchLocals.
const lbNodes = 1
