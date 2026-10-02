package aws

import (
	"context"
	"encoding/json"
	"os"
	"testing"

	awspricing "github.com/aws/aws-sdk-go-v2/service/pricing"
)

// fakeAPI serves testdata/products.json like the Price List API: ServiceCode
// picks the list, filters match attributes exactly, results come in pages.
type fakeAPI struct {
	items    map[string][]json.RawMessage
	err      error
	pageSize int
	calls    int
}

func newFake(t *testing.T) *fakeAPI {
	t.Helper()
	data, err := os.ReadFile("testdata/products.json")
	if err != nil {
		t.Fatal(err)
	}
	f := &fakeAPI{pageSize: 100}
	if err := json.Unmarshal(data, &f.items); err != nil {
		t.Fatal(err)
	}
	return f
}

func (f *fakeAPI) GetProducts(_ context.Context, in *awspricing.GetProductsInput, _ ...func(*awspricing.Options)) (*awspricing.GetProductsOutput, error) {
	f.calls++
	if f.err != nil {
		return nil, f.err
	}
	var match []string
	for _, raw := range f.items[*in.ServiceCode] {
		var it priceItem
		_ = json.Unmarshal(raw, &it)
		var fam struct {
			Product struct {
				ProductFamily string `json:"productFamily"`
			} `json:"product"`
		}
		_ = json.Unmarshal(raw, &fam)
		it.Product.Attributes["productFamily"] = fam.Product.ProductFamily
		ok := true
		for _, fl := range in.Filters {
			if it.Product.Attributes[*fl.Field] != *fl.Value {
				ok = false
			}
		}
		if ok {
			match = append(match, string(raw))
		}
	}
	start := 0
	if in.NextToken != nil {
		for i := range match {
			if *in.NextToken == string(rune('a'+i)) {
				start = i
			}
		}
	}
	end := min(start+f.pageSize, len(match))
	out := &awspricing.GetProductsOutput{PriceList: match[start:end]}
	if end < len(match) {
		tok := string(rune('a' + end))
		out.NextToken = &tok
	}
	return out, nil
}
