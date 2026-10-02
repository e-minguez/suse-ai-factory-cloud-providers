package pricing

// Disclaimer is the mandatory wording of every output: the first line and
// last line of the text report and the top-level "disclaimer" JSON field.
const Disclaimer = "ESTIMATE ONLY — a helper for rough guidance, not a quote. " +
	"For real numbers contact the provider or do your own math."

// HoursPerMonth is the month length used to prorate monthly rates and to
// split a duration into whole months for MonthlyCap.
const HoursPerMonth = 730.0

// Kind says how a Resource is priced.
type Kind int

const (
	// KindCompute is a billable instance priced from the catalog plan RateID.
	KindCompute Kind = iota
	// KindStorage is SizeGB of storage priced from the catalog plan RateID
	// (see Plan.Hourly and Plan.GBMonthly).
	KindStorage
	// KindFixed is any other catalog rate (load balancer, NAT, public IP),
	// priced per unit like a compute plan under a synthetic RateID.
	KindFixed
	// KindFree is always zero but still a row, so the reader sees it was
	// considered.
	KindFree
)

// String is the JSON/text name of the kind.
func (k Kind) String() string {
	switch k {
	case KindCompute:
		return "compute"
	case KindStorage:
		return "storage"
	case KindFixed:
		return "fixed"
	}
	return "free"
}

// Resource is one row of the report: a billable (or deliberately free) thing
// a deployment creates, before any catalog lookup.
type Resource struct {
	Kind  Kind
	Label string // e.g. "control plane"
	Role  string // label vocabulary of docs/conventions.md#labels; "" if none
	Pool  string // pool key, "cp" for control planes; "" when not pool-based

	RateID string  // catalog plan ID; empty for KindFree
	Qty    int     // rows with 0 are dropped before pricing (see dropZeroQty in main.go)
	SizeGB float64 // KindStorage only

	// SurvivesDestroy marks resources `terraform destroy` does not remove;
	// their monthly cost is reported as an ongoing charge.
	SurvivesDestroy bool
	// BuildOnly marks resources that exist only while the image is built.
	// They go into the build-only subtotal, never the steady-state total.
	BuildOnly bool
}

// Excluded is a cost the estimate leaves out, with the reason, shown in the
// report footer.
type Excluded struct {
	Label  string
	Reason string
}
