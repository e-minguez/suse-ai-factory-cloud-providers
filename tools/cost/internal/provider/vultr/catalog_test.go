package vultr

import (
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

func TestToCatalog(t *testing.T) {
	plans, err := LoadPlansFile("testdata/plans.json")
	if err != nil {
		t.Fatal(err)
	}
	cat := plans.ToCatalog("ams", pricing.CatalogInfo{Source: "file"})
	if cat.Currency() != "USD" {
		t.Errorf("Currency = %q", cat.Currency())
	}

	monthly, _ := cat.Lookup("vc2-6c-16gb")
	if monthly.MonthlyCap != 80_000_000 || monthly.MinHours != 1 {
		t.Errorf("monthly-invoiced plan: %+v", monthly)
	}
	// vx1 plans publish a monthly_cost but invoice hourly: no cap.
	hourly, _ := cat.Lookup("vx1-g-4c-16g-240s")
	if hourly.MonthlyCap != 0 || hourly.Hourly != 153_000 {
		t.Errorf("hourly-invoiced plan: %+v", hourly)
	}
	for id, wantHourly := range map[string]pricing.Micros{"lb": 15_000, "nat-gateway": 30_000} {
		p, ok := cat.Lookup(id)
		if !ok || p.Hourly != wantHourly || p.MonthlyCap == 0 {
			t.Errorf("synthetic %s: %+v, %v", id, p, ok)
		}
	}
	if p, ok := cat.Lookup("storage:snapshot"); !ok || p.GBMonthly != 50_000 {
		t.Errorf("snapshot plan: %+v, %v", p, ok)
	}
}

// TestToCatalogRegionOverride: location_cost replaces both rates in its region.
func TestToCatalogRegionOverride(t *testing.T) {
	plans, err := LoadPlansFile("testdata/plans.json")
	if err != nil {
		t.Fatal(err)
	}
	ams, _ := plans.ToCatalog("ams", pricing.CatalogInfo{}).Lookup("vc2-1c-1gb")
	sao, _ := plans.ToCatalog("sao", pricing.CatalogInfo{}).Lookup("vc2-1c-1gb")
	if ams.Hourly != 7_000 || sao.Hourly != 10_000 || sao.MonthlyCap != 7_500_000 {
		t.Errorf("ams %+v, sao %+v", ams, sao)
	}
}
