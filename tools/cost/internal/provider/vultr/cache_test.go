package vultr

import (
	"path/filepath"
	"testing"
	"time"
)

func TestCacheRoundTrip(t *testing.T) {
	catalog, err := LoadPlansFile("testdata/plans.json")
	if err != nil {
		t.Fatalf("LoadPlansFile: %v", err)
	}

	path := filepath.Join(t.TempDir(), "plans.json")
	fetchedAt := time.Date(2026, 9, 18, 10, 0, 0, 0, time.UTC)
	if err := SaveCache(path, catalog, fetchedAt); err != nil {
		t.Fatalf("SaveCache: %v", err)
	}

	got, gotFetchedAt, err := LoadCache(path)
	if err != nil {
		t.Fatalf("LoadCache: %v", err)
	}
	if !gotFetchedAt.Equal(fetchedAt) {
		t.Errorf("FetchedAt = %v, want %v", gotFetchedAt, fetchedAt)
	}
	if len(got) != len(catalog) {
		t.Fatalf("cache has %d plans, want %d", len(got), len(catalog))
	}
	for id, want := range catalog {
		p, ok := got[id]
		if !ok {
			t.Errorf("cache missing plan %q", id)
			continue
		}
		if p.HourlyMicros != want.HourlyMicros || p.MonthlyMicros != want.MonthlyMicros || p.InvoiceType != want.InvoiceType {
			t.Errorf("cache plan %q = %+v, want %+v", id, p, want)
		}
	}
}
