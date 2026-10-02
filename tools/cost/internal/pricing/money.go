// Package pricing is provider-neutral: it prices a list of Resources against
// a Catalog of rates for any number of durations. It knows no provider, rate
// or currency; those come from the Catalog.
package pricing

import (
	"encoding/json"
	"fmt"
	"math/big"
)

// Micros is an amount of money in millionths of the catalog currency's major
// unit (1_000_000 = 1.00), stored as int64. Rates are parsed through
// ParseMicros (json.Number -> big.Rat) rather than float64, so e.g. "0.153"
// is exactly 153000 and golden files do not flap.
type Micros int64

// Major renders the amount as a float64 in the currency's major unit. Used
// only by the JSON renderer; all arithmetic here stays integer.
func (m Micros) Major() float64 {
	return float64(m) / 1_000_000
}

// ParseMicros converts a JSON number (decoded via json.Number, never
// float64) to whole millionths, rounding half up.
func ParseMicros(n json.Number) (Micros, error) {
	s := n.String()
	if s == "" {
		s = "0"
	}
	r, ok := new(big.Rat).SetString(s)
	if !ok {
		return 0, fmt.Errorf("not a decimal number: %q", s)
	}
	r.Mul(r, big.NewRat(1_000_000, 1))
	r.Add(r, big.NewRat(1, 2)) // every input here is non-negative
	q := new(big.Int).Quo(r.Num(), r.Denom())
	return Micros(q.Int64()), nil
}
