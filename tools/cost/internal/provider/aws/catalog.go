package aws

import (
	"context"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"time"

	awsconfig "github.com/aws/aws-sdk-go-v2/config"
	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
	"github.com/aws/aws-sdk-go-v2/service/pricing/types"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
)

// The Price List API is served from a few regions only; its data covers
// every region through the regionCode attribute.
const pricingEndpointRegion = "us-east-1"

// productsAPI is the part of the Price List client the estimator uses.
type productsAPI interface {
	GetProducts(ctx context.Context, in *awspricing.GetProductsInput, optFns ...func(*awspricing.Options)) (*awspricing.GetProductsOutput, error)
}

// query selects one rate from GetProducts results: the server-side filters
// narrow the products, pick keeps the one whose usage type is wanted.
type query struct {
	id      string
	service string
	filters [][2]string // field, value
	unit    string      // price dimension unit
	pick    func(attrs map[string]string) bool
	apply   func(rate pricing.Micros) pricing.Plan
}

func usageSuffix(s string) func(map[string]string) bool {
	return func(a map[string]string) bool { return strings.HasSuffix(a["usagetype"], s) }
}

// EC2 and EBS bill per second with a 60 s minimum; NAT gateways, load
// balancers and public IPv4 addresses bill per started hour.
const perSecondMin = 1.0 / 60

func fixedQueries() []query {
	return []query{
		{
			id: rateDisk, service: "AmazonEC2", unit: "GB-Mo",
			filters: [][2]string{{"productFamily", "Storage"}, {"volumeApiName", "gp3"}},
			pick:    func(a map[string]string) bool { return a["volumeApiName"] == "gp3" },
			apply:   func(r pricing.Micros) pricing.Plan { return pricing.Plan{GBMonthly: r, MinHours: perSecondMin} },
		},
		{
			id: rateSnapshot, service: "AmazonEC2", unit: "GB-Mo",
			filters: [][2]string{{"productFamily", "Storage Snapshot"}},
			pick:    usageSuffix("EBS:SnapshotUsage"),
			apply:   func(r pricing.Micros) pricing.Plan { return pricing.Plan{GBMonthly: r} },
		},
		{
			id: rateNAT, service: "AmazonEC2", unit: "Hrs",
			filters: [][2]string{{"productFamily", "NAT Gateway"}},
			pick:    usageSuffix("NatGateway-Hours"),
			apply:   func(r pricing.Micros) pricing.Plan { return pricing.Plan{Hourly: r, MinHours: 1} },
		},
		{
			id: ratePublicIP, service: "AmazonVPC", unit: "Hrs",
			filters: [][2]string{{"group", "VPCPublicIPv4Address"}},
			pick:    usageSuffix("PublicIPv4:InUseAddress"),
			apply:   func(r pricing.Micros) pricing.Plan { return pricing.Plan{Hourly: r, MinHours: 1} },
		},
		{
			id: rateLB, service: "AWSELB", unit: "Hrs",
			filters: [][2]string{{"productFamily", "Load Balancer-Network"}},
			pick:    usageSuffix("LoadBalancerUsage"),
			apply:   func(r pricing.Micros) pricing.Plan { return pricing.Plan{Hourly: r, MinHours: 1} },
		},
	}
}

func instanceQuery(instanceType string) query {
	return query{
		id: instanceType, service: "AmazonEC2", unit: "Hrs",
		filters: [][2]string{
			{"instanceType", instanceType}, {"operatingSystem", "Linux"}, {"preInstalledSw", "NA"},
			{"capacitystatus", "Used"}, {"tenancy", "Shared"}, {"licenseModel", "No License required"},
		},
		pick:  func(a map[string]string) bool { return a["instanceType"] == instanceType },
		apply: func(r pricing.Micros) pricing.Plan { return pricing.Plan{Hourly: r, MinHours: perSecondMin} },
	}
}

// priceItem is the part of one PriceList entry that is read.
type priceItem struct {
	Product struct {
		Attributes map[string]string `json:"attributes"`
	} `json:"product"`
	Terms struct {
		OnDemand map[string]struct {
			PriceDimensions map[string]struct {
				Unit         string            `json:"unit"`
				PricePerUnit map[string]string `json:"pricePerUnit"`
			} `json:"priceDimensions"`
		} `json:"OnDemand"`
	} `json:"terms"`
}

// parseRate returns the USD on-demand price of the first item q picks.
func parseRate(q query, priceList []string) (pricing.Micros, bool, error) {
	for _, raw := range priceList {
		var it priceItem
		if err := json.Unmarshal([]byte(raw), &it); err != nil {
			return 0, false, fmt.Errorf("parsing price list entry for %s: %w", q.id, err)
		}
		if !q.pick(it.Product.Attributes) {
			continue
		}
		offers := make([]string, 0, len(it.Terms.OnDemand))
		for k := range it.Terms.OnDemand {
			offers = append(offers, k)
		}
		sort.Strings(offers)
		for _, k := range offers {
			dims := it.Terms.OnDemand[k].PriceDimensions
			names := make([]string, 0, len(dims))
			for n := range dims {
				names = append(names, n)
			}
			sort.Strings(names)
			for _, n := range names {
				d := dims[n]
				usd, ok := d.PricePerUnit["USD"]
				if d.Unit != q.unit || !ok {
					continue
				}
				m, err := pricing.ParseMicros(json.Number(usd))
				if err != nil {
					return 0, false, fmt.Errorf("price of %s: %w", q.id, err)
				}
				return m, true, nil
			}
		}
	}
	return 0, false, nil
}

// fetchRate runs q for region, following pagination.
func fetchRate(ctx context.Context, api productsAPI, region string, q query) (pricing.Micros, bool, error) {
	filters := []types.Filter{{Type: types.FilterTypeTermMatch, Field: ptr("regionCode"), Value: ptr(region)}}
	for _, f := range q.filters {
		filters = append(filters, types.Filter{Type: types.FilterTypeTermMatch, Field: ptr(f[0]), Value: ptr(f[1])})
	}
	var token *string
	for {
		out, err := api.GetProducts(ctx, &awspricing.GetProductsInput{
			ServiceCode: ptr(q.service), Filters: filters, NextToken: token, MaxResults: ptr(int32(100)),
		})
		if err != nil {
			return 0, false, err
		}
		if m, ok, err := parseRate(q, out.PriceList); err != nil || ok {
			return m, ok, err
		}
		if out.NextToken == nil || *out.NextToken == "" {
			return 0, false, nil
		}
		token = out.NextToken
	}
}

func ptr[T any](v T) *T { return &v }

// authError wraps a failure of the first API call with what to do about it.
func authError(err error) error {
	return fmt.Errorf("aws pricing needs valid AWS credentials (pricing:GetProducts) and network access: %v. Log in (e.g. aws sso login) or pass --catalog FILE.", err)
}

// fetchPlans prices the fixed products and instanceTypes for region. The
// fixed products go first, so an authentication or network failure surfaces
// on the first call. An instance type with no price is left out of the
// result: pricing.Price reports it with its row.
func fetchPlans(ctx context.Context, api productsAPI, region string, instanceTypes []string) (map[string]pricing.Plan, error) {
	plans := map[string]pricing.Plan{}
	qs := fixedQueries()
	for _, t := range instanceTypes {
		qs = append(qs, instanceQuery(t))
	}
	for i, q := range qs {
		rate, ok, err := fetchRate(ctx, api, region, q)
		if err != nil {
			if i == 0 {
				return nil, authError(err)
			}
			return nil, fmt.Errorf("aws pricing: fetching %s for %s: %w", q.id, region, err)
		}
		if !ok {
			if i < len(fixedQueries()) {
				return nil, fmt.Errorf("aws pricing: no %s price in region %q (is the region code right?)", q.id, region)
			}
			continue
		}
		p := q.apply(rate)
		p.ID = q.id
		plans[q.id] = p
	}
	return plans, nil
}

// Catalog resolves rates in this order: the --catalog file; with --no-network
// the warm cache; otherwise the Price List API with the default credential
// chain. The live path never falls back to the cache: stale prices must be
// asked for with --no-network.
func (p *awsProvider) Catalog(ctx context.Context, region string, o provider.CatalogOpts) (pricing.Catalog, error) {
	if region == "" {
		return nil, fmt.Errorf("no region: pass --region")
	}
	if o.File != "" {
		cf, err := loadCacheFile(o.File)
		if err != nil {
			return nil, fmt.Errorf("loading --catalog %s: %w", o.File, err)
		}
		if cf.Region != region {
			return nil, fmt.Errorf("--catalog %s holds prices for region %q, not %q", o.File, cf.Region, region)
		}
		return cf.catalog(pricing.CatalogInfo{Source: "file", AsOf: cf.FetchedAt.UTC().Format(time.RFC3339)}), nil
	}

	cache := ""
	if o.CacheDir != "" {
		cache = cachePath(o.CacheDir, region)
	}
	if o.NoNetwork {
		if cache != "" {
			if cf, err := loadCacheFile(cache); err == nil {
				age := time.Since(cf.FetchedAt).Round(time.Minute)
				return cf.catalog(pricing.CatalogInfo{Source: "cache", AsOf: cf.FetchedAt.UTC().Format(time.RFC3339), Age: fmt.Sprintf("(%s old)", age)}), nil
			}
		}
		return nil, fmt.Errorf("--no-network was set, no --catalog given, and no warm cache is available at %s", cache)
	}

	api := p.api
	if api == nil {
		cfg, err := awsconfig.LoadDefaultConfig(ctx, awsconfig.WithRegion(pricingEndpointRegion))
		if err != nil {
			return nil, authError(err)
		}
		api = awspricing.NewFromConfig(cfg)
	}
	ctx, cancel := context.WithTimeout(ctx, 2*time.Minute)
	defer cancel()
	fetchedAt := time.Now()
	plans, err := fetchPlans(ctx, api, region, p.neededTypes())
	if err != nil {
		return nil, err
	}
	cf := newCacheFile(region, fetchedAt, plans)
	if cache != "" {
		// Merge into the cache so instance types of earlier runs stay available offline.
		if old, err := loadCacheFile(cache); err == nil && old.Region == region {
			cf = old.merge(cf)
		}
		_ = saveCacheFile(cache, cf) // best effort
	}
	return newCacheFile(region, fetchedAt, plans).catalog(pricing.CatalogInfo{Source: "api", AsOf: fetchedAt.UTC().Format(time.RFC3339)}), nil
}
