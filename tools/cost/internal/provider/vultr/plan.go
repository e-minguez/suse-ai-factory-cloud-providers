// Package vultr is the Vultr cost provider: it decodes the public plan catalog
// (GET /v2/plans, /v2/plans-metal; no API key), expands a deployment into
// resources and prices them.
package vultr

import (
	"encoding/json"
	"fmt"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

// Plan is one entry from GET /v2/plans or /v2/plans-metal, trimmed to what
// pricing needs. HourlyMicros/MonthlyMicros are hourly_cost/monthly_cost
// verbatim -- never one derived from the other. Measured across the live
// catalog, monthly_cost/hourly_cost ranges from 664 to 1363 depending on the
// plan (vc2-6c-16gb is 727.3, vbm-24c-384gb-amd5 is 1363), so treating either
// figure as authoritative for the other silently mis-prices a plan.
type Plan struct {
	ID          string `json:"id"`
	InvoiceType string `json:"invoice_type"` // "monthly" or "hourly" -- the monthly-cap discriminator; see ToCatalog

	HourlyMicros  int64 `json:"hourly_micros"`  // dollars * 1_000_000, from hourly_cost
	MonthlyMicros int64 `json:"monthly_micros"` // dollars * 1_000_000, from monthly_cost

	Locations []string `json:"locations"`

	// LocationCost holds a per-region override of both Hourly/MonthlyMicros,
	// keyed by region ID (e.g. "sao"). Present on roughly a third of live
	// cloud plans as of 2026-09, absent (nil) on every bare metal plan --
	// the API's /v2/plans-metal responses carry no location_cost key at all.
	// See the README's Known limits.
	LocationCost map[string]LocationCost `json:"location_cost,omitempty"`
}

// LocationCost is one region's override of a Plan's hourly/monthly cost.
// Vultr's API documents this as a full replacement of both figures, not a
// delta on top of the base rate.
type LocationCost struct {
	HourlyMicros  int64 `json:"hourly_micros"`
	MonthlyMicros int64 `json:"monthly_micros"`
}

// RateFor returns the plan's hourly/monthly cost, replaced by region's
// LocationCost override when one exists.
func (p Plan) RateFor(region string) (hourlyMicros, monthlyMicros int64, regional bool) {
	if lc, ok := p.LocationCost[region]; ok {
		return lc.HourlyMicros, lc.MonthlyMicros, true
	}
	return p.HourlyMicros, p.MonthlyMicros, false
}

// --- raw API JSON decoding -------------------------------------------------

type rawLocationCost struct {
	HourlyCost  json.Number `json:"hourly_cost"`
	MonthlyCost json.Number `json:"monthly_cost"`
}

type rawPlan struct {
	ID           string                     `json:"id"`
	InvoiceType  string                     `json:"invoice_type"`
	HourlyCost   json.Number                `json:"hourly_cost"`
	MonthlyCost  json.Number                `json:"monthly_cost"`
	Locations    []string                   `json:"locations"`
	LocationCost map[string]rawLocationCost `json:"location_cost"`
}

func (r rawPlan) toPlan() (Plan, error) {
	hourly, err := parseMicros(r.HourlyCost)
	if err != nil {
		return Plan{}, fmt.Errorf("plan %s: hourly_cost: %w", r.ID, err)
	}
	monthly, err := parseMicros(r.MonthlyCost)
	if err != nil {
		return Plan{}, fmt.Errorf("plan %s: monthly_cost: %w", r.ID, err)
	}

	var lc map[string]LocationCost
	if len(r.LocationCost) > 0 {
		lc = make(map[string]LocationCost, len(r.LocationCost))
		for region, v := range r.LocationCost {
			h, err := parseMicros(v.HourlyCost)
			if err != nil {
				return Plan{}, fmt.Errorf("plan %s: location_cost[%s].hourly_cost: %w", r.ID, region, err)
			}
			m, err := parseMicros(v.MonthlyCost)
			if err != nil {
				return Plan{}, fmt.Errorf("plan %s: location_cost[%s].monthly_cost: %w", r.ID, region, err)
			}
			lc[region] = LocationCost{HourlyMicros: h, MonthlyMicros: m}
		}
	}

	return Plan{
		ID:            r.ID,
		InvoiceType:   r.InvoiceType,
		HourlyMicros:  hourly,
		MonthlyMicros: monthly,
		Locations:     r.Locations,
		LocationCost:  lc,
	}, nil
}

// parseMicros converts a JSON number to millionths exactly (see
// pricing.ParseMicros).
func parseMicros(n json.Number) (int64, error) {
	m, err := pricing.ParseMicros(n)
	return int64(m), err
}
