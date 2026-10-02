package vultr

import "github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"

// MapCatalog is the decoded API catalog, keyed by plan ID.
type MapCatalog map[string]Plan

// Merge returns a new MapCatalog with other's entries winning on collisions.
func (c MapCatalog) Merge(other MapCatalog) MapCatalog {
	out := make(MapCatalog, len(c)+len(other))
	for id, p := range c {
		out[id] = p
	}
	for id, p := range other {
		out[id] = p
	}
	return out
}

// Synthetic rate IDs for resources the plans API does not list.
const (
	rateLB       = "lb"
	rateNAT      = "nat-gateway"
	rateSnapshot = "storage:snapshot"
)

// Published rates of the resources the plans API does not list.
// Sources: https://www.vultr.com/pricing/ (load balancers, NAT gateways) and
// https://docs.vultr.com/vultr-snapshots-overview (snapshots). Load balancers
// bill 0.015 per node-hour capped at 10 per node-month; NAT gateways 0.03 per
// hour capped at 20 per month; snapshots 0.05 per GB-month with no cap.
var syntheticPlans = []pricing.Plan{
	{ID: rateLB, Hourly: 15_000, MonthlyCap: 10_000_000, MinHours: 1},
	{ID: rateNAT, Hourly: 30_000, MonthlyCap: 20_000_000, MinHours: 1},
	{ID: rateSnapshot, GBMonthly: 50_000},
}

// ToCatalog converts the API plans to a pricing.Catalog for region, applying
// the region's location_cost override (a full replacement of both rates) and
// adding the synthetic LB, NAT and snapshot plans.
//
// Only plans with invoice_type "monthly" carry a monthly cap; "hourly" plans
// (for example vx1-g-4c-16g-240s) bill hourly without one even though they
// publish a monthly_cost, so the cap is never inferred from the plan ID.
// Every plan has a one hour minimum.
func (c MapCatalog) ToCatalog(region string, info pricing.CatalogInfo) pricing.StaticCatalog {
	plans := make(map[string]pricing.Plan, len(c)+len(syntheticPlans))
	for id, p := range c {
		hourly, monthly, _ := p.RateFor(region)
		pp := pricing.Plan{ID: id, Hourly: pricing.Micros(hourly), MinHours: 1}
		if p.InvoiceType == "monthly" {
			pp.MonthlyCap = pricing.Micros(monthly)
		}
		plans[id] = pp
	}
	for _, p := range syntheticPlans {
		plans[p.ID] = p
	}
	return pricing.StaticCatalog{Cur: "USD", Meta: info, Plans: plans}
}

// Lookup returns the API plan with the given ID.
func (c MapCatalog) Lookup(id string) (Plan, bool) {
	p, ok := c[id]
	return p, ok
}
