package pricing

import (
	"fmt"
	"math"
	"strings"
)

// Charge returns the cost of hours on plan p for one unit, and whether
// MonthlyCap bound. Hours are raised to MinHours. With a cap, the duration
// splits into whole 730 h months (each at the cap) plus a remainder that is
// itself capped at the same monthly figure.
func Charge(p Plan, hours float64) (Micros, bool) {
	h := math.Max(p.MinHours, hours)
	raw := Micros(math.Round(float64(p.Hourly) * h))
	if p.MonthlyCap == 0 {
		return raw, false
	}
	months := math.Floor(h / HoursPerMonth)
	rem := h - months*HoursPerMonth
	total := Micros(months)*p.MonthlyCap +
		min(Micros(math.Round(float64(p.Hourly)*rem)), p.MonthlyCap)
	return total, total < raw
}

// ChargeStorage returns the cost of keeping sizeGB for hours, per unit.
// Storage has no cap; MinHours still applies.
func ChargeStorage(p Plan, sizeGB, hours float64) Micros {
	h := math.Max(p.MinHours, hours)
	perHour := float64(p.Hourly) + float64(p.GBMonthly)/HoursPerMonth
	return Micros(math.Round(perHour * sizeGB * h))
}

// LineItem is one priced Resource. Hourly is per unit (Qty is applied only
// to Costs), so the rate column always reads as a per-instance figure.
type LineItem struct {
	Resource Resource
	Found    bool              // rate present in the catalog (always true for KindFree)
	Hourly   Micros            // per unit; for KindStorage per GB-hour, derived from GBMonthly if needed
	Costs    map[string]Micros // keyed by Duration.Label, Qty-multiplied
	Capped   map[string]bool
	Warnings []string
}

// Result is the full priced report.
type Result struct {
	Currency string
	Catalog  CatalogInfo
	Items    []LineItem

	// Totals is the steady-state total per duration label; BuildOnlyTotals
	// the cost of BuildOnly resources over the same durations, not included
	// in Totals.
	Totals          map[string]Micros
	BuildOnlyTotals map[string]Micros
	HasBuildOnly    bool

	// RecurringAfterDestroy is the monthly cost of SurvivesDestroy resources.
	RecurringAfterDestroy Micros

	// Excluded lists costs left out; the caller fills it from the provider's
	// Expand.
	Excluded []Excluded

	// Incomplete is set when --allow-unknown-plans priced a missing rate as
	// zero; the totals are then a floor.
	Incomplete bool
	Warnings   []string
	// Notes are informational lines for the report footer, not warnings.
	Notes []string
}

// AllWarnings flattens result-level and per-item warnings in row order.
func (r Result) AllWarnings() []string {
	out := append([]string(nil), r.Warnings...)
	for _, item := range r.Items {
		out = append(out, item.Warnings...)
	}
	return out
}

// Price bills every resource against cat for each duration. The error is
// non-nil only when a RateID is missing from the catalog at Qty >= 1 and
// allowUnknown is false; the partial Result is still returned.
func Price(resources []Resource, cat Catalog, durations []Duration, allowUnknown bool) (Result, error) {
	res := Result{
		Currency:        cat.Currency(),
		Catalog:         cat.Info(),
		Totals:          map[string]Micros{},
		BuildOnlyTotals: map[string]Micros{},
	}
	for _, d := range durations {
		res.Totals[d.Label] = 0
		res.BuildOnlyTotals[d.Label] = 0
	}

	var fatal []string
	for _, r := range resources {
		item := LineItem{Resource: r, Found: true, Costs: map[string]Micros{}, Capped: map[string]bool{}}
		qty := Micros(r.Qty)

		if r.Kind != KindFree {
			p, found := cat.Lookup(r.RateID)
			item.Found = found
			switch {
			case !found && r.Qty >= 1 && allowUnknown:
				item.Warnings = append(item.Warnings, fmt.Sprintf("rate %q not found in catalog; priced as 0 because --allow-unknown-plans was set", r.RateID))
				res.Incomplete = true
			case !found && r.Qty >= 1:
				fatal = append(fatal, fmt.Sprintf("%s: rate %q not found in catalog", r.Label, r.RateID))
			case !found:
				item.Warnings = append(item.Warnings, fmt.Sprintf("rate %q not found in catalog (qty 0, informational only)", r.RateID))
			default:
				item.Hourly = p.Hourly
				if r.Kind == KindStorage && p.Hourly == 0 {
					item.Hourly = Micros(math.Round(float64(p.GBMonthly) / HoursPerMonth))
				}
				for _, d := range durations {
					if r.Kind == KindStorage {
						item.Costs[d.Label] = ChargeStorage(p, r.SizeGB, d.Hours) * qty
					} else {
						c, capped := Charge(p, d.Hours)
						item.Costs[d.Label] = c * qty
						item.Capped[d.Label] = capped
					}
				}
				if r.SurvivesDestroy {
					if r.Kind == KindStorage {
						res.RecurringAfterDestroy += ChargeStorage(p, r.SizeGB, HoursPerMonth) * qty
					} else {
						c, _ := Charge(p, HoursPerMonth)
						res.RecurringAfterDestroy += c * qty
					}
				}
			}
		}

		for _, d := range durations {
			c := item.Costs[d.Label] // zero when missing or free
			item.Costs[d.Label] = c
			if r.BuildOnly {
				res.BuildOnlyTotals[d.Label] += c
			} else {
				res.Totals[d.Label] += c
			}
		}
		if r.BuildOnly {
			res.HasBuildOnly = true
		}
		res.Items = append(res.Items, item)
	}

	if len(fatal) > 0 {
		return res, fmt.Errorf("rate(s) not found in catalog, refusing to price them as 0 (pass --allow-unknown-plans to override):\n  %s", strings.Join(fatal, "\n  "))
	}
	return res, nil
}
