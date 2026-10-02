// Package tfconfig parses a module's variables.tf and a caller's tfvars, and
// resolves the two into the narrow tfconfig.Config the pricing package
// consumes. See resolve.go's package comment for the security rationale.
package tfconfig

import (
	"fmt"
	"slices"

	"github.com/hashicorp/hcl/v2"
)

// Severity mirrors hcl.DiagnosticSeverity's two levels. Kept as our own type,
// not hcl.DiagnosticSeverity, so nothing downstream is tempted to hand a
// Diagnostic to hcl.NewDiagnosticTextWriter -- which prints the offending
// source line, and the offending source in a tfvars can be a credential.
type Severity int

const (
	SeverityWarning Severity = iota
	SeverityError
)

func (s Severity) String() string {
	if s == SeverityError {
		return "error"
	}
	return "warning"
}

// Diagnostic is this package's own diagnostic type. It deliberately has no
// Detail field: hcl.Diagnostic's Detail is free-form prose that upstream
// sometimes composes by echoing part of the offending expression or value,
// and Summary is built by this package's own code, which never interpolates
// a resolved value into a message (see resolve.go). Format prints only
// "file:line:col: Summary" -- never a source snippet.
type Diagnostic struct {
	Severity Severity
	Summary  string
	Subject  *hcl.Range // nil when not tied to a specific source location
}

func (d Diagnostic) Error() string { return d.Format() }

// Format renders "file:line:col: Summary", or just "Summary" when there is
// no source location (e.g. a diagnostic about a flag, not a file).
func (d Diagnostic) Format() string {
	if d.Subject != nil {
		return fmt.Sprintf("%s:%d:%d: %s", d.Subject.Filename, d.Subject.Start.Line, d.Subject.Start.Column, d.Summary)
	}
	return d.Summary
}

// FromHCLDiagnostics converts hcl.Diagnostics -- produced only while parsing,
// e.g. a syntax error -- into our own type. Detail is appended to Summary
// UNLESS the diagnostic's Subject falls inside one of redactPaths (the tfvars files),
// in which case Detail is dropped outright: hcl's own parser diagnostics can
// and do include fragments of the offending token (e.g. an unterminated
// string's content so far), and that token in a tfvars can be a credential.
// variables.tf carries no secrets, so its diagnostics keep their Detail,
// which is usually the only useful part of an HCL syntax error.
func FromHCLDiagnostics(diags hcl.Diagnostics, redactPaths ...string) []Diagnostic {
	out := make([]Diagnostic, 0, len(diags))
	for _, d := range diags {
		sev := SeverityWarning
		if d.Severity == hcl.DiagError {
			sev = SeverityError
		}
		summary := d.Summary
		redact := d.Subject != nil && slices.Contains(redactPaths, d.Subject.Filename)
		if !redact && d.Detail != "" {
			summary = summary + ": " + d.Detail
		}
		out = append(out, Diagnostic{Severity: sev, Summary: summary, Subject: d.Subject})
	}
	return out
}

// HasErrors reports whether any diagnostic in the slice is an error.
func HasErrors(diags []Diagnostic) bool {
	for _, d := range diags {
		if d.Severity == SeverityError {
			return true
		}
	}
	return false
}
