// Package all registers every provider by importing it for its side effect.
package all

import (
	_ "github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider/aws"
	_ "github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider/evroc"
	_ "github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider/exoscale"
	_ "github.com/e-minguez/suse-ai-factory-cloud-providers/tools/cost/internal/provider/vultr"
)
