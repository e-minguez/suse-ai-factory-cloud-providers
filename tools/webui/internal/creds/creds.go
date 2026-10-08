// Package creds stores cloud credentials on the shared volume and returns
// the environment child processes need to find them. Values are never
// returned, only whether they are set.
package creds

import (
	"bufio"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"gopkg.in/yaml.v3"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/schema"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/tfvars"
)

// ErrUnknown is returned for providers without credential storage.
var ErrUnknown = errors.New("unknown provider")

// evroc: the Terraform provider only reads ~/.evroc/config.yaml, so the
// file lives under <clusters>/.home/.evroc (HOME of children, see HomeDir).
const evrocRel = ".home/.evroc/config.yaml"

func field(name, label, help string, sensitive bool) schema.Field {
	return schema.Field{
		Name: name, Type: "string", Description: help, Sensitive: sensitive,
		Required: true, Widget: "password", Label: label, Help: help,
	}
}

// Fields lists the credential inputs of a provider.
func Fields(p string) []schema.Field {
	switch p {
	case "aws":
		return []schema.Field{
			field("access_key_id", "Access key ID", "AWS_ACCESS_KEY_ID of the IAM user.", true),
			field("secret_access_key", "Secret access key", "AWS_SECRET_ACCESS_KEY of the IAM user.", true),
			field("session_token", "Session token (optional)", "Only for temporary credentials.", true),
		}
	case "evroc":
		f := field("config", "evroc config file", "Content of ~/.evroc/config.yaml written by `evroc login`.", true)
		f.Widget = "text"
		return []schema.Field{f}
	case "vultr":
		return []schema.Field{field("vultr_api_key", "API key", "Vultr API key.", true)}
	case "exoscale":
		return []schema.Field{
			field("exoscale_api_key", "API key", "Exoscale IAM API key.", true),
			field("exoscale_api_secret", "API secret", "Secret of the API key.", true),
		}
	}
	return nil
}

func awsDir(c string) string  { return filepath.Join(c, ".aws") }
func awsCred(c string) string { return filepath.Join(awsDir(c), "credentials") }

// Status reports, per field name, whether a value is stored.
func Status(clustersDir, p string) (map[string]bool, error) {
	out := map[string]bool{}
	for _, f := range Fields(p) {
		out[f.Name] = false
	}
	switch p {
	case "aws":
		vals, err := readAWS(clustersDir)
		if err != nil {
			return nil, err
		}
		for k := range out {
			out[k] = vals[k] != ""
		}
	case "evroc":
		b, err := os.ReadFile(filepath.Join(clustersDir, evrocRel))
		if err != nil && !os.IsNotExist(err) {
			return nil, err
		}
		out["config"] = len(strings.TrimSpace(string(b))) > 0
	case "vultr", "exoscale":
		vals, err := tfvars.Read(tfvars.Path(clustersDir, p, "", tfvars.LayerCommonProvider))
		if err != nil {
			return nil, err
		}
		for k := range out {
			s, _ := vals[k].(string)
			out[k] = s != ""
		}
	default:
		return nil, ErrUnknown
	}
	return out, nil
}

// Save stores values; an empty value keeps the existing one.
func Save(clustersDir, p string, values map[string]string) error {
	switch p {
	case "aws":
		return saveAWS(clustersDir, values)
	case "evroc":
		cfg := strings.TrimSpace(values["config"])
		if cfg == "" {
			return nil
		}
		if err := checkEvrocConfig(cfg); err != nil {
			return err
		}
		return writeFile(filepath.Join(clustersDir, evrocRel), []byte(cfg+"\n"))
	case "vultr", "exoscale":
		set := map[string]any{}
		for _, f := range Fields(p) {
			if v := strings.TrimSpace(values[f.Name]); v != "" {
				set[f.Name] = v
			}
		}
		if len(set) == 0 {
			return nil
		}
		return tfvars.Write(tfvars.Path(clustersDir, p, "", tfvars.LayerCommonProvider), set, nil)
	}
	return ErrUnknown
}

// HomeDir is the HOME of every child process: <clusters>/.home.
func HomeDir(clustersDir string) string { return filepath.Join(clustersDir, ".home") }

// EnsureHome creates HomeDir and its .ssh with mode 700.
func EnsureHome(clustersDir string) error {
	h := HomeDir(clustersDir)
	for _, d := range []string{h, filepath.Join(h, ".ssh")} {
		if err := os.MkdirAll(d, 0o700); err != nil {
			return err
		}
		if err := os.Chmod(d, 0o700); err != nil {
			return err
		}
	}
	return nil
}

// Env returns environment additions for child processes. HOME is set by
// the job runner (HomeDir), not here.
func Env(clustersDir, p string) []string {
	switch p {
	case "aws":
		var env []string
		if cred := awsCred(clustersDir); exists(cred) {
			env = append(env, "AWS_SHARED_CREDENTIALS_FILE="+cred, "AWS_PROFILE=default")
		}
		if cfg := filepath.Join(awsDir(clustersDir), "config"); exists(cfg) {
			env = append(env, "AWS_CONFIG_FILE="+cfg)
		}
		return env
	case "evroc":
		// Nothing: the provider and the CLI read $HOME/.evroc/config.yaml (CLI
		// format); EVROC_CONFIG_FILE would make the provider expect the SDK format.
		return nil
	}
	return nil
}

var secretKeyRe = regexp.MustCompile(`(?i)token|secret|key|password`)

// SecretValues returns the stored secret values of a provider for output
// redaction. Callers must never log or display them.
func SecretValues(clustersDir, p string) ([]string, error) {
	var out []string
	switch p {
	case "aws":
		vals, err := readAWS(clustersDir)
		if err != nil {
			return nil, err
		}
		for _, k := range []string{"access_key_id", "secret_access_key", "session_token"} {
			if vals[k] != "" {
				out = append(out, vals[k])
			}
		}
	case "evroc":
		b, err := os.ReadFile(filepath.Join(clustersDir, evrocRel))
		if os.IsNotExist(err) {
			return nil, nil
		}
		if err != nil {
			return nil, err
		}
		var v any
		if err := yaml.Unmarshal(b, &v); err != nil {
			return nil, nil
		}
		collectSecrets(v, false, &out)
	case "vultr", "exoscale":
		vals, err := tfvars.Read(tfvars.Path(clustersDir, p, "", tfvars.LayerCommonProvider))
		if err != nil {
			return nil, err
		}
		for _, f := range Fields(p) {
			if s, _ := vals[f.Name].(string); s != "" {
				out = append(out, s)
			}
		}
	default:
		return nil, ErrUnknown
	}
	return out, nil
}

// collectSecrets gathers scalar strings longer than 8 characters found
// under keys that look secret.
func collectSecrets(v any, secret bool, out *[]string) {
	switch t := v.(type) {
	case map[string]any:
		for k, e := range t {
			collectSecrets(e, secret || secretKeyRe.MatchString(k), out)
		}
	case []any:
		for _, e := range t {
			collectSecrets(e, secret, out)
		}
	case string:
		if secret && len(t) > 8 {
			*out = append(*out, t)
		}
	}
}

func exists(p string) bool { _, err := os.Stat(p); return err == nil }

func readAWS(clustersDir string) (map[string]string, error) {
	f, err := os.Open(awsCred(clustersDir))
	if os.IsNotExist(err) {
		return map[string]string{}, nil
	}
	if err != nil {
		return nil, err
	}
	defer f.Close()
	vals, section := map[string]string{}, ""
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		switch {
		case l == "" || l[0] == '#' || l[0] == ';':
		case l[0] == '[':
			section = strings.Trim(l, "[] ")
		case section == "default":
			k, v, ok := strings.Cut(l, "=")
			if !ok {
				continue
			}
			switch strings.TrimSpace(k) {
			case "aws_access_key_id":
				vals["access_key_id"] = strings.TrimSpace(v)
			case "aws_secret_access_key":
				vals["secret_access_key"] = strings.TrimSpace(v)
			case "aws_session_token":
				vals["session_token"] = strings.TrimSpace(v)
			}
		}
	}
	return vals, sc.Err()
}

func saveAWS(clustersDir string, values map[string]string) error {
	cur, err := readAWS(clustersDir)
	if err != nil {
		return err
	}
	for k, v := range values {
		if v = strings.TrimSpace(v); v != "" {
			if strings.ContainsAny(v, "\r\n") {
				return fmt.Errorf("%s: invalid value", k)
			}
			cur[k] = v
		}
	}
	if cur["access_key_id"] == "" || cur["secret_access_key"] == "" {
		return errors.New("access key ID and secret access key are both required")
	}
	var b strings.Builder
	b.WriteString("[default]\n")
	fmt.Fprintf(&b, "aws_access_key_id = %s\naws_secret_access_key = %s\n", cur["access_key_id"], cur["secret_access_key"])
	if t := cur["session_token"]; t != "" {
		fmt.Fprintf(&b, "aws_session_token = %s\n", t)
	}
	return writeFile(awsCred(clustersDir), []byte(b.String()))
}

// writeFile writes atomically with mode 600, creating parents with 700.
func writeFile(path string, data []byte) error {
	dir := filepath.Dir(path)
	if err := os.MkdirAll(dir, 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(dir, ".tmp-*")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(data); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), path)
}

// checkEvrocConfig accepts an `evroc login` config: currentProfile must name a
// profile with a refresh token, as the provider's CLI-config loader requires.
func checkEvrocConfig(cfg string) error {
	var c struct {
		CurrentProfile string `yaml:"currentProfile"`
		Profiles       map[string]struct {
			User struct {
				RefreshToken string `yaml:"refreshToken"`
			} `yaml:"user"`
		} `yaml:"profiles"`
	}
	if err := yaml.Unmarshal([]byte(cfg), &c); err != nil {
		return errors.New("evroc config is not valid YAML")
	}
	p, ok := c.Profiles[c.CurrentProfile]
	switch {
	case c.CurrentProfile == "":
		return errors.New("evroc config has no currentProfile: paste the whole ~/.evroc/config.yaml written by `evroc login`")
	case !ok:
		return fmt.Errorf("evroc config: currentProfile %q is not under profiles", c.CurrentProfile)
	case p.User.RefreshToken == "":
		return fmt.Errorf("evroc config: profile %q has no user.refreshToken; run `evroc login` and paste the file again", c.CurrentProfile)
	}
	return nil
}
