package pricing

// Plan is one catalog rate. A rate the provider quotes monthly only is
// converted by the catalog, not here.
//
// Compute and fixed plans use Hourly (per unit-hour). Storage plans use
// Hourly per GB-hour or GBMonthly per GB-month (set one).
type Plan struct {
	ID         string
	Hourly     Micros  // per unit-hour (per GB-hour for storage)
	GBMonthly  Micros  // storage only: per GB-month
	MonthlyCap Micros  // billed ceiling per month; 0 = none
	MinHours   float64 // minimum billed duration in hours; 0 = none
}

// CatalogInfo says where a catalog came from, for the report header.
type CatalogInfo struct {
	Source string // "api", "cache", "file", "ratecard"
	AsOf   string // RFC3339 or YYYY-MM-DD; "" if unknown
	Age    string // staleness note, e.g. "(3h old, network unavailable)"; "" when fresh
}

// Catalog resolves rate IDs to plans. Synthetic IDs for non-instance rates:
// "lb", "nat-gateway", "public-ipv4", "storage:snapshot", "storage:disk".
// Providers may add more; nothing is hardcoded in this package.
type Catalog interface {
	// Lookup returns the plan and whether it exists. It never errors: the
	// caller reports unknown IDs with context.
	Lookup(id string) (Plan, bool)
	// Currency is the ISO code every rate is quoted in, e.g. "USD".
	Currency() string
	Info() CatalogInfo
}

// StaticCatalog is a Catalog backed by a map; the concrete type providers
// and tests build.
type StaticCatalog struct {
	Cur   string
	Meta  CatalogInfo
	Plans map[string]Plan
}

// Lookup implements Catalog.
func (c StaticCatalog) Lookup(id string) (Plan, bool) { p, ok := c.Plans[id]; return p, ok }

// Currency implements Catalog.
func (c StaticCatalog) Currency() string { return c.Cur }

// Info implements Catalog.
func (c StaticCatalog) Info() CatalogInfo { return c.Meta }
