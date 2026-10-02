package pricing

import (
	"fmt"
	"strconv"
	"strings"
)

// Duration names one report column: a label as typed on the CLI ("1h", "7d")
// and the number of hours it represents.
type Duration struct {
	Label string
	Hours float64
}

// DefaultDurations is the CLI's default --durations value: 1h,8h,24h,7d,30d.
var DefaultDurations = []Duration{
	{Label: "1h", Hours: 1},
	{Label: "8h", Hours: 8},
	{Label: "24h", Hours: 24},
	{Label: "7d", Hours: 7 * 24},
	{Label: "30d", Hours: 30 * 24},
}

// ParseDurations parses a comma-separated --durations value like
// "1h,8h,24h,7d,30d". Only "h" (hours) and "d" (days) suffixes are
// supported -- the two units every duration in the plan uses.
func ParseDurations(spec string) ([]Duration, error) {
	parts := strings.Split(spec, ",")
	out := make([]Duration, 0, len(parts))
	for _, raw := range parts {
		p := strings.TrimSpace(raw)
		if p == "" {
			continue
		}
		if len(p) < 2 {
			return nil, fmt.Errorf("invalid duration %q: expected e.g. \"1h\" or \"7d\"", p)
		}
		unit := p[len(p)-1:]
		numPart := p[:len(p)-1]
		n, err := strconv.ParseFloat(numPart, 64)
		if err != nil || n <= 0 {
			return nil, fmt.Errorf("invalid duration %q: expected e.g. \"1h\" or \"7d\"", p)
		}
		var hours float64
		switch unit {
		case "h":
			hours = n
		case "d":
			hours = n * 24
		default:
			return nil, fmt.Errorf("invalid duration %q: unit must be h or d", p)
		}
		out = append(out, Duration{Label: p, Hours: hours})
	}
	if len(out) == 0 {
		return nil, fmt.Errorf("--durations must name at least one duration")
	}
	return out, nil
}
