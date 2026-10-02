package vultr

import (
	"encoding/json"
	"fmt"
	"os"

	"path/filepath"
	"time"
)

// cacheFile is the on-disk shape of the warm cache: a fetch timestamp plus
// the already-decoded (Micros, not json.Number) catalog, so a cache read
// never needs to re-parse the API's own JSON shape.
type cacheFile struct {
	FetchedAt time.Time  `json:"fetched_at"`
	Plans     MapCatalog `json:"plans"`
}

// cachePath is the plan cache file inside dir.
func cachePath(dir string) string { return filepath.Join(dir, "vultr-plans.json") }

// LoadCache reads a previously saved catalog and the time it was fetched.
func LoadCache(path string) (MapCatalog, time.Time, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, time.Time{}, err
	}
	var cf cacheFile
	if err := json.Unmarshal(data, &cf); err != nil {
		return nil, time.Time{}, fmt.Errorf("parsing cache %s: %w", path, err)
	}
	return cf.Plans, cf.FetchedAt, nil
}

// SaveCache persists catalog as the warm cache, for use the next time a live
// fetch fails. Best-effort: callers should treat a save failure as a warning,
// never as a reason to fail an otherwise-successful run.
func SaveCache(path string, catalog MapCatalog, fetchedAt time.Time) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	data, err := json.Marshal(cacheFile{FetchedAt: fetchedAt, Plans: catalog})
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}
