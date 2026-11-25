package gcp

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/url"
	"os"
	"time"
)

// KeyEnv is the environment variable that holds the Cloud Billing API key.
const KeyEnv = "GCP_PRICING_API_KEY"

// BaseURL is the Cloud Billing Catalog API root; a variable for tests.
var BaseURL = "https://cloudbilling.googleapis.com/v1"

// Services read: Compute Engine (instances, disks, snapshots, images, IPs,
// NAT) and Networking (load balancer forwarding rules, which moved there in
// 2022). The second is optional: a failure leaves the load balancer rate out.
var (
	computeService    = "6F81-5844-456A"
	networkingService = "E505-1604-58F8"
)

// APIKey returns the key from the environment or an error saying how to set it.
func APIKey() (string, error) {
	if k := os.Getenv(KeyEnv); k != "" {
		return k, nil
	}
	return "", fmt.Errorf("%s is not set: create an API key with the Cloud Billing API enabled (https://cloud.google.com/billing/docs/how-to/get-pricing-information-api) and export it, or pass --catalog", KeyEnv)
}

type skuPage struct {
	SKUs          []SKU  `json:"skus"`
	NextPageToken string `json:"nextPageToken"`
}

// fetchService reads every page of a service's SKUs. The key goes in a header,
// never in the URL, so errors cannot leak it.
func fetchService(ctx context.Context, client *http.Client, key, service string) ([]SKU, error) {
	var all []SKU
	token := ""
	for {
		q := url.Values{"currencyCode": {currency}, "pageSize": {"5000"}}
		if token != "" {
			q.Set("pageToken", token)
		}
		u := fmt.Sprintf("%s/services/%s/skus?%s", BaseURL, service, q.Encode())
		req, err := http.NewRequestWithContext(ctx, http.MethodGet, u, nil)
		if err != nil {
			return nil, err
		}
		req.Header.Set("X-Goog-Api-Key", key)
		resp, err := client.Do(req)
		if err != nil {
			return nil, fmt.Errorf("fetching SKUs of service %s: %w", service, err)
		}
		var p skuPage
		err = func() error {
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return fmt.Errorf("fetching SKUs of service %s: HTTP %d", service, resp.StatusCode)
			}
			return json.NewDecoder(resp.Body).Decode(&p)
		}()
		if err != nil {
			return nil, err
		}
		all = append(all, p.SKUs...)
		if p.NextPageToken == "" {
			return all, nil
		}
		token = p.NextPageToken
	}
}

// FetchLive reads the catalog with the API key and keeps the SKUs the
// estimator uses in region.
func FetchLive(ctx context.Context, client *http.Client, key, region string, timeout time.Duration) (PriceList, error) {
	if client == nil {
		client = http.DefaultClient
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	skus, err := fetchService(ctx, client, key, computeService)
	if err != nil {
		return PriceList{}, err
	}
	if more, err := fetchService(ctx, client, key, networkingService); err == nil {
		skus = append(skus, more...)
	}
	pl := PriceList{SKUs: skus}.filtered(region)
	if len(pl.SKUs) == 0 {
		return PriceList{}, fmt.Errorf("the catalog has no usable SKUs for region %q", region)
	}
	return pl, nil
}
