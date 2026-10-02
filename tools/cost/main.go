// Command cost estimates, from tfvars alone, what a deployment of this repo
// will cost on aws, evroc or vultr. Nothing is deployed or discovered. See
// tools/cost/README.md and the provider packages under internal/provider.
package main

import (
	"context"
	"flag"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider"
	_ "github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider/all"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/render"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/tfconfig"
)

// Exit codes: 0 success, 2 a config problem (flags, tfvars, variables), 3 a
// pricing problem (catalog unavailable, or a rate missing at qty >= 1).
const (
	exitOK     = 0
	exitConfig = 2
	exitPrice  = 3
)

const commonVariables = "modules/common/variables-common.tf"

// varFiles collects the repeatable --var-file flag.
type varFiles []string

func (v *varFiles) String() string     { return strings.Join(*v, ",") }
func (v *varFiles) Set(s string) error { *v = append(*v, s); return nil }

func main() {
	os.Exit(run(os.Args[1:], os.Stdout, os.Stderr))
}

func run(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("cost", flag.ContinueOnError)
	fs.SetOutput(stderr)
	fs.Usage = func() {
		fmt.Fprintln(stderr, "usage: cost --provider NAME [flags]")
		fs.PrintDefaults()
	}

	var vfiles varFiles
	providerName := fs.String("provider", "", "provider to price: "+strings.Join(provider.Names(), ", ")+" (required)")
	fs.Var(&vfiles, "var-file", "tfvars file; repeatable, later files win (same order as deploy.sh layering)")
	regionFlag := fs.String("region", "", "override the region")
	jsonOut := fs.Bool("json", false, "print a JSON report instead of a table")
	catalogFile := fs.String("catalog", "", "provider catalog file to use instead of the network or cache")
	noNetwork := fs.Bool("no-network", false, "never call the network; use --catalog or a warm cache")
	allowUnknown := fs.Bool("allow-unknown-plans", false, "price a rate missing from the catalog as 0 with a warning, instead of failing")
	durationsFlag := fs.String("durations", "1h,8h,24h,7d,30d", "comma-separated durations to price (h and d units)")
	repo := fs.String("repo", "", "repository root (default: walk up from the working directory)")

	if err := fs.Parse(args); err != nil {
		return exitConfig
	}
	if fs.NArg() != 0 || *providerName == "" {
		fs.Usage()
		return exitConfig
	}

	prov, err := provider.Get(*providerName)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitConfig
	}
	durations, err := pricing.ParseDurations(*durationsFlag)
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitConfig
	}

	root := *repo
	if root == "" {
		if root, err = findRepo(); err != nil {
			fmt.Fprintln(stderr, err)
			return exitConfig
		}
	}
	commonPath := filepath.Join(root, commonVariables)
	providerPath := filepath.Join(root, "modules", prov.Name(), "variables.tf")
	decls, hclDiags := tfconfig.ParseVariables(commonPath, providerPath)
	if hclDiags.HasErrors() {
		for _, d := range tfconfig.FromHCLDiagnostics(hclDiags) {
			fmt.Fprintln(stderr, d.Format())
		}
		return exitConfig
	}

	// Detail is dropped from any diagnostic located in a tfvars file: HCL
	// syntax errors can echo part of the offending token, a credential.
	tfvars, hclDiags := tfconfig.ParseTFVarsLayered(vfiles)
	diags := tfconfig.FromHCLDiagnostics(hclDiags, vfiles...)
	if hclDiags.HasErrors() {
		printDiags(stderr, diags)
		return exitConfig
	}

	overrides := map[string]string{}
	if *regionFlag != "" {
		overrides["region"] = *regionFlag
	}
	vars := tfconfig.NewVars(decls, tfvars, overrides)
	common := tfconfig.ResolveCommon(vars)
	cfg, provDiags := prov.Resolve(common, vars)
	diags = append(diags, vars.Diagnostics()...)
	diags = append(diags, provDiags...)
	if tfconfig.HasErrors(diags) {
		printDiags(stderr, diags)
		return exitConfig
	}
	var warnings []string
	for _, d := range diags {
		fmt.Fprintln(stderr, "warning: "+d.Format())
		warnings = append(warnings, d.Format())
	}

	cacheDir, _ := provider.DefaultCacheDir() // "" disables caching
	catalog, err := prov.Catalog(context.Background(), cfg.Common.Region, provider.CatalogOpts{
		File: *catalogFile, NoNetwork: *noNetwork, CacheDir: cacheDir,
	})
	if err != nil {
		fmt.Fprintln(stderr, err)
		return exitPrice
	}

	resources, excluded := prov.Expand(cfg)
	resources, notes := dropZeroQty(resources, cfg.Common.DeployNodes)
	result, priceErr := pricing.Price(resources, catalog, durations, *allowUnknown)
	result.Excluded = excluded
	result.Notes = notes
	result.Warnings = append(result.Warnings, warnings...)
	if priceErr != nil {
		for _, w := range result.AllWarnings() {
			fmt.Fprintln(stderr, "warning: "+w)
		}
		fmt.Fprintln(stderr, priceErr)
		return exitPrice
	}

	report := render.Report{Provider: prov.Name(), Region: cfg.Common.Region, Cluster: cfg.Common.ClusterName, Result: result, Durations: durations}
	renderFn := render.Text
	if *jsonOut {
		renderFn = render.JSON
	}
	if err := renderFn(stdout, report); err != nil {
		fmt.Fprintln(stderr, err)
		return exitPrice
	}
	return exitOK
}

func printDiags(w io.Writer, diags []tfconfig.Diagnostic) {
	for _, d := range diags {
		fmt.Fprintln(w, d.Severity.String()+": "+d.Format())
	}
}

// findRepo walks up from the working directory to the directory holding
// modules/common/variables-common.tf.
func findRepo() (string, error) {
	dir, err := os.Getwd()
	if err != nil {
		return "", err
	}
	for {
		if _, err := os.Stat(filepath.Join(dir, commonVariables)); err == nil {
			return dir, nil
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("could not find %s above the working directory; pass --repo", commonVariables)
		}
		dir = parent
	}
}

// dropZeroQty removes rows with quantity 0 (nodes with deploy_nodes = false,
// pools with count = 0, disabled public IPs) and returns a footer note when
// node rows went.
func dropZeroQty(in []pricing.Resource, deployNodes bool) ([]pricing.Resource, []string) {
	out := make([]pricing.Resource, 0, len(in))
	dropped := false
	for _, r := range in {
		if r.Qty == 0 && r.Kind != pricing.KindFree {
			dropped = dropped || r.Kind == pricing.KindCompute && r.Role != "builder" && r.Role != "jumphost"
			continue
		}
		out = append(out, r)
	}
	if !dropped {
		return out, nil
	}
	if !deployNodes {
		return out, []string{"deploy_nodes = false: node rows omitted."}
	}
	return out, []string{"Node pools with count = 0 omitted."}
}
