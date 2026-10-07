package exoscale

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

// PriceListURL is public and unauthenticated: no API key is needed to price
// a cluster before it exists.
const PriceListURL = "https://portal.exoscale.com/api/pricing/opencompute"

// FetchLive fetches the price list over HTTP.
func FetchLive(ctx context.Context, client *http.Client, timeout time.Duration) (PriceList, error) {
	if client == nil {
		client = http.DefaultClient
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, PriceListURL, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("fetching %s: %w", PriceListURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("fetching %s: HTTP %d", PriceListURL, resp.StatusCode)
	}
	pl, err := decodePriceList(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("decoding %s: %w", PriceListURL, err)
	}
	return pl, nil
}
