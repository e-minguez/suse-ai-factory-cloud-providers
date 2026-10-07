package exoscale

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

// currency is the price list section the report uses. The list also has chf
// and usd; amounts are never converted.
const currency = "eur"

// Synthetic rate IDs for non-instance rates.
const (
	rateDisk        = "storage:disk"
	rateDiskStorage = "storage:disk-storage-optimized"
	rateTemplate    = "storage:template"
	rateLB          = "lb"
)

// Instance type families with their own pricing rules.
const (
	standardFamily = "standard" // price key has no family: running_<size>
	storageFamily  = "storage"  // local disk billed at volume_data
)

// syntheticKeys maps synthetic rate IDs to their price list keys. Every
// rate is per hour; storage rates are per GiB-hour.
var syntheticKeys = map[string]string{
	rateDisk:        "volume",
	rateDiskStorage: "volume_data",
	rateTemplate:    "template",
	rateLB:          "network_load_balancer",
}

// PriceList is the public price list: currency -> price key -> decimal string.
type PriceList map[string]map[string]string

func decodePriceList(r io.Reader) (PriceList, error) {
	var pl PriceList
	if err := json.NewDecoder(r).Decode(&pl); err != nil {
		return nil, err
	}
	if len(pl[currency]) == 0 {
		return nil, fmt.Errorf("price list has no %q section", currency)
	}
	return pl, nil
}

// LoadPriceListFile decodes a saved copy of the price list (--catalog).
func LoadPriceListFile(path string) (PriceList, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return decodePriceList(f)
}

// instanceKey maps an instance type (family.size) to its price key:
// standard.extra-large -> running_extra_large, gpu3.small -> running_gpu3_small.
func instanceKey(instanceType string) (string, bool) {
	family, size, ok := strings.Cut(strings.ToLower(instanceType), ".")
	if !ok || family == "" || size == "" {
		return "", false
	}
	size = strings.ReplaceAll(size, "-", "_")
	if family == standardFamily {
		return "running_" + size, true
	}
	return "running_" + family + "_" + size, true
}

// diskRate is the rate ID of an instance's local disk: storage optimized
// instances bill their disk at a lower rate.
func diskRate(instanceType string) string {
	if family, _, _ := strings.Cut(strings.ToLower(instanceType), "."); family == storageFamily {
		return rateDiskStorage
	}
	return rateDisk
}

// catalog resolves instance types and synthetic IDs against one currency of
// the price list.
type catalog struct {
	prices map[string]pricing.Micros
	info   pricing.CatalogInfo
}

// ToCatalog parses the currency's rates into a pricing.Catalog.
func (pl PriceList) ToCatalog(info pricing.CatalogInfo) (pricing.Catalog, error) {
	prices := make(map[string]pricing.Micros, len(pl[currency]))
	for k, v := range pl[currency] {
		m, err := pricing.ParseMicros(json.Number(v))
		if err != nil {
			return nil, fmt.Errorf("price %s: %w", k, err)
		}
		prices[k] = m
	}
	return catalog{prices: prices, info: info}, nil
}

// Lookup implements pricing.Catalog.
func (c catalog) Lookup(id string) (pricing.Plan, bool) {
	key, ok := syntheticKeys[id]
	if !ok {
		if key, ok = instanceKey(id); !ok {
			return pricing.Plan{}, false
		}
	}
	m, ok := c.prices[key]
	if !ok {
		return pricing.Plan{}, false
	}
	return pricing.Plan{ID: id, Hourly: m}, true
}

// Currency implements pricing.Catalog.
func (catalog) Currency() string { return strings.ToUpper(currency) }

// Info implements pricing.Catalog.
func (c catalog) Info() pricing.CatalogInfo { return c.info }
