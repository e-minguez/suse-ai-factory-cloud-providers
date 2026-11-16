package oci

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strconv"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

// currency is the price list currency the report uses; amounts are never
// converted.
const currency = "USD"

// Synthetic rate IDs for non-instance rates.
const (
	rateBoot   = "storage:boot"
	rateObject = "storage:object"
)

// Part numbers of the non-instance rates.
const (
	partBlockStorage = "B91961" // Block Volume - Storage, per GB-month
	partBlockPerf    = "B91962" // Block Volume - Performance Units, per GB-month per VPU
	partObject       = "B91628" // Object Storage - Storage, per GB-month
)

// bootVPUs is the performance level of boot volumes, in volume performance
// units per GB (10 is the OCI default, "Balanced").
const bootVPUs = 10

// flexParts are the OCPU and memory part numbers of each flex shape (OCPU per
// hour, memory GB per hour), keyed by lowercase shape name.
var flexParts = map[string][2]string{
	"vm.standard.e3.flex": {"B92306", "B92307"},
	"vm.standard.e4.flex": {"B93113", "B93114"},
	"vm.standard.e5.flex": {"B97384", "B97385"},
	"vm.standard.e6.flex": {"B111129", "B111130"},
	"vm.standard.a1.flex": {"B93297", "B93298"},
	"vm.standard3.flex":   {"B94176", "B94177"},
}

// gpuShape is a fixed GPU shape: a per GPU-hour part number (CPU and memory
// included) and the number of GPUs.
type gpuShape struct {
	part string
	gpus int
}

var gpuShapes = map[string]gpuShape{
	"vm.gpu.a10.1": {"B95909", 1},
	"vm.gpu.a10.2": {"B95909", 2},
	"vm.gpu3.1":    {"B89734", 1},
	"vm.gpu3.2":    {"B89734", 2},
	"vm.gpu3.4":    {"B89734", 4},
	"vm.gpu2.1":    {"B88518", 1},
}

func isFlex(shape string) bool { return strings.HasSuffix(strings.ToLower(shape), ".flex") }

// wanted lists every part number the estimator reads.
func wanted() map[string]bool {
	w := map[string]bool{partBlockStorage: true, partBlockPerf: true, partObject: true}
	for _, p := range flexParts {
		w[p[0]], w[p[1]] = true, true
	}
	for _, g := range gpuShapes {
		w[g.part] = true
	}
	return w
}

// PriceList is the public price list in its API shape.
type PriceList struct {
	LastUpdated string `json:"lastUpdated"`
	Items       []Item `json:"items"`
}

// Item is one product of the price list.
type Item struct {
	PartNumber  string         `json:"partNumber"`
	DisplayName string         `json:"displayName"`
	MetricName  string         `json:"metricName"`
	Currencies  []itemCurrency `json:"currencyCodeLocalizations"`
}

type itemCurrency struct {
	Code   string  `json:"currencyCode"`
	Prices []price `json:"prices"`
}

type price struct {
	Model    string      `json:"model"`
	Value    json.Number `json:"value"`
	RangeMin json.Number `json:"rangeMin,omitempty"`
}

func decodePriceList(r io.Reader) (PriceList, error) {
	var pl PriceList
	if err := json.NewDecoder(r).Decode(&pl); err != nil {
		return PriceList{}, err
	}
	if len(pl.Items) == 0 {
		return PriceList{}, fmt.Errorf("price list has no items")
	}
	return pl, nil
}

// LoadPriceListFile decodes a saved copy of the price list (--catalog).
func LoadPriceListFile(path string) (PriceList, error) {
	f, err := os.Open(path)
	if err != nil {
		return PriceList{}, err
	}
	defer f.Close()
	return decodePriceList(f)
}

// filtered keeps only the items the estimator uses.
func (pl PriceList) filtered() PriceList {
	w := wanted()
	out := PriceList{LastUpdated: pl.LastUpdated}
	for _, it := range pl.Items {
		if w[it.PartNumber] {
			out.Items = append(out.Items, it)
		}
	}
	return out
}

// unitPrice is the pay-as-you-go price of an item in currency: of the tiers,
// the one with the highest range minimum (what is billed past any free tier).
func (it Item) unitPrice() (pricing.Micros, bool) {
	best, bestMin, found := pricing.Micros(0), -1.0, false
	for _, c := range it.Currencies {
		if c.Code != currency {
			continue
		}
		for _, p := range c.Prices {
			if p.Model != "PAY_AS_YOU_GO" {
				continue
			}
			min, _ := strconv.ParseFloat(p.RangeMin.String(), 64)
			m, err := pricing.ParseMicros(p.Value)
			if err != nil {
				continue
			}
			if min > bestMin {
				best, bestMin, found = m, min, true
			}
		}
	}
	return best, found
}

// catalog resolves instance types and synthetic IDs against the price list.
type catalog struct {
	parts map[string]pricing.Micros
	info  pricing.CatalogInfo
}

// ToCatalog parses the price list into a pricing.Catalog.
func (pl PriceList) ToCatalog(info pricing.CatalogInfo) (pricing.Catalog, error) {
	parts := map[string]pricing.Micros{}
	for _, it := range pl.Items {
		if m, ok := it.unitPrice(); ok {
			parts[it.PartNumber] = m
		}
	}
	if len(parts) == 0 {
		return nil, fmt.Errorf("price list has no %s prices", currency)
	}
	return catalog{parts: parts, info: info}, nil
}

// Lookup implements pricing.Catalog.
func (c catalog) Lookup(id string) (pricing.Plan, bool) {
	switch id {
	case rateBoot:
		s, ok1 := c.parts[partBlockStorage]
		p, ok2 := c.parts[partBlockPerf]
		return pricing.Plan{ID: id, GBMonthly: s + bootVPUs*p}, ok1 && ok2
	case rateObject:
		o, ok := c.parts[partObject]
		return pricing.Plan{ID: id, GBMonthly: o}, ok
	}
	m := shapeFormat.FindStringSubmatch(id)
	if m == nil {
		return pricing.Plan{}, false
	}
	name := strings.ToLower(m[1])
	if m[2] != "" {
		parts, ok := flexParts[name]
		if !ok || !isFlex(name) {
			return pricing.Plan{}, false
		}
		ocpus, _ := strconv.Atoi(m[2])
		mem, _ := strconv.Atoi(m[3])
		o, ok1 := c.parts[parts[0]]
		g, ok2 := c.parts[parts[1]]
		return pricing.Plan{ID: id, Hourly: pricing.Micros(ocpus)*o + pricing.Micros(mem)*g}, ok1 && ok2
	}
	g, ok := gpuShapes[name]
	if !ok {
		return pricing.Plan{}, false
	}
	h, ok := c.parts[g.part]
	return pricing.Plan{ID: id, Hourly: pricing.Micros(g.gpus) * h}, ok
}

// Currency implements pricing.Catalog.
func (catalog) Currency() string { return currency }

// Info implements pricing.Catalog.
func (c catalog) Info() pricing.CatalogInfo { return c.info }
