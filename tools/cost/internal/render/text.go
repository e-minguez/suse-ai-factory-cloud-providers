package render

import (
	"fmt"
	"io"
	"math"
	"text/tabwriter"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

// Text renders r as a table: one row per resource in Expand order, a TOTAL
// row (steady state), a build-only subtotal row when any resource is
// build-only, and footnotes. The disclaimer is the first and last line.
func Text(w io.Writer, r Report) error {
	res := r.Result
	cur := res.Currency

	catalogDesc := res.Catalog.Source
	if res.Catalog.AsOf != "" {
		catalogDesc += " (" + res.Catalog.AsOf + ")"
	}
	if res.Catalog.Age != "" {
		catalogDesc += " " + res.Catalog.Age
	}
	fmt.Fprintln(w, pricing.Disclaimer)
	fmt.Fprintf(w, "Provider: %s   Region: %s   Cluster: %s   Catalog: %s\n\n", r.Provider, r.Region, r.Cluster, catalogDesc)

	tw := tabwriter.NewWriter(w, 0, 4, 2, ' ', tabwriter.AlignRight)

	// AlignRight is per writer, not per column. Left-aligned text columns are
	// pre-padded to a common width so right alignment is a no-op for them.
	labels := make([]string, len(res.Items))
	labelW, roleW, poolW, typeW := len("RESOURCE"), len("ROLE"), len("POOL"), len("TYPE")
	for i, item := range res.Items {
		labels[i] = resourceLabel(item)
		labelW = max(labelW, len(labels[i]))
		roleW = max(roleW, len(item.Resource.Role))
		poolW = max(poolW, len(item.Resource.Pool))
		typeW = max(typeW, len(typeCell(item)))
	}
	row := func(label, role, pool, qty, typ, hourly string) {
		fmt.Fprintf(tw, "%-*s\t%-*s\t%-*s\t%s\t%-*s\t%s", labelW, label, roleW, role, poolW, pool, qty, typeW, typ, hourly)
	}

	row("RESOURCE", "ROLE", "POOL", "QTY", "TYPE", cur+"/hr")
	for _, d := range r.Durations {
		fmt.Fprintf(tw, "\t%s", d.Label)
	}
	// tabwriter terminates cells with a tab: without a trailing one the last
	// column runs into the next line.
	fmt.Fprint(tw, "\t\n")

	anyCapped := false
	for i, item := range res.Items {
		row(labels[i], item.Resource.Role, item.Resource.Pool, qtyCell(item), typeCell(item), hourlyCell(item))
		for _, d := range r.Durations {
			cell, capped := costCell(item, d)
			anyCapped = anyCapped || capped
			fmt.Fprintf(tw, "\t%s", cell)
		}
		fmt.Fprint(tw, "\t\n")
	}

	totalRow := func(name string, totals map[string]pricing.Micros) {
		row("", "", "", "", "", name)
		for _, d := range r.Durations {
			fmt.Fprintf(tw, "\t%s", formatMoney(totals[d.Label]))
		}
		fmt.Fprint(tw, "\t\n")
	}
	totalRow("TOTAL", res.Totals)
	if res.HasBuildOnly {
		totalRow("BUILD-ONLY", res.BuildOnlyTotals)
	}
	if err := tw.Flush(); err != nil {
		return err
	}

	fmt.Fprintln(w)
	fmt.Fprintf(w, "  All amounts in %s.\n", cur)
	if anyCapped {
		fmt.Fprintln(w, "  *  capped at the monthly rate")
	}
	if res.HasBuildOnly {
		fmt.Fprintln(w, "  (build only) rows exist only while the image is built; BUILD-ONLY is not part of TOTAL.")
	}
	if res.RecurringAfterDestroy > 0 {
		fmt.Fprintf(w, "  %s %s/month keeps billing after `terraform destroy`.\n", formatMoney(res.RecurringAfterDestroy), cur)
	}
	for _, n := range res.Notes {
		fmt.Fprintf(w, "  %s\n", n)
	}
	if len(res.Excluded) > 0 {
		fmt.Fprintln(w, "  Not included:")
		for _, e := range res.Excluded {
			fmt.Fprintf(w, "    - %s: %s\n", e.Label, e.Reason)
		}
	}
	if res.Incomplete {
		fmt.Fprintln(w, "  TOTAL is a floor, not a full total: at least one rate was not found in the catalog (--allow-unknown-plans).")
	}
	for _, warn := range res.AllWarnings() {
		fmt.Fprintf(w, "  warning: %s\n", warn)
	}
	fmt.Fprintln(w)
	fmt.Fprintln(w, pricing.Disclaimer)
	return nil
}

// formatMoney renders m to two decimals with integer arithmetic (a float64
// can round the half-cent boundary the wrong way). A nonzero amount below
// 0.01 renders as "<0.01" rather than a misleading 0.00.
func formatMoney(m pricing.Micros) string {
	if m > 0 && m < 5_000 {
		return "<0.01"
	}
	return formatFixed(roundToUnit(int64(m), 10_000), 100)
}

// formatRate renders m to four decimals, enough for published hourly rates.
func formatRate(m pricing.Micros) string {
	return formatFixed(roundToUnit(int64(m), 100), 10_000)
}

// roundToUnit divides v by unit, rounding half away from zero.
func roundToUnit(v, unit int64) int64 {
	if v < 0 {
		return -roundToUnit(-v, unit)
	}
	return (v + unit/2) / unit
}

// formatFixed renders whole as a fixed-point decimal with log10(scale)
// digits, e.g. formatFixed(153, 100) is "1.53".
func formatFixed(whole, scale int64) string {
	sign := ""
	if whole < 0 {
		sign = "-"
		whole = -whole
	}
	digits := len(fmt.Sprintf("%d", scale)) - 1
	return fmt.Sprintf("%s%d.%0*d", sign, whole/scale, digits, whole%scale)
}

func resourceLabel(item pricing.LineItem) string {
	label := item.Resource.Label
	if item.Resource.Kind == pricing.KindStorage {
		label = fmt.Sprintf("%s (%s)", label, formatGB(item.Resource.SizeGB))
	}
	if item.Resource.BuildOnly {
		label += " (build only)"
	}
	return label
}

func formatGB(gb float64) string {
	if gb == math.Trunc(gb) {
		return fmt.Sprintf("%d GB", int64(gb))
	}
	return fmt.Sprintf("%.1f GB", gb)
}

func qtyCell(item pricing.LineItem) string {
	if item.Resource.Kind == pricing.KindFree {
		return ""
	}
	return fmt.Sprintf("%d", item.Resource.Qty)
}

func typeCell(item pricing.LineItem) string {
	if item.Resource.Kind == pricing.KindFree {
		return "-- free --"
	}
	return item.Resource.RateID + notFound(item)
}

func notFound(item pricing.LineItem) string {
	if item.Found {
		return ""
	}
	return " (unknown)"
}

// hourlyCell is the per-unit hourly rate; storage is per GB-hour.
func hourlyCell(item pricing.LineItem) string {
	k := item.Resource.Kind
	if k == pricing.KindFree || item.Resource.Qty == 0 || !item.Found {
		return "--"
	}
	if k == pricing.KindStorage {
		return formatFixed(roundToUnit(int64(item.Hourly), 1), 1_000_000) + "/GB"
	}
	return formatRate(item.Hourly)
}

func costCell(item pricing.LineItem, d pricing.Duration) (string, bool) {
	if item.Resource.Kind == pricing.KindFree || item.Resource.Qty == 0 {
		return "--", false
	}
	capped := item.Capped[d.Label]
	s := formatMoney(item.Costs[d.Label])
	if capped {
		s += " *"
	}
	return s, capped
}
