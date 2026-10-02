// Package tfconfig parses the module variable declarations and layered
// tfvars, and resolves them into the narrow Common struct providers price.
//
// Security boundary: Common and Pool hold only typed Go values copied out of
// cty for the handful of variables pricing needs. No cty.Value and no map of
// "everything the tfvars set" leaves this package, and credentials are never
// read: a new sensitive variable is safe by construction, because resolving
// it would need an explicit edit here (an allow-list, not a deny-list).
package tfconfig

import (
	"fmt"
	"regexp"
	"sort"
	"strconv"

	"github.com/hashicorp/hcl/v2"
	"github.com/hashicorp/hcl/v2/ext/typeexpr"
	"github.com/zclconf/go-cty/cty"
	"github.com/zclconf/go-cty/cty/convert"
	"github.com/zclconf/go-cty/cty/gocty"
)

// Common is the provider-neutral view of a deployment, from
// modules/common/variables-common.tf. Fields a provider fills with its own
// default when null ("" or nil here) are applied by that provider's Resolve.
type Common struct {
	Region      string // "" when unset
	ClusterName string
	Zones       []string // nil = provider default

	DeployNodes       bool
	ControlPlaneCount int
	// ControlPlaneInstanceType is "" when null (provider default).
	ControlPlaneInstanceType string
	ControlPlaneDiskGB       *float64 // nil = provider default
	ControlPlanePublicIP     bool

	JumphostInstanceType string   // "" = provider default
	JumphostDiskGB       *float64 // nil = provider default

	// ImageIDSet is true when image_id is set: an existing image is reused
	// and nothing is built. The id itself is never copied.
	ImageIDSet         bool
	KeepBuildArtifacts bool
	ImageDiskGB        float64 // from image_disk_size
	IngressController  string

	// Pools are in sorted key order, like locals.tf.
	GPUPools    []Pool
	WorkerPools []Pool
}

// Pool is one gpu_pools or worker_pools entry after optional() defaults.
type Pool struct {
	Name         string
	InstanceType string
	Count        int
	DiskGB       *float64
	Zone         *string
	PublicIP     bool
	Kind         string // "vm" or "bare_metal"
}

// diskSizePattern mirrors the image_disk_size validation in the module.
var diskSizePattern = regexp.MustCompile(`^([1-9][0-9]*)([KMGT])$`)

// ResolveCommon reads the common variables from v into a Common. Problems go
// to v.Diagnostics(). Region is not required here: providers may default it,
// and the caller checks the effective value.
func ResolveCommon(v *Vars) Common {
	var c Common
	for _, name := range []string{
		"cluster_name", "deploy_nodes", "control_plane_count", "control_plane_public_ip",
		"keep_build_artifacts", "image_disk_size", "ingress_controller",
	} {
		v.require(name)
	}

	c.Region = v.String("region")
	c.ClusterName = v.String("cluster_name")
	c.Zones = v.StringList("zones")
	c.DeployNodes = v.Bool("deploy_nodes")
	c.ControlPlaneCount = v.Int("control_plane_count")
	c.ControlPlaneInstanceType = v.String("control_plane_instance_type")
	c.ControlPlaneDiskGB = v.OptFloat("control_plane_disk_size_gb")
	c.ControlPlanePublicIP = v.Bool("control_plane_public_ip")
	c.JumphostInstanceType = v.String("jumphost_instance_type")
	c.JumphostDiskGB = v.OptFloat("jumphost_disk_size_gb")
	c.ImageIDSet = v.IsSet("image_id")
	c.KeepBuildArtifacts = v.Bool("keep_build_artifacts")
	c.IngressController = v.String("ingress_controller")

	gb, err := parseDiskSizeGB(v.String("image_disk_size"))
	if err != nil {
		v.addErr("image_disk_size must match <positive integer><K|M|G|T>")
		gb = 8
	}
	c.ImageDiskGB = gb

	c.GPUPools = v.pools("gpu_pools")
	c.WorkerPools = v.pools("worker_pools")
	return c
}

func (v *Vars) pools(name string) []Pool {
	val, ok := v.value(name)
	if !ok || val.IsNull() {
		return nil
	}
	pools, err := decodePools(val)
	if err != nil {
		v.addErr("%s: %s", name, err.Error())
	}
	return pools
}

// resolveValue is the one place the spec's "convert first would lose the
// default" trap is avoided: for every value, whether it came from an
// override, the tfvars, or the variable's own `default`, optional() defaults
// (decl.Defaults.Apply) are applied BEFORE convert.Convert -- never after.
// Converting a value missing an optional attribute produces null for that
// attribute (cty.ObjectWithOptionalAttrs allows exactly that), which leaves
// Apply nothing to fill if it runs second. See resolve.go's package comment
// and the plan this package implements.
func resolveValue(decls map[string]*VariableDecl, tfvars map[string]TFVarValue, overrides map[string]string, name string) (cty.Value, bool, []Diagnostic) {
	decl := decls[name]

	applyAndConvert := func(v cty.Value, subject *hcl.Range) (cty.Value, []Diagnostic) {
		if decl == nil {
			return v, nil
		}
		if decl.Defaults != nil {
			v = decl.Defaults.Apply(v)
		}
		converted, err := convert.Convert(v, decl.Type)
		if err != nil {
			return cty.NilVal, []Diagnostic{{
				Severity: SeverityError,
				Summary:  fmt.Sprintf("variable %q: value does not match expected type %s", name, typeexpr.TypeString(decl.Type)),
				Subject:  subject,
			}}
		}
		return converted, nil
	}

	if ov, ok := overrides[name]; ok {
		v, diags := applyAndConvert(cty.StringVal(ov), nil)
		if diags != nil {
			return cty.NilVal, false, diags
		}
		return v, true, nil
	}

	if tv, ok := tfvars[name]; ok {
		r := tv.Range
		v, diags := applyAndConvert(tv.Value, &r)
		if diags != nil {
			return cty.NilVal, false, diags
		}
		return v, true, nil
	}

	if decl != nil && decl.HasDefault {
		v, diags := applyAndConvert(decl.Default, nil)
		if diags != nil {
			return cty.NilVal, false, diags
		}
		return v, true, nil
	}

	return cty.NilVal, false, nil
}

// poolAttr reads one attribute off a pool object; absent or null is
// reported as not present.
func poolAttr(obj cty.Value, name string) (cty.Value, bool) {
	if !obj.Type().IsObjectType() && !obj.Type().IsMapType() {
		return cty.NilVal, false
	}
	if obj.Type().IsObjectType() && !obj.Type().HasAttribute(name) {
		return cty.NilVal, false
	}
	v := obj.GetAttr(name)
	if v.IsNull() {
		return cty.NilVal, false
	}
	return v, true
}

func decodePools(v cty.Value) ([]Pool, error) {
	m := v.AsValueMap()
	names := make([]string, 0, len(m))
	for name := range m {
		names = append(names, name)
	}
	sort.Strings(names) // locals.tf iterates sort(keys(...))

	pools := make([]Pool, 0, len(names))
	for _, name := range names {
		obj := m[name]
		p := Pool{Name: name}
		get := func(attr string, dst any, required bool) error {
			av, ok := poolAttr(obj, attr)
			if !ok {
				if required {
					return fmt.Errorf("pool %q: missing required attribute %q", name, attr)
				}
				return nil
			}
			if err := gocty.FromCtyValue(av, dst); err != nil {
				return fmt.Errorf("pool %q: attribute %q has the wrong type", name, attr)
			}
			return nil
		}
		var disk float64
		var zone string
		for _, step := range []func() error{
			func() error { return get("instance_type", &p.InstanceType, true) },
			func() error { return get("count", &p.Count, false) },
			func() error { return get("public_ip", &p.PublicIP, false) },
			func() error { return get("kind", &p.Kind, false) },
			func() error { return get("disk_size_gb", &disk, false) },
			func() error { return get("zone", &zone, false) },
		} {
			if err := step(); err != nil {
				return nil, err
			}
		}
		if _, ok := poolAttr(obj, "disk_size_gb"); ok {
			p.DiskGB = &disk
		}
		if _, ok := poolAttr(obj, "zone"); ok {
			p.Zone = &zone
		}
		pools = append(pools, p)
	}
	return pools, nil
}

// parseDiskSizeGB converts variables.tf:616's image_disk_size (e.g. "8G",
// "35G") to decimal gigabytes, matching variables.tf:625's own validation
// regex. K/M/G/T are read as decimal (1000-based) scale factors, consistent
// with how Vultr itself quotes plan disk sizes.
func parseDiskSizeGB(s string) (float64, error) {
	m := diskSizePattern.FindStringSubmatch(s)
	if m == nil {
		return 0, fmt.Errorf("invalid size")
	}
	n, err := strconv.ParseFloat(m[1], 64)
	if err != nil {
		return 0, err
	}
	switch m[2] {
	case "K":
		return n / 1e6, nil
	case "M":
		return n / 1e3, nil
	case "G":
		return n, nil
	case "T":
		return n * 1e3, nil
	}
	return 0, fmt.Errorf("invalid size")
}
