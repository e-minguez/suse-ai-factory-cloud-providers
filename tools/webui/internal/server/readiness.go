package server

import (
	"slices"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/schema"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/workspace"
)

// appcoComponents are pulled from Application Collection; with any of them
// enabled, appco_username and appco_password are required (module validation).
var appcoComponents = []string{"local-path-provisioner", "suse-storage"}

func filled(v any) bool {
	switch t := v.(type) {
	case nil:
		return false
	case string:
		return t != ""
	case []any:
		return len(t) > 0
	}
	return true
}

// missingForDeploy lists the labels of values a plan would reject: required
// variables without a value, and the Application Collection credentials when
// a component needs them. value returns the effective value of a field.
func missingForDeploy(fields []schema.Field, value func(schema.Field) any) []string {
	var out []string
	byName := map[string]schema.Field{}
	for _, f := range fields {
		byName[f.Name] = f
		if f.Required && !filled(value(f)) {
			label := f.Label
			if schema.IsCredential(f.Name) {
				label += " (account profile)"
			}
			out = append(out, label)
		}
	}
	comps, _ := value(byName["components"]).([]any)
	needs := false
	for _, c := range comps {
		if s, ok := c.(string); ok && slices.Contains(appcoComponents, s) {
			needs = true
		}
	}
	if needs {
		for _, n := range []string{"appco_username", "appco_password"} {
			if f, ok := byName[n]; ok && !filled(value(f)) {
				out = append(out, f.Label)
			}
		}
	}
	return out
}

// deployBlockers checks the saved layers (as deploy.sh reads them) before a
// deploy starts. A schema or read error returns nil and leaves it to the plan.
func (s *Server) deployBlockers(c *workspace.Cluster) []string {
	fields, err := schema.Load(s.Cfg.Repo, c.Provider)
	if err != nil {
		return nil
	}
	vars, err := workspace.Vars(s.Cfg.Repo, s.Cfg.ClustersDir(), c.Provider, c.Name)
	if err != nil {
		return nil
	}
	return missingForDeploy(fields, func(f schema.Field) any {
		if v, ok := vars[f.Name]; ok {
			return v
		}
		return f.Default
	})
}
