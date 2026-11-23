package azure

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

// currency is the price list currency the report uses.
const currency = "USD"

// Synthetic rate IDs for non-VM rates. Disks are "disk:<tier>", e.g. disk:P15.
const (
	rateIP  = "public-ipv4"
	rateLB  = "lb"
	rateNAT = "nat-gateway"
	diskPfx = "disk:"
)

// Meter names of the non-VM rates.
const (
	meterPublicIP = "Standard IPv4 Static Public IP"
	meterLB       = "Standard Included LB Rules and Outbound Rules"
	meterNAT      = "Standard Gateway"
)

// diskTier is a Premium SSD size tier: name and size in GiB.
type diskTier struct {
	Name string
	GiB  float64
}

// diskTiers are the Premium SSD tiers, ascending. A disk is billed as the
// smallest tier that holds it.
var diskTiers = []diskTier{
	{"P1", 4}, {"P2", 8}, {"P3", 16}, {"P4", 32}, {"P6", 64}, {"P10", 128},
	{"P15", 256}, {"P20", 512}, {"P30", 1024}, {"P40", 2048}, {"P50", 4096},
	{"P60", 8192}, {"P70", 16384}, {"P80", 32767},
}

// tierFor returns the smallest tier holding gb.
func tierFor(gb float64) (diskTier, bool) {
	for _, t := range diskTiers {
		if gb <= t.GiB {
			return t, true
		}
	}
	return diskTier{}, false
}

func tierByName(name string) (diskTier, bool) {
	for _, t := range diskTiers {
		if t.Name == name {
			return t, true
		}
	}
	return diskTier{}, false
}

// PriceList is a set of Retail Prices API items.
type PriceList struct {
	BillingCurrency string `json:"BillingCurrency,omitempty"`
	Items           []Item `json:"Items"`
}

// Item is one meter of the Retail Prices API.
type Item struct {
	RetailPrice      json.Number `json:"retailPrice"`
	ArmRegionName    string      `json:"armRegionName"`
	MeterName        string      `json:"meterName"`
	ProductName      string      `json:"productName"`
	SkuName          string      `json:"skuName"`
	ServiceName      string      `json:"serviceName"`
	UnitOfMeasure    string      `json:"unitOfMeasure"`
	Type             string      `json:"type"`
	ArmSkuName       string      `json:"armSkuName"`
	TierMinimumUnits json.Number `json:"tierMinimumUnits,omitempty"`
	CurrencyCode     string      `json:"currencyCode,omitempty"`
}

// keep reports whether it is a meter the estimator reads: a base Consumption
// price in region (or global), in USD, and for VMs a Linux, on-demand one
// (the Spot and Low Priority meters have a different skuName).
func keep(it Item, region string) bool {
	if it.Type != "Consumption" || (it.CurrencyCode != "" && it.CurrencyCode != currency) {
		return false
	}
	if t := it.TierMinimumUnits.String(); t != "" && t != "0" && t != "0.0" {
		return false
	}
	switch it.ServiceName {
	case "Virtual Machines":
		return it.ArmRegionName == region && it.ArmSkuName != "" && it.SkuName == it.ArmSkuName &&
			!strings.Contains(it.ProductName, "Windows") && it.UnitOfMeasure == "1 Hour"
	case "Storage":
		return it.ArmRegionName == region && it.ProductName == "Premium SSD Managed Disks" &&
			strings.HasSuffix(it.SkuName, " LRS") && it.MeterName == it.SkuName+" Disk"
	case "Virtual Network":
		return it.ArmRegionName == region && it.MeterName == meterPublicIP && it.UnitOfMeasure == "1 Hour"
	case "Load Balancer":
		return it.ArmRegionName == globalRegion && it.MeterName == meterLB
	case "NAT Gateway":
		return it.ArmRegionName == globalRegion && it.MeterName == meterNAT
	}
	return false
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

// LoadPriceListFile decodes a saved API response (--catalog): the JSON of
// one page, or several pages merged into {"Items": [...]}.
func LoadPriceListFile(path string) (PriceList, error) {
	f, err := os.Open(path)
	if err != nil {
		return PriceList{}, err
	}
	defer f.Close()
	return decodePriceList(f)
}

// catalog resolves rate IDs against the kept items.
type catalog struct {
	vm    map[string]pricing.Micros // lowercase armSkuName -> per hour
	other map[string]pricing.Micros // synthetic id -> per hour (disks: per month)
	info  pricing.CatalogInfo
}

// ToCatalog builds a pricing.Catalog for region from the items.
func (pl PriceList) ToCatalog(region string, info pricing.CatalogInfo) (pricing.Catalog, error) {
	c := catalog{vm: map[string]pricing.Micros{}, other: map[string]pricing.Micros{}, info: info}
	for _, it := range pl.Items {
		if !keep(it, region) {
			continue
		}
		m, err := pricing.ParseMicros(it.RetailPrice)
		if err != nil {
			continue
		}
		switch it.ServiceName {
		case "Virtual Machines":
			k := strings.ToLower(it.ArmSkuName)
			if _, dup := c.vm[k]; !dup {
				c.vm[k] = m
			}
		case "Storage":
			c.other[diskPfx+strings.TrimSuffix(it.SkuName, " LRS")] = m
		case "Virtual Network":
			c.other[rateIP] = m
		case "Load Balancer":
			c.other[rateLB] = m
		case "NAT Gateway":
			c.other[rateNAT] = m
		}
	}
	if len(c.vm)+len(c.other) == 0 {
		return nil, fmt.Errorf("price list has no %s prices for region %q", currency, region)
	}
	return c, nil
}

// Lookup implements pricing.Catalog.
func (c catalog) Lookup(id string) (pricing.Plan, bool) {
	if strings.HasPrefix(id, diskPfx) {
		t, ok := tierByName(strings.TrimPrefix(id, diskPfx))
		m, found := c.other[id]
		if !ok || !found {
			return pricing.Plan{}, false
		}
		return pricing.Plan{ID: id, GBMonthly: pricing.Micros(float64(m)/t.GiB + 0.5)}, true
	}
	if m, ok := c.other[id]; ok {
		return pricing.Plan{ID: id, Hourly: m}, true
	}
	if m, ok := c.vm[strings.ToLower(id)]; ok {
		return pricing.Plan{ID: id, Hourly: m}, true
	}
	return pricing.Plan{}, false
}

// Currency implements pricing.Catalog.
func (catalog) Currency() string { return currency }

// Info implements pricing.Catalog.
func (c catalog) Info() pricing.CatalogInfo { return c.info }
