package gcp

import (
	"regexp"
	"strconv"
)

// machine is what a machine type name stands for: its vCPUs, memory and the
// built-in GPUs (G2, G4, A2, A3), which are billed as separate SKUs.
type machine struct {
	family string
	vcpu   int
	ramGB  float64
	gpus   int
	gpu    string // key of gpuStems; "" without a GPU
}

// Families billed as vCPU + GB of RAM (no built-in GPU) and their GB of RAM
// per vCPU for the standard, highmem and highcpu shapes. A missing shape
// does not exist for the family.
var ramPerVCPU = map[string]map[string]float64{
	"e2":  {"standard": 4, "highmem": 8, "highcpu": 1},
	"n1":  {"standard": 3.75, "highmem": 6.5, "highcpu": 0.9},
	"n2":  {"standard": 4, "highmem": 8, "highcpu": 1},
	"n2d": {"standard": 4, "highmem": 8, "highcpu": 1},
	"n4":  {"standard": 4, "highmem": 8, "highcpu": 2},
	"c2":  {"standard": 4},
	"c2d": {"standard": 4, "highmem": 8, "highcpu": 2},
	"c3":  {"standard": 4, "highmem": 8, "highcpu": 2},
	"c3d": {"standard": 4, "highmem": 8, "highcpu": 2},
	"c4":  {"standard": 3.75, "highmem": 7.75, "highcpu": 1.875},
}

var generalType = regexp.MustCompile(`^([a-z0-9]+)-(standard|highmem|highcpu)-([1-9][0-9]*)$`)

// Fixed-size GPU machine types: vCPU, GB of RAM, GPU count.
type fixedGPU struct {
	vcpu  int
	ramGB float64
	gpus  int
	gpu   string
}

var gpuMachines = map[string]fixedGPU{
	"g2-standard-4":  {4, 16, 1, "l4"},
	"g2-standard-8":  {8, 32, 1, "l4"},
	"g2-standard-12": {12, 48, 1, "l4"},
	"g2-standard-16": {16, 64, 1, "l4"},
	"g2-standard-24": {24, 96, 2, "l4"},
	"g2-standard-32": {32, 128, 1, "l4"},
	"g2-standard-48": {48, 192, 4, "l4"},
	"g2-standard-96": {96, 384, 8, "l4"},

	// Full-GPU G4 sizes; the fractional ones are rejected by the module.
	"g4-standard-48":  {48, 180, 1, "rtx-pro-6000"},
	"g4-standard-96":  {96, 360, 2, "rtx-pro-6000"},
	"g4-standard-192": {192, 720, 4, "rtx-pro-6000"},
	"g4-standard-384": {384, 1440, 8, "rtx-pro-6000"},

	"a2-highgpu-1g":  {12, 85, 1, "a100-40"},
	"a2-highgpu-2g":  {24, 170, 2, "a100-40"},
	"a2-highgpu-4g":  {48, 340, 4, "a100-40"},
	"a2-highgpu-8g":  {96, 680, 8, "a100-40"},
	"a2-megagpu-16g": {96, 1360, 16, "a100-40"},
	"a2-ultragpu-1g": {12, 170, 1, "a100-80"},
	"a2-ultragpu-2g": {24, 340, 2, "a100-80"},
	"a2-ultragpu-4g": {48, 680, 4, "a100-80"},
	"a2-ultragpu-8g": {96, 1360, 8, "a100-80"},

	"a3-highgpu-1g":  {26, 234, 1, "h100-80"},
	"a3-highgpu-2g":  {52, 468, 2, "h100-80"},
	"a3-highgpu-4g":  {104, 936, 4, "h100-80"},
	"a3-highgpu-8g":  {208, 1872, 8, "h100-80"},
	"a3-megagpu-8g":  {208, 1872, 8, "h100-80"},
	"a3-ultragpu-8g": {224, 2952, 8, "h200-141"},
}

// parseMachine resolves a machine type name; ok is false for a type outside
// the tables (shared-core, custom, local SSD variants, other GPU families).
func parseMachine(name string) (machine, bool) {
	if g, ok := gpuMachines[name]; ok {
		return machine{family: familyOf(name), vcpu: g.vcpu, ramGB: g.ramGB, gpus: g.gpus, gpu: g.gpu}, true
	}
	m := generalType.FindStringSubmatch(name)
	if m == nil {
		return machine{}, false
	}
	ratio, ok := ramPerVCPU[m[1]][m[2]]
	if !ok {
		return machine{}, false
	}
	n, _ := strconv.Atoi(m[3])
	return machine{family: m[1], vcpu: n, ramGB: float64(n) * ratio}, true
}

func familyOf(name string) string {
	for i := 0; i < len(name); i++ {
		if name[i] == '-' {
			return name[:i]
		}
	}
	return name
}

// hyperdiskFamilies mirrors `hyperdisk_families` in modules/gcp/locals.tf:
// the families whose boot disk is hyperdisk-balanced.
var hyperdiskFamilies = map[string]bool{
	"c3": true, "c3d": true, "c4": true, "c4a": true, "c4d": true, "n4": true,
	"g4": true, "a3": true, "a4": true, "a4x": true,
}

// defaultDiskType is the boot disk type of a machine type without an override.
func defaultDiskType(machineType string) string {
	if hyperdiskFamilies[familyOf(machineType)] {
		return "hyperdisk-balanced"
	}
	return "pd-balanced"
}
