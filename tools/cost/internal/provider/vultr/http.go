package vultr

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

// Both endpoints are public and unauthenticated -- no VULTR_API_KEY needed --
// which is the entire point of pricing a cluster before it exists. See the
// README.
const (
	PlansURL      = "https://api.vultr.com/v2/plans?per_page=500"
	PlansMetalURL = "https://api.vultr.com/v2/plans-metal?per_page=100"
)

// plansFile is the shape of both live endpoints combined, and of a --plans
// override file: "plans" is GET /v2/plans' top-level key, "plans_metal" is
// GET /v2/plans-metal's. A file needs only the key(s) it has data for; the
// other decodes as empty.
type plansFile struct {
	Plans      []rawPlan `json:"plans"`
	PlansMetal []rawPlan `json:"plans_metal"`
}

func decodePlansFile(r io.Reader) (MapCatalog, error) {
	dec := json.NewDecoder(r)
	dec.UseNumber()
	var pf plansFile
	if err := dec.Decode(&pf); err != nil {
		return nil, err
	}
	out := make(MapCatalog, len(pf.Plans)+len(pf.PlansMetal))
	for _, raw := range pf.Plans {
		p, err := raw.toPlan()
		if err != nil {
			return nil, err
		}
		out[p.ID] = p
	}
	for _, raw := range pf.PlansMetal {
		p, err := raw.toPlan()
		if err != nil {
			return nil, err
		}
		out[p.ID] = p
	}
	return out, nil
}

// LoadPlansFile decodes a --plans override file: either endpoint's raw JSON
// body, or both merged under "plans"/"plans_metal".
func LoadPlansFile(path string) (MapCatalog, error) {
	f, err := os.Open(path)
	if err != nil {
		return nil, err
	}
	defer f.Close()
	return decodePlansFile(f)
}

// FetchLive fetches both catalog endpoints over HTTP.
func FetchLive(ctx context.Context, client *http.Client, timeout time.Duration) (MapCatalog, error) {
	if client == nil {
		client = http.DefaultClient
	}
	ctx, cancel := context.WithTimeout(ctx, timeout)
	defer cancel()

	cloud, err := fetchOne(ctx, client, PlansURL)
	if err != nil {
		return nil, fmt.Errorf("fetching %s: %w", PlansURL, err)
	}
	metal, err := fetchOne(ctx, client, PlansMetalURL)
	if err != nil {
		return nil, fmt.Errorf("fetching %s: %w", PlansMetalURL, err)
	}
	return cloud.Merge(metal), nil
}

func fetchOne(ctx context.Context, client *http.Client, url string) (MapCatalog, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return nil, err
	}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("HTTP %d", resp.StatusCode)
	}
	return decodePlansFile(resp.Body)
}
