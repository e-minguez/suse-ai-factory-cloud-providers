package render

import (
	"bytes"
	"flag"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"github.com/google/go-cmp/cmp"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

var update = flag.Bool("update", false, "write golden files instead of comparing against them")

// fixtureReport covers every report feature: pools, a capped rate, a
// build-only resource, a survives-destroy resource, a free row, an excluded
// cost and a non-USD currency.
func fixtureReport(t *testing.T) Report {
	t.Helper()
	cat := pricing.StaticCatalog{Cur: "EUR", Meta: pricing.CatalogInfo{Source: "ratecard", AsOf: "2026-09-11"}, Plans: map[string]pricing.Plan{
		"c1a.m":            {ID: "c1a.m", Hourly: 206_000, MinHours: 1.0 / 60},
		"gn-l40s.s":        {ID: "gn-l40s.s", Hourly: 1_500_000, MinHours: 1.0 / 60},
		"lb":               {ID: "lb", Hourly: 15_000, MonthlyCap: 10_000_000},
		"storage:disk":     {ID: "storage:disk", Hourly: 137},
		"storage:snapshot": {ID: "storage:snapshot", GBMonthly: 50_000},
	}}
	resources := []pricing.Resource{
		{Kind: pricing.KindCompute, Label: "control plane", Role: "control_plane", Pool: "cp", RateID: "c1a.m", Qty: 3},
		{Kind: pricing.KindCompute, Label: "gpu node", Role: "gpu", Pool: "gpu", RateID: "gn-l40s.s", Qty: 1},
		{Kind: pricing.KindCompute, Label: "worker node", Role: "worker", Pool: "w", RateID: "c1a.m", Qty: 0},
		{Kind: pricing.KindFixed, Label: "load balancer", Role: "lb", RateID: "lb", Qty: 1},
		{Kind: pricing.KindStorage, Label: "node disk", Role: "control_plane", Pool: "cp", RateID: "storage:disk", Qty: 3, SizeGB: 100},
		{Kind: pricing.KindCompute, Label: "builder", Role: "builder", RateID: "c1a.m", Qty: 1, BuildOnly: true},
		{Kind: pricing.KindStorage, Label: "image snapshot", Role: "image", RateID: "storage:snapshot", Qty: 1, SizeGB: 8, SurvivesDestroy: true},
		{Kind: pricing.KindFree, Label: "vpc", Role: "network", Qty: 1},
	}
	durations, err := pricing.ParseDurations("1h,24h,30d")
	if err != nil {
		t.Fatal(err)
	}
	res, err := pricing.Price(resources, cat, durations, false)
	if err != nil {
		t.Fatal(err)
	}
	res.Excluded = []pricing.Excluded{{Label: "outbound transfer", Reason: "traffic-dependent"}}
	res.Warnings = []string{"tfvars sets \"x\", which is not declared in the module's variables"}
	return Report{Provider: "evroc", Region: "se-sto", Cluster: "demo", Result: res, Durations: durations}
}

func compareGolden(t *testing.T, path string, got []byte) {
	t.Helper()
	if *update {
		if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(path, got, 0o644); err != nil {
			t.Fatal(err)
		}
		return
	}
	want, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("reading %s: %v (run `go test ./... -update` to create it)", path, err)
	}
	if diff := cmp.Diff(string(want), string(got)); diff != "" {
		t.Errorf("%s mismatch (-want +got):\n%s", path, diff)
	}
}

func TestTextGolden(t *testing.T) {
	var buf bytes.Buffer
	if err := Text(&buf, fixtureReport(t)); err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if lines[0] != pricing.Disclaimer || lines[len(lines)-1] != pricing.Disclaimer {
		t.Error("the disclaimer must be the first and last line")
	}
	compareGolden(t, "testdata/golden/text.txt", buf.Bytes())
}

func TestJSONGolden(t *testing.T) {
	var buf bytes.Buffer
	if err := JSON(&buf, fixtureReport(t)); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(buf.String(), `"disclaimer": "`+pricing.Disclaimer+`"`) {
		t.Error("JSON must carry the disclaimer field")
	}
	compareGolden(t, "testdata/golden/report.json", buf.Bytes())
}
