package azure

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"time"
)

// PriceURL is the public, unauthenticated Azure Retail Prices API.
const PriceURL = "https://prices.azure.com/api/retail/prices"

// globalRegion is the armRegionName of meters that have no region (load
// balancer rules, NAT gateway hours).
const globalRegion = "Global"

// queries returns the OData filters the estimator needs for region. Values
// are case sensitive. The API has no `not` operator, so Windows, Spot and
// Low Priority meters are dropped client-side by keep.
func queries(region string) []string {
	base := "priceType eq 'Consumption' and "
	return []string{
		base + "serviceName eq 'Virtual Machines' and armRegionName eq '" + region + "'",
		base + "serviceName eq 'Storage' and productName eq 'Premium SSD Managed Disks' and armRegionName eq '" + region + "'",
		base + "serviceName eq 'Virtual Network' and meterName eq '" + meterPublicIP + "' and armRegionName eq '" + region + "'",
		base + "serviceName eq 'Load Balancer' and meterName eq '" + meterLB + "' and armRegionName eq '" + globalRegion + "'",
		base + "serviceName eq 'NAT Gateway' and meterName eq '" + meterNAT + "' and armRegionName eq '" + globalRegion + "'",
	}
}

type page struct {
	Items        []Item `json:"Items"`
	NextPageLink string `json:"NextPageLink"`
}

// FetchLive fetches the prices of region, following NextPageLink, and keeps
// the items the estimator uses. timeout bounds the whole fetch.
func FetchLive(ctx context.Context, client *http.Client, region string, timeout time.Duration) (PriceList, error) {
	if client == nil {
		client = http.DefaultClient
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	out := PriceList{BillingCurrency: currency}
	for _, filter := range queries(region) {
		next := PriceURL + "?currencyCode=" + currency + "&$filter=" + url.QueryEscape(filter)
		for pages := 0; next != "" && pages < 100; pages++ {
			var p page
			if err := getJSON(ctx, client, next, &p); err != nil {
				return PriceList{}, err
			}
			for _, it := range p.Items {
				if keep(it, region) {
					out.Items = append(out.Items, it)
				}
			}
			next = p.NextPageLink
		}
	}
	if len(out.Items) == 0 {
		return PriceList{}, fmt.Errorf("the price API returned no usable prices for region %q (use an armRegionName such as westeurope)", region)
	}
	return out, nil
}

func getJSON(ctx context.Context, client *http.Client, u string, v any) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return fmt.Errorf("fetching %s: %w", PriceURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("fetching %s: HTTP %d", PriceURL, resp.StatusCode)
	}
	if err := json.NewDecoder(resp.Body).Decode(v); err != nil {
		return fmt.Errorf("decoding %s: %w", PriceURL, err)
	}
	return nil
}
