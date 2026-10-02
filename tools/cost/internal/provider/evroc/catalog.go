package evroc

import (
	"bytes"
	_ "embed"
	"encoding/json"
	"fmt"
	"os"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

// Synthetic rate IDs for non-instance rates.
const (
	rateDisk     = "storage:disk"
	ratePublicIP = "public-ipv4"
)

// sourceNote is part of every catalog's Info().Source.
const sourceNote = "derived from the public calculator because evroc provides no pricing API"

//go:embed ratecard.json
var embeddedCard []byte

// rateCard is the ratecard.json format. Amounts are EUR excluding VAT:
// instances per VM-hour, storage per GB-hour, public IP per hour. Refreshed
// by scripts/refresh-evroc-ratecard.sh.
type rateCard struct {
	Currency      string                 `json:"currency"`
	AsOf          string                 `json:"as_of"`
	SourceURL     string                 `json:"source_url"`
	Instances     map[string]json.Number `json:"instances"`
	StorageGBHour json.Number            `json:"storage_gb_hour"`
	PublicIPHour  json.Number            `json:"public_ip_hour"`
}

func parseCard(data []byte) (rateCard, error) {
	var c rateCard
	dec := json.NewDecoder(bytes.NewReader(data))
	dec.UseNumber()
	dec.DisallowUnknownFields()
	if err := dec.Decode(&c); err != nil {
		return c, err
	}
	switch {
	case c.Currency == "":
		return c, fmt.Errorf("rate card has no currency")
	case len(c.Instances) == 0:
		return c, fmt.Errorf("rate card has no instances")
	case c.StorageGBHour == "" || c.PublicIPHour == "":
		return c, fmt.Errorf("rate card needs storage_gb_hour and public_ip_hour")
	}
	return c, nil
}

// catalog is a pricing.Catalog that matches instance types case-insensitively.
type catalog struct{ pricing.StaticCatalog }

// Lookup implements pricing.Catalog.
func (c catalog) Lookup(id string) (pricing.Plan, bool) {
	return c.StaticCatalog.Lookup(strings.ToLower(id))
}

func (c rateCard) toCatalog(source string) (pricing.Catalog, error) {
	plans := map[string]pricing.Plan{}
	for id, n := range c.Instances {
		m, err := pricing.ParseMicros(n)
		if err != nil {
			return nil, fmt.Errorf("instance %s: %w", id, err)
		}
		id = strings.ToLower(id)
		plans[id] = pricing.Plan{ID: id, Hourly: m}
	}
	disk, err := pricing.ParseMicros(c.StorageGBHour)
	if err != nil {
		return nil, fmt.Errorf("storage_gb_hour: %w", err)
	}
	ip, err := pricing.ParseMicros(c.PublicIPHour)
	if err != nil {
		return nil, fmt.Errorf("public_ip_hour: %w", err)
	}
	plans[rateDisk] = pricing.Plan{ID: rateDisk, Hourly: disk}
	plans[ratePublicIP] = pricing.Plan{ID: ratePublicIP, Hourly: ip}
	return catalog{pricing.StaticCatalog{
		Cur:   c.Currency,
		Meta:  pricing.CatalogInfo{Source: source + " " + sourceNote, AsOf: c.AsOf},
		Plans: plans,
	}}, nil
}

// EmbeddedCatalog returns the rate card compiled into the binary.
func EmbeddedCatalog() (pricing.Catalog, error) {
	c, err := parseCard(embeddedCard)
	if err != nil {
		return nil, fmt.Errorf("embedded rate card: %w", err)
	}
	return c.toCatalog("ratecard")
}

// LoadCatalogFile reads a rate card in the ratecard.json format.
func LoadCatalogFile(path string) (pricing.Catalog, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	c, err := parseCard(data)
	if err != nil {
		return nil, err
	}
	return c.toCatalog("file")
}
