package gcp

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"regexp"
	"slices"
	"sort"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

// currency is the catalog currency the report uses; amounts are never
// converted.
const currency = "USD"

// Synthetic rate IDs for non-instance rates.
const (
	rateIP       = "ip:external"
	rateLBMin    = "lb:forwarding-min"
	rateLBExtra  = "lb:forwarding-extra"
	rateNATVM    = "nat:vm"
	rateSnapshot = "storage:snapshot"
	rateImage    = "storage:image"
	diskPrefix   = "disk:"
)

// Units of pricingExpression.usageUnit the estimator accepts per rate kind.
const (
	unitHour    = "h"
	unitGiBHour = "GiBy.h"
	unitGiBMon  = "GiBy.mo"
)

// SKU is one entry of the Cloud Billing Catalog API `skus` list.
type SKU struct {
	SkuID          string        `json:"skuId"`
	Description    string        `json:"description"`
	Category       Category      `json:"category"`
	ServiceRegions []string      `json:"serviceRegions"`
	PricingInfo    []PricingInfo `json:"pricingInfo"`
}

// Category is the SKU classification.
type Category struct {
	ResourceFamily string `json:"resourceFamily"`
	ResourceGroup  string `json:"resourceGroup"`
	UsageType      string `json:"usageType"`
}

// PricingInfo is one price version of a SKU.
type PricingInfo struct {
	EffectiveTime     string            `json:"effectiveTime"`
	PricingExpression PricingExpression `json:"pricingExpression"`
}

// PricingExpression holds the unit and the usage tiers.
type PricingExpression struct {
	UsageUnit   string       `json:"usageUnit"`
	TieredRates []TieredRate `json:"tieredRates"`
}

// TieredRate is the price from StartUsageAmount on.
type TieredRate struct {
	StartUsageAmount float64 `json:"startUsageAmount"`
	UnitPrice        Money   `json:"unitPrice"`
}

// Money is the API's google.type.Money: units is a string holding an int64.
type Money struct {
	CurrencyCode string `json:"currencyCode"`
	Units        string `json:"units"`
	Nanos        int64  `json:"nanos"`
}

// micros converts to whole millionths.
func (m Money) micros() (pricing.Micros, error) {
	units := m.Units
	if units == "" {
		units = "0"
	}
	return pricing.ParseMicros(json.Number(fmt.Sprintf("%s.%09d", units, m.Nanos)))
}

// PriceList is the SKUs of the services the estimator reads, in API shape.
// A --catalog file is the `skus` of one or more response pages joined.
type PriceList struct {
	SKUs []SKU `json:"skus"`
}

func decodePriceList(r io.Reader) (PriceList, error) {
	var pl PriceList
	if err := json.NewDecoder(r).Decode(&pl); err != nil {
		return PriceList{}, err
	}
	if len(pl.SKUs) == 0 {
		return PriceList{}, fmt.Errorf("price list has no skus")
	}
	return pl, nil
}

// LoadPriceListFile decodes a saved copy of the catalog (--catalog).
func LoadPriceListFile(path string) (PriceList, error) {
	f, err := os.Open(path)
	if err != nil {
		return PriceList{}, err
	}
	defer f.Close()
	return decodePriceList(f)
}

// spec says which SKU a rate comes from: the description pattern and the
// usage unit. Only OnDemand SKUs are matched.
type spec struct {
	key  string
	re   *regexp.Regexp
	unit string
}

// Description fragments that mark SKUs the estimator never uses (spot,
// commitments, sole tenancy, flex-start, custom shapes).
var excludedWords = []string{"Preemptible", "Spot", "Commitment", "Sole Tenancy", "DWS", "Flex Start", "Flex-start", "Custom", "Reserved", "Regional"}

// coreStems and gpuStems are the description prefixes (before " running in" or
// " in") of the vCPU, memory and GPU SKUs. Unverified against the live
// catalog: the live test checks them.
var coreStems = map[string]string{
	"e2": "E2 Instance", "n1": "N1 Predefined Instance", "n2": "N2 Instance",
	"n2d": "N2D AMD Instance", "n4": "N4 Instance", "c2": "Compute optimized",
	"c2d": "C2D AMD Instance", "c3": "C3 Instance", "c3d": "C3D AMD Instance",
	"c4": "C4 Instance", "g2": "G2 Instance", "g4": "G4 Instance",
	"a2": "A2 Instance", "a3": "A3 Instance",
}

var gpuStems = map[string]string{
	"l4":           "Nvidia L4 GPU",
	"rtx-pro-6000": "Nvidia RTX PRO 6000 GPU",
	"a100-40":      "Nvidia Tesla A100 GPU",
	"a100-80":      "Nvidia Tesla A100 80GB GPU",
	"h100-80":      "Nvidia H100 80GB GPU",
	"h200-141":     "Nvidia H200 141GB GPU",
}

// diskStems are the capacity SKU descriptions per boot disk type.
var diskStems = map[string]string{
	"pd-standard":          `Storage PD Capacity`,
	"pd-balanced":          `Balanced PD Capacity`,
	"pd-ssd":               `SSD backed PD Capacity`,
	"hyperdisk-balanced":   `Hyperdisk Balanced (Provisioned )?Capacity`,
	"hyperdisk-extreme":    `Hyperdisk Extreme (Provisioned )?Capacity`,
	"hyperdisk-throughput": `Hyperdisk Throughput (Provisioned )?Capacity`,
}

func mustRe(s string) *regexp.Regexp { return regexp.MustCompile(s) }

// inRegion is the tail of the description: " running in <place>" or " in <place>".
const inRegion = `( running)? in `

func specs() []spec {
	var out []spec
	for fam, stem := range coreStems {
		out = append(out,
			spec{"core:" + fam, mustRe(`^` + regexp.QuoteMeta(stem) + ` Core` + inRegion), unitHour},
			spec{"ram:" + fam, mustRe(`^` + regexp.QuoteMeta(stem) + ` Ram` + inRegion), unitGiBHour})
	}
	for k, stem := range gpuStems {
		out = append(out, spec{"gpu:" + k, mustRe(`^` + regexp.QuoteMeta(stem) + inRegion), unitHour})
	}
	for k, stem := range diskStems {
		out = append(out, spec{diskPrefix + k, mustRe(`^` + stem + inRegion), unitGiBMon})
	}
	out = append(out,
		spec{rateIP, mustRe(`^External IP Charge on a Standard VM`), unitHour},
		spec{rateLBMin, mustRe(`(?i)^network load balancing: forwarding rule minimum service charge`), unitHour},
		spec{rateLBExtra, mustRe(`(?i)^network load balancing: forwarding rule additional service charge`), unitHour},
		spec{rateNATVM, mustRe(`(?i)^cloud nat gateway.*uptime`), unitHour},
		spec{rateSnapshot, mustRe(`^Storage PD Snapshot` + inRegion), unitGiBMon},
		spec{rateImage, mustRe(`^Storage Image` + inRegion), unitGiBMon},
	)
	sort.Slice(out, func(i, j int) bool { return out[i].key < out[j].key })
	return out
}

var allSpecs = specs()

// usable reports whether the SKU is an on-demand SKU for region (or a global
// one) that the exclusion words do not rule out.
func (s SKU) usable(region string) bool {
	if s.Category.UsageType != "OnDemand" {
		return false
	}
	for _, w := range excludedWords {
		if strings.Contains(s.Description, w) {
			return false
		}
	}
	return slices.Contains(s.ServiceRegions, region) || slices.Contains(s.ServiceRegions, "global")
}

// rate returns the price of the SKU in the unit: of the tiers, the first
// with a non-zero price (what is billed past any free tier).
func (s SKU) rate(unit string) (pricing.Micros, string, bool) {
	for _, pi := range s.PricingInfo {
		if pi.PricingExpression.UsageUnit != unit {
			continue
		}
		for _, t := range pi.PricingExpression.TieredRates {
			if t.UnitPrice.CurrencyCode != "" && t.UnitPrice.CurrencyCode != currency {
				continue
			}
			m, err := t.UnitPrice.micros()
			if err == nil && m > 0 {
				return m, pi.EffectiveTime, true
			}
		}
	}
	return 0, "", false
}

// match is the SKUs of a spec for region. Regional SKUs win over global ones;
// among several candidates the cheapest is used, so a duplicate description
// never raises the estimate.
func match(sk []SKU, sp spec, region string) (m pricing.Micros, effective string, found, regional bool) {
	best, at, bestRegional := pricing.Micros(0), "", false
	for _, s := range sk {
		if !s.usable(region) || !sp.re.MatchString(s.Description) {
			continue
		}
		price, eff, ok := s.rate(sp.unit)
		if !ok {
			continue
		}
		isRegional := slices.Contains(s.ServiceRegions, region)
		if !found || (isRegional && !bestRegional) || (isRegional == bestRegional && price < best) {
			best, at, found, bestRegional = price, eff, true, isRegional
		}
	}
	return best, at, found, bestRegional
}

// filtered keeps only the SKUs the estimator can use in region, so the cache
// is small.
func (pl PriceList) filtered(region string) PriceList {
	var out PriceList
	for _, s := range pl.SKUs {
		if !s.usable(region) {
			continue
		}
		for _, sp := range allSpecs {
			if sp.re.MatchString(s.Description) {
				out.SKUs = append(out.SKUs, s)
				break
			}
		}
	}
	return out
}

// catalog resolves machine types and synthetic IDs against the rates.
type catalog struct {
	rates map[string]pricing.Micros
	info  pricing.CatalogInfo
}

// ToCatalog resolves the rates for region. info.AsOf is filled with the
// latest effective time of the used SKUs when empty.
func (pl PriceList) ToCatalog(region string, info pricing.CatalogInfo) (pricing.Catalog, error) {
	rates := map[string]pricing.Micros{}
	latest, hasRegional := "", false
	for _, sp := range allSpecs {
		if m, eff, ok, regional := match(pl.SKUs, sp, region); ok {
			rates[sp.key] = m
			hasRegional = hasRegional || regional
			if eff > latest {
				latest = eff
			}
		}
	}
	if !hasRegional {
		return nil, fmt.Errorf("catalog has no %s on-demand prices for region %q", currency, region)
	}
	if info.AsOf == "" {
		info.AsOf = latest
	}
	return catalog{rates: rates, info: info}, nil
}

// Lookup implements pricing.Catalog.
func (c catalog) Lookup(id string) (pricing.Plan, bool) {
	switch id {
	case rateIP, rateLBMin, rateLBExtra, rateNATVM:
		h, ok := c.rates[id]
		return pricing.Plan{ID: id, Hourly: h}, ok
	case rateSnapshot, rateImage:
		g, ok := c.rates[id]
		return pricing.Plan{ID: id, GBMonthly: g}, ok
	}
	if t, ok := strings.CutPrefix(id, diskPrefix); ok {
		g, ok := c.rates[diskPrefix+t]
		return pricing.Plan{ID: id, GBMonthly: g}, ok
	}
	m, ok := parseMachine(id)
	if !ok {
		return pricing.Plan{}, false
	}
	core, ok1 := c.rates["core:"+m.family]
	ram, ok2 := c.rates["ram:"+m.family]
	h := pricing.Micros(m.vcpu)*core + pricing.Micros(float64(ram)*m.ramGB+0.5)
	ok = ok1 && ok2
	if m.gpus > 0 {
		g, okg := c.rates["gpu:"+m.gpu]
		h += pricing.Micros(m.gpus) * g
		ok = ok && okg
	}
	return pricing.Plan{ID: id, Hourly: h}, ok
}

// Currency implements pricing.Catalog.
func (catalog) Currency() string { return currency }

// Info implements pricing.Catalog.
func (c catalog) Info() pricing.CatalogInfo { return c.info }
