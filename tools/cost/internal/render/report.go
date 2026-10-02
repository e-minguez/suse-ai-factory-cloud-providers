// Package render turns a priced Result into the CLI's two output formats: a
// text table (text.go) and a self-contained JSON document (json.go). Both
// carry pricing.Disclaimer.
package render

import "github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"

// Report is everything a renderer needs.
type Report struct {
	Provider  string
	Region    string
	Cluster   string
	Result    pricing.Result
	Durations []pricing.Duration
}
