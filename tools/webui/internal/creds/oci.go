package creds

import (
	"bufio"
	"encoding/pem"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/schema"
	"github.com/e-minguez/suse-ai-factory-cloud-providers/tools/webui/internal/tfvars"
)

// oci: Terraform reads the OCIDs, the fingerprint and the key path from
// common-oci.tfvars; the oci CLI (leftovers check) reads $HOME/.oci/config,
// which Save writes from the same values. Both point at one PEM file.
const (
	ociKeyRel    = ".home/.oci/oci_api_key.pem"
	ociConfigRel = ".home/.oci/config"
)

// ociTfvars are the credential fields stored in common-oci.tfvars.
var ociTfvars = []string{"oci_tenancy_ocid", "oci_user_ocid", "oci_fingerprint"}

func ociFields() []schema.Field {
	key := field("private_key", "API signing private key (PEM)", "Content of the private key file whose public key is uploaded to the user. Unencrypted PEM.", true)
	key.Widget = "text"
	return []schema.Field{
		field("oci_tenancy_ocid", "Tenancy OCID", "OCID of the tenancy.", true),
		field("oci_user_ocid", "User OCID", "OCID of the user that owns the API key.", true),
		field("oci_fingerprint", "API key fingerprint", "Fingerprint of the API key, as shown on the user's API keys page.", true),
		key,
		field("cli_region", "OCI CLI region", "Default region written to ~/.oci/config for the oci CLI (leftovers check), usually the home region. Clusters use their own region.", true),
	}
}

func ociStatus(clustersDir string, out map[string]bool) error {
	vals, err := tfvars.Read(tfvars.Path(clustersDir, "oci", "", tfvars.LayerCommonProvider))
	if err != nil {
		return err
	}
	for _, k := range ociTfvars {
		s, _ := vals[k].(string)
		out[k] = s != ""
	}
	b, err := os.ReadFile(filepath.Join(clustersDir, ociKeyRel))
	if err != nil && !os.IsNotExist(err) {
		return err
	}
	out["private_key"] = len(strings.TrimSpace(string(b))) > 0
	region, err := ociConfigRegion(clustersDir)
	if err != nil {
		return err
	}
	out["cli_region"] = region != ""
	return nil
}

func ociSave(clustersDir string, values map[string]string) error {
	abs, err := filepath.Abs(clustersDir)
	if err != nil {
		return err
	}
	for k, v := range values {
		if k != "private_key" && strings.ContainsAny(v, "\r\n") {
			return fmt.Errorf("%s: invalid value", k)
		}
	}
	keyPath := filepath.Join(abs, ociKeyRel)
	if k := strings.TrimSpace(values["private_key"]); k != "" {
		if err := checkOCIKey(k); err != nil {
			return err
		}
		if err := writeFile(keyPath, []byte(k+"\n")); err != nil {
			return err
		}
	}

	tfPath := tfvars.Path(clustersDir, "oci", "", tfvars.LayerCommonProvider)
	set := map[string]any{}
	for _, k := range ociTfvars {
		if v := strings.TrimSpace(values[k]); v != "" {
			set[k] = v
		}
	}
	if exists(keyPath) {
		set["oci_private_key_path"] = keyPath
	}
	if len(set) > 0 {
		if err := tfvars.Write(tfPath, set, nil); err != nil {
			return err
		}
	}

	// The CLI config needs every value: write it once all are known.
	cur, err := tfvars.Read(tfPath)
	if err != nil {
		return err
	}
	region := strings.TrimSpace(values["cli_region"])
	if region == "" {
		if region, err = ociConfigRegion(clustersDir); err != nil {
			return err
		}
	}
	str := func(k string) string { s, _ := cur[k].(string); return s }
	if str("oci_tenancy_ocid") == "" || str("oci_user_ocid") == "" || str("oci_fingerprint") == "" || region == "" || !exists(keyPath) {
		return nil
	}
	cfg := fmt.Sprintf("[DEFAULT]\nuser=%s\nfingerprint=%s\ntenancy=%s\nregion=%s\nkey_file=%s\n",
		str("oci_user_ocid"), str("oci_fingerprint"), str("oci_tenancy_ocid"), region, keyPath)
	return writeFile(filepath.Join(abs, ociConfigRel), []byte(cfg))
}

// ociConfigRegion returns region= of the [DEFAULT] profile, "" without a config.
func ociConfigRegion(clustersDir string) (string, error) {
	f, err := os.Open(filepath.Join(clustersDir, ociConfigRel))
	if os.IsNotExist(err) {
		return "", nil
	}
	if err != nil {
		return "", err
	}
	defer f.Close()
	section := ""
	sc := bufio.NewScanner(f)
	for sc.Scan() {
		l := strings.TrimSpace(sc.Text())
		switch {
		case strings.HasPrefix(l, "["):
			section = strings.Trim(l, "[] ")
		case section == "DEFAULT":
			if k, v, ok := strings.Cut(l, "="); ok && strings.TrimSpace(k) == "region" {
				return strings.TrimSpace(v), nil
			}
		}
	}
	return "", sc.Err()
}

func ociSecretValues(clustersDir string) ([]string, error) {
	b, err := os.ReadFile(filepath.Join(clustersDir, ociKeyRel))
	if os.IsNotExist(err) {
		return nil, nil
	}
	if err != nil {
		return nil, err
	}
	if k := strings.TrimSpace(string(b)); k != "" {
		return []string{k}, nil
	}
	return nil, nil
}

// checkOCIKey accepts one unencrypted PEM private key block.
func checkOCIKey(k string) error {
	blk, rest := pem.Decode([]byte(k))
	switch {
	case blk == nil:
		return errors.New("private key is not PEM: paste the whole file, including the BEGIN and END lines")
	case !strings.HasSuffix(blk.Type, "PRIVATE KEY"):
		return fmt.Errorf("private key: PEM block is %q, not a private key", blk.Type)
	case blk.Type == "ENCRYPTED PRIVATE KEY" || blk.Headers["Proc-Type"] != "":
		return errors.New("private key is encrypted: paste an unencrypted key")
	case len(strings.TrimSpace(string(rest))) > 0:
		return errors.New("private key: unexpected content after the PEM block")
	}
	return nil
}
