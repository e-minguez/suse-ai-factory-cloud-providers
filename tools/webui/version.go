package main

import (
	_ "embed"
	"strings"
)

// Web UI release, independent of the repository version while it is alpha.
//
//go:embed VERSION
var versionFile string

func version() string { return strings.TrimSpace(versionFile) }
