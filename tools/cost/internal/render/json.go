package render

import (
	"encoding/json"
	"io"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

type jsonCatalog struct {
	Source string `json:"source"`
	AsOf   string `json:"as_of,omitempty"`
	Age    string `json:"age,omitempty"`
}

type jsonResource struct {
	Resource        string             `json:"resource"`
	Kind            string             `json:"kind"`
	Role            string             `json:"role,omitempty"`
	Pool            string             `json:"pool,omitempty"`
	RateID          string             `json:"rate_id,omitempty"`
	Qty             int                `json:"qty"`
	SizeGB          float64            `json:"size_gb,omitempty"`
	RateFound       bool               `json:"rate_found"`
	Hourly          float64            `json:"hourly"`
	BuildOnly       bool               `json:"build_only"`
	SurvivesDestroy bool               `json:"survives_destroy"`
	Costs           map[string]float64 `json:"costs"`
	Capped          map[string]bool    `json:"capped"`
	Warnings        []string           `json:"warnings,omitempty"`
}

type jsonExcluded struct {
	Resource string `json:"resource"`
	Reason   string `json:"reason"`
}

type jsonReport struct {
	Disclaimer      string             `json:"disclaimer"`
	Provider        string             `json:"provider"`
	Region          string             `json:"region"`
	ClusterName     string             `json:"cluster_name"`
	Currency        string             `json:"currency"`
	Catalog         jsonCatalog        `json:"catalog"`
	Durations       []string           `json:"durations"`
	Resources       []jsonResource     `json:"resources"`
	Totals          map[string]float64 `json:"totals"`
	BuildOnlyTotals map[string]float64 `json:"build_only_totals"`
	// RecurringAfterDestroyPerMonth is what keeps billing after `terraform
	// destroy`.
	RecurringAfterDestroyPerMonth float64        `json:"recurring_after_destroy_per_month"`
	Excluded                      []jsonExcluded `json:"excluded"`
	Incomplete                    bool           `json:"incomplete"`
	Warnings                      []string       `json:"warnings"`
	Notes                         []string       `json:"notes"`
}

// JSON renders r as one self-contained JSON object. Every warning also goes
// to stderr, so the document stands alone.
func JSON(w io.Writer, r Report) error {
	res := r.Result
	report := jsonReport{
		Disclaimer:                    pricing.Disclaimer,
		Provider:                      r.Provider,
		Region:                        r.Region,
		ClusterName:                   r.Cluster,
		Currency:                      res.Currency,
		Catalog:                       jsonCatalog{Source: res.Catalog.Source, AsOf: res.Catalog.AsOf, Age: res.Catalog.Age},
		Durations:                     []string{},
		Resources:                     []jsonResource{},
		Totals:                        map[string]float64{},
		BuildOnlyTotals:               map[string]float64{},
		RecurringAfterDestroyPerMonth: res.RecurringAfterDestroy.Major(),
		Excluded:                      []jsonExcluded{},
		Incomplete:                    res.Incomplete,
		Warnings:                      res.AllWarnings(),
		Notes:                         append([]string{}, res.Notes...),
	}
	if report.Warnings == nil {
		report.Warnings = []string{}
	}
	for _, e := range res.Excluded {
		report.Excluded = append(report.Excluded, jsonExcluded{Resource: e.Label, Reason: e.Reason})
	}
	for _, d := range r.Durations {
		report.Durations = append(report.Durations, d.Label)
		report.Totals[d.Label] = res.Totals[d.Label].Major()
		report.BuildOnlyTotals[d.Label] = res.BuildOnlyTotals[d.Label].Major()
	}
	for _, item := range res.Items {
		jr := jsonResource{
			Resource:        item.Resource.Label,
			Kind:            item.Resource.Kind.String(),
			Role:            item.Resource.Role,
			Pool:            item.Resource.Pool,
			RateID:          item.Resource.RateID,
			Qty:             item.Resource.Qty,
			SizeGB:          item.Resource.SizeGB,
			RateFound:       item.Found,
			Hourly:          item.Hourly.Major(),
			BuildOnly:       item.Resource.BuildOnly,
			SurvivesDestroy: item.Resource.SurvivesDestroy,
			Costs:           map[string]float64{},
			Capped:          map[string]bool{},
			Warnings:        item.Warnings,
		}
		for _, d := range r.Durations {
			jr.Costs[d.Label] = item.Costs[d.Label].Major()
			jr.Capped[d.Label] = item.Capped[d.Label]
		}
		report.Resources = append(report.Resources, jr)
	}

	enc := json.NewEncoder(w)
	enc.SetIndent("", "  ")
	return enc.Encode(report)
}
