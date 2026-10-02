package pricing

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestChargeMinHours(t *testing.T) {
	p := Plan{Hourly: 100_000, MinHours: 1}
	if got, capped := Charge(p, 0.25); got != 100_000 || capped {
		t.Errorf("Charge(0.25h) = %d, %v; want one full hour, uncapped", got, capped)
	}
	p.MinHours = 1.0 / 60 // per-second billing with a one minute minimum
	if got, _ := Charge(p, 0.5); got != 50_000 {
		t.Errorf("Charge(0.5h) with a 1 minute minimum = %d, want 50000", got)
	}
	p.MinHours = 0
	if got, _ := Charge(p, 0.5); got != 50_000 {
		t.Errorf("Charge(0.5h) without a minimum = %d, want 50000", got)
	}
}

func TestChargeMonthlyCap(t *testing.T) {
	tests := []struct {
		name       string
		p          Plan
		hours      float64
		want       Micros
		wantCapped bool
	}{
		{"below cap", Plan{Hourly: 110_000, MonthlyCap: 80_000_000}, 720, 79_200_000, false},
		{"above cap", Plan{Hourly: 15_000, MonthlyCap: 10_000_000}, 720, 10_000_000, true},
		{"no cap is never capped", Plan{Hourly: 153_000}, 720, 110_160_000, false},
		{"two months plus remainder", Plan{Hourly: 110_000, MonthlyCap: 80_000_000}, 730*2 + 100, 2*80_000_000 + 11_000_000, true},
		{"remainder capped", Plan{Hourly: 110_000, MonthlyCap: 80_000_000}, 730 + 729, 2 * 80_000_000, true},
	}
	for _, tt := range tests {
		got, capped := Charge(tt.p, tt.hours)
		if got != tt.want || capped != tt.wantCapped {
			t.Errorf("%s: Charge = %d, %v; want %d, %v", tt.name, got, capped, tt.want, tt.wantCapped)
		}
	}
}

func TestChargeStorage(t *testing.T) {
	month := Plan{GBMonthly: 50_000}
	if got := ChargeStorage(month, 8, HoursPerMonth); got != 400_000 {
		t.Errorf("8 GB for a month at 0.05/GB-month = %d, want 400000", got)
	}
	hour := Plan{Hourly: 137}
	if got := ChargeStorage(hour, 100, 10); got != 137_000 {
		t.Errorf("100 GB for 10h at 137/GB-hour = %d, want 137000", got)
	}
}

func testCatalog() StaticCatalog {
	return StaticCatalog{Cur: "EUR", Meta: CatalogInfo{Source: "file"}, Plans: map[string]Plan{
		"vm":               {ID: "vm", Hourly: 100_000, MonthlyCap: 60_000_000, MinHours: 1},
		"lb":               {ID: "lb", Hourly: 10_000},
		"storage:snapshot": {ID: "storage:snapshot", GBMonthly: 73_000},
	}}
}

var testDurations = []Duration{{"1h", 1}, {"24h", 24}}

func TestPriceTotalsBuildOnlyAndSurvives(t *testing.T) {
	resources := []Resource{
		{Kind: KindCompute, Label: "vm", RateID: "vm", Qty: 2},
		{Kind: KindFixed, Label: "lb", RateID: "lb", Qty: 1},
		{Kind: KindCompute, Label: "builder", RateID: "vm", Qty: 1, BuildOnly: true},
		{Kind: KindStorage, Label: "snap", RateID: "storage:snapshot", Qty: 1, SizeGB: 10, SurvivesDestroy: true},
		{Kind: KindFree, Label: "vpc", Qty: 1},
	}
	res, err := Price(resources, testCatalog(), testDurations, false)
	if err != nil {
		t.Fatal(err)
	}
	if res.Currency != "EUR" {
		t.Errorf("Currency = %q", res.Currency)
	}
	// 2 vm x 0.10 + lb 0.01 + snapshot 10 GB x 0.073/730 = 0.001 per hour.
	if got := res.Totals["1h"]; got != 211_000 {
		t.Errorf("1h total = %d, want 211000", got)
	}
	if got := res.BuildOnlyTotals["1h"]; got != 100_000 {
		t.Errorf("1h build-only = %d, want 100000 (not in the total)", got)
	}
	if !res.HasBuildOnly {
		t.Error("HasBuildOnly = false")
	}
	if res.RecurringAfterDestroy != 730_000 {
		t.Errorf("RecurringAfterDestroy = %d, want 730000", res.RecurringAfterDestroy)
	}
	vm := res.Items[0]
	if vm.Capped["24h"] {
		t.Error("24h at 0.10/h = 2.40 must not hit the 60 cap")
	}
}

func TestPriceUnknownRate(t *testing.T) {
	resources := []Resource{{Kind: KindCompute, Label: "x", RateID: "nope", Qty: 1}}
	if _, err := Price(resources, testCatalog(), testDurations, false); err == nil || !strings.Contains(err.Error(), `"nope"`) {
		t.Fatalf("want an error naming the rate, got %v", err)
	}
	res, err := Price(resources, testCatalog(), testDurations, true)
	if err != nil || !res.Incomplete || len(res.AllWarnings()) != 1 {
		t.Errorf("--allow-unknown-plans: err=%v incomplete=%v warnings=%v", err, res.Incomplete, res.AllWarnings())
	}
	// Qty 0 never fails.
	zero := []Resource{{Kind: KindCompute, Label: "x", RateID: "nope", Qty: 0}}
	if res, err := Price(zero, testCatalog(), testDurations, false); err != nil || res.Incomplete {
		t.Errorf("qty 0: err=%v incomplete=%v", err, res.Incomplete)
	}
}

func TestParseMicrosExact(t *testing.T) {
	for in, want := range map[string]Micros{"0": 0, "0.153": 153_000, "0.1": 100_000, "111.69": 111_690_000, "0.000137": 137} {
		got, err := ParseMicros(jsonNumber(in))
		if err != nil || got != want {
			t.Errorf("ParseMicros(%q) = %d, %v; want %d", in, got, err, want)
		}
	}
}

func TestParseDurations(t *testing.T) {
	got, err := ParseDurations("1h, 7d")
	if err != nil || len(got) != 2 || got[1].Hours != 168 {
		t.Errorf("ParseDurations = %v, %v", got, err)
	}
	for _, bad := range []string{"", "5m", "0h", "xh"} {
		if _, err := ParseDurations(bad); err == nil {
			t.Errorf("ParseDurations(%q) should fail", bad)
		}
	}
}

func jsonNumber(s string) json.Number { return json.Number(s) }
