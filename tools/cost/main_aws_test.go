package main

import (
	"encoding/json"
	"strings"
	"testing"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/pricing"
)

const (
	awsCatalog = "internal/provider/aws/testdata/catalog-us-east-1.json"
	awsExample = "../../examples/aws/terraform.tfvars.example"
)

// TestAwsExampleGolden runs the whole pipeline against the shipped example
// tfvars with a fixture catalog, in text and JSON.
func TestAwsExampleGolden(t *testing.T) {
	base := []string{"--provider", "aws", "--no-network", "--catalog", awsCatalog, "--var-file", awsExample}

	code, out, errOut := exec(base...)
	if code != exitOK {
		t.Fatalf("exit %d: %s", code, errOut)
	}
	lines := strings.Split(strings.TrimSpace(out), "\n")
	if lines[0] != pricing.Disclaimer || lines[len(lines)-1] != pricing.Disclaimer {
		t.Error("the text report must start and end with the disclaimer")
	}
	compareGolden(t, "aws-example.txt", out)

	code, out, errOut = exec(append([]string{"--json"}, base...)...)
	if code != exitOK {
		t.Fatalf("json: exit %d: %s", code, errOut)
	}
	var doc struct {
		Disclaimer string `json:"disclaimer"`
		Currency   string `json:"currency"`
	}
	if err := json.Unmarshal([]byte(out), &doc); err != nil || doc.Disclaimer != pricing.Disclaimer || doc.Currency != "USD" {
		t.Errorf("JSON disclaimer/currency wrong: %+v, %v", doc, err)
	}
	compareGolden(t, "aws-example.json", out)
}

func TestAwsMissingRegionExitsConfig(t *testing.T) {
	code, _, errOut := exec("--provider", "aws", "--no-network", "--catalog", awsCatalog)
	if code != exitConfig || !strings.Contains(errOut, "--region") {
		t.Errorf("exit %d, stderr %q; want exit 2 mentioning --region", code, errOut)
	}
}

func TestAwsCatalogRegionMismatchExitsPricing(t *testing.T) {
	code, _, errOut := exec("--provider", "aws", "--region", "eu-west-1", "--no-network", "--catalog", awsCatalog, "--var-file", awsExample)
	if code != exitPrice || !strings.Contains(errOut, "us-east-1") {
		t.Errorf("exit %d, stderr %q; want exit 3 naming the catalog region", code, errOut)
	}
}
