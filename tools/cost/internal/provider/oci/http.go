package oci

import (
	"context"
	"fmt"
	"net/http"
	"time"
)

// PriceListURL is public and unauthenticated: no API key is needed and the
// whole list comes in one response.
const PriceListURL = "https://apexapps.oracle.com/pls/apex/cetools/api/v1/products/?currencyCode=" + currency

// FetchLive fetches the price list over HTTP and keeps the parts the
// estimator uses.
func FetchLive(ctx context.Context, client *http.Client, timeout time.Duration) (PriceList, error) {
	if client == nil {
		client = http.DefaultClient
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, PriceListURL, nil)
	if err != nil {
		return PriceList{}, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return PriceList{}, fmt.Errorf("fetching %s: %w", PriceListURL, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return PriceList{}, fmt.Errorf("fetching %s: HTTP %d", PriceListURL, resp.StatusCode)
	}
	pl, err := decodePriceList(resp.Body)
	if err != nil {
		return PriceList{}, fmt.Errorf("decoding %s: %w", PriceListURL, err)
	}
	return pl.filtered(), nil
}
