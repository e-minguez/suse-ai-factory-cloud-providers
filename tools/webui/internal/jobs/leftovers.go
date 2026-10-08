package jobs

import (
	"os"
	"os/exec"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

// leftoverTools are the commands tools/leftovers/<provider>.sh needs on PATH.
var leftoverTools = map[string][]string{
	"aws":      {"aws"},
	"evroc":    {"evroc", "jq"},
	"exoscale": {"curl", "jq", "openssl"},
	"vultr":    {"curl", "jq"},
}

// MissingToolError is returned when the leftovers script cannot run here.
type MissingToolError struct{ Tools []string }

func (e *MissingToolError) Error() string {
	return "needs " + strings.Join(e.Tools, ", ") + ", not found in PATH"
}

// LeftoversMissing lists the commands the provider's leftovers script needs
// that are not on PATH.
func LeftoversMissing(provider string) []string {
	var out []string
	for _, t := range leftoverTools[provider] {
		if _, err := exec.LookPath(t); err != nil {
			out = append(out, t)
		}
	}
	return out
}

// Command is the read-only command line to run the leftovers check by hand
// (no secrets: credentials come from the caller's environment).
func (l Leftovers) Command(provider string) string {
	parts := []string{"tools/leftovers/" + provider + ".sh"}
	for _, a := range l.Args {
		parts = append(parts, "'"+strings.ReplaceAll(a, "'", `'\''`)+"'")
	}
	return strings.Join(parts, " ")
}

// Leftovers describes one tools/leftovers/<provider>.sh invocation.
type Leftovers struct {
	Args []string // after the script: <cluster_name> [--region R] [--project P]
	Env  []string // credentials from the tfvars layers (never printed)
}

// LeftoverSpec mirrors deploy_after_destroy in examples/<p>/deploy.sh:
//
//	aws       <cluster_name> --region <region>   (region: tfvars, else AWS_REGION; AWS_* creds via creds.Env)
//	evroc     <cluster_name> [--region R] [--project P]
//	exoscale  <cluster_name> [--region R]        + EXOSCALE_API_KEY/SECRET from exoscale_api_key/secret
//	vultr     <cluster_name>                     + VULTR_API_KEY from vultr_api_key
//
// The repo-root common-all.tfvars is the lowest layer, as in deploy.sh.
// cluster_name defaults to "suse-ai-factory" as in deploy.sh.
func LeftoverSpec(repo, clustersDir, provider, cluster string) Leftovers {
	all, _ := workspace.Vars(repo, clustersDir, provider, cluster) // layers deploy.sh reads, repo root first
	vars := map[string]string{}
	for k, v := range all {
		if str, ok := v.(string); ok {
			vars[k] = str
		}
	}
	name := vars["cluster_name"]
	if name == "" {
		name = "suse-ai-factory"
	}
	l := Leftovers{Args: []string{name}}
	region := func() {
		if vars["region"] != "" {
			l.Args = append(l.Args, "--region", vars["region"])
		}
	}
	switch provider {
	case "aws":
		r := vars["region"]
		if r == "" {
			r = os.Getenv("AWS_REGION")
		}
		if r == "" {
			r = os.Getenv("AWS_DEFAULT_REGION")
		}
		if r != "" {
			l.Args = append(l.Args, "--region", r)
		}
	case "evroc":
		region()
		if vars["project"] != "" {
			l.Args = append(l.Args, "--project", vars["project"])
		}
	case "exoscale":
		region()
		if vars["exoscale_api_key"] != "" {
			l.Env = append(l.Env, "EXOSCALE_API_KEY="+vars["exoscale_api_key"])
		}
		if vars["exoscale_api_secret"] != "" {
			l.Env = append(l.Env, "EXOSCALE_API_SECRET="+vars["exoscale_api_secret"])
		}
	case "vultr":
		if vars["vultr_api_key"] != "" {
			l.Env = append(l.Env, "VULTR_API_KEY="+vars["vultr_api_key"])
		}
	}
	return l
}
