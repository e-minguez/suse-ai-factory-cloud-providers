package vultr

import (
	"encoding/json"
	"testing"
)

// TestCatalogSchema asserts that loading the trimmed testdata/plans.json
// fixture did not drop location_cost during the trim -- a curated fixture is
// only useful for TestLoadsRegionalOverride below if it still carries at
// least one plan with a real per-region override.
func TestCatalogSchema(t *testing.T) {
	catalog, err := LoadPlansFile("testdata/plans.json")
	if err != nil {
		t.Fatalf("LoadPlansFile: %v", err)
	}

	p, ok := catalog.Lookup("vc2-1c-1gb")
	if !ok {
		t.Fatal("fixture missing vc2-1c-1gb")
	}
	if len(p.LocationCost) == 0 {
		t.Error("vc2-1c-1gb should carry a location_cost override in the fixture; the trim dropped it")
	}
	if _, ok := p.LocationCost["sao"]; !ok {
		t.Errorf("vc2-1c-1gb should have a \"sao\" location_cost entry, got %+v", p.LocationCost)
	}

	// Bare metal plans carry no location_cost key at all in the live API --
	// confirmed 2026-09 against GET /v2/plans-metal -- so the fixture must
	// not invent one.
	metal, ok := catalog.Lookup("vbm-6c-32gb-amd")
	if !ok {
		t.Fatal("fixture missing vbm-6c-32gb-amd")
	}
	if len(metal.LocationCost) != 0 {
		t.Errorf("vbm-6c-32gb-amd should have no location_cost, got %+v", metal.LocationCost)
	}
}

// TestHourlyMetalPlan asserts the fixture's one hourly-invoiced bare metal
// plan decodes with the right InvoiceType -- pricing.Charge's cap logic
// hinges entirely on this field, not on the vbm- prefix.
func TestHourlyMetalPlan(t *testing.T) {
	catalog, err := LoadPlansFile("testdata/plans.json")
	if err != nil {
		t.Fatalf("LoadPlansFile: %v", err)
	}
	p, ok := catalog.Lookup("vbm-72c-480gb-gh200-gpu")
	if !ok {
		t.Fatal("fixture missing vbm-72c-480gb-gh200-gpu")
	}
	if p.InvoiceType != "hourly" {
		t.Errorf("InvoiceType = %q, want \"hourly\"", p.InvoiceType)
	}
}

// TestParseMicrosExact asserts money is parsed exactly, not through a
// binary-float approximation: 0.153 must become precisely 153000, and a
// value already known to be an awkward binary fraction (0.1) must round
// exactly too.
func TestParseMicrosExact(t *testing.T) {
	cases := []struct {
		in   string
		want int64
	}{
		{"0", 0},
		{"0.153", 153_000},
		{"0.1", 100_000},
		{"111.69", 111_690_000},
		{"80", 80_000_000},
		{"0.007", 7_000},
	}
	for _, c := range cases {
		got, err := parseMicros(json.Number(c.in))
		if err != nil {
			t.Errorf("parseMicros(%q): %v", c.in, err)
			continue
		}
		if got != c.want {
			t.Errorf("parseMicros(%q) = %d, want %d", c.in, got, c.want)
		}
	}
}
