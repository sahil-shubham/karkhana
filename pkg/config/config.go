// Package config loads Karkhana's configuration. We deliberately
// re-use bhatti's existing config file at ~/.bhatti/config.yaml
// so the operator doesn't have to set anything up — if `bhatti`
// CLI works, Karkhana works.
//
// Env vars override file values: KARKHANA_BHATTI_URL,
// KARKHANA_BHATTI_TOKEN. Useful for testing against a different
// bhatti instance without rewriting the config.
package config

import (
	"bufio"
	"fmt"
	"log/slog"
	"os"
	"path/filepath"
	"strings"

	"gopkg.in/yaml.v3"
)

// Config is the resolved runtime config.
type Config struct {
	BhattiURL   string
	BhattiToken string
	Addr        string // HTTP listen addr; default :4000

	// WorkerImage is the bhatti image used for new worker sandboxes.
	// Defaults to "computer" (pi gets npm-installed at runtime, ~30s).
	// Set KARKHANA_WORKER_IMAGE=kk-base after running
	// scripts/bake-image.sh to pre-bake pi and skip the install
	// (~2s spawn instead of ~30s).
	WorkerImage string

	// PiExtensions is the list of pi extension paths (in the
	// SANDBOX filesystem) to load via `--extension <path>` when
	// spawning the worker. With kk-base, defaults to the
	// computer-use extension that gives the agent
	// screenshot/click/type/scroll tools. Empty when WorkerImage
	// is the raw "computer" image (pi installed at runtime, no
	// extension dir to load from).
	PiExtensions []string

	// Pi (worker agent) provider config. If unset, we auto-detect
	// from whichever API key is present in the env.
	PiProvider string // e.g. "openrouter" | "anthropic" | "openai"
	PiModel    string // e.g. "anthropic/claude-sonnet-4"
}

// DefaultComputerUseExtensionPath is where bake-image.sh installs
// the computer-use extension inside the worker rootfs. Karkhana
// loads this automatically for any non-vanilla worker image.
const DefaultComputerUseExtensionPath = "/usr/local/share/karkhana/extensions/computer-use/index.ts"

// bhattiCLIConfig mirrors the YAML schema of ~/.bhatti/config.yaml.
type bhattiCLIConfig struct {
	APIURL    string `yaml:"api_url"`
	AuthToken string `yaml:"auth_token"`
}

// Load resolves the config from (in priority order):
//  1. Env vars (KARKHANA_*)
//  2. .env files (./.env, ~/Projects/karkhana/.env, then KARKHANA_ENV_FILE if set)
//  3. ~/.bhatti/config.yaml
//  4. Return error if neither yields a URL+token
func Load() (*Config, error) {
	cfg := &Config{
		Addr: envOr("KARKHANA_ADDR", ":4000"),
	}

	// Load .env files first (they don't override existing env vars).
	loadEnvFiles()

	// Try the bhatti CLI config; env vars override below.
	if home, err := os.UserHomeDir(); err == nil {
		path := filepath.Join(home, ".bhatti", "config.yaml")
		if cli, err := loadBhattiCLI(path); err == nil {
			cfg.BhattiURL = cli.APIURL
			cfg.BhattiToken = cli.AuthToken
		}
	}

	// Env-var overrides
	if v := os.Getenv("KARKHANA_BHATTI_URL"); v != "" {
		cfg.BhattiURL = v
	}
	if v := os.Getenv("KARKHANA_BHATTI_TOKEN"); v != "" {
		cfg.BhattiToken = v
	}

	if cfg.BhattiURL == "" || cfg.BhattiToken == "" {
		return nil, fmt.Errorf(
			"bhatti URL+token not configured. Either run `bhatti setup` " +
				"to populate ~/.bhatti/config.yaml, or set KARKHANA_BHATTI_URL " +
				"and KARKHANA_BHATTI_TOKEN env vars.",
		)
	}

	// Pi provider/model: explicit env vars first, then auto-detect.
	cfg.PiProvider = os.Getenv("KARKHANA_PI_PROVIDER")
	cfg.PiModel = os.Getenv("KARKHANA_PI_MODEL")
	if cfg.PiProvider == "" {
		cfg.PiProvider, cfg.PiModel = autoDetectPiProvider(cfg.PiModel)
	}

	// Worker image. Default to "computer"; user can switch to a
	// pre-baked image (e.g. kk-base from scripts/bake-image.sh).
	cfg.WorkerImage = envOr("KARKHANA_WORKER_IMAGE", "computer")

	// Pi extensions. Explicit env var (KARKHANA_PI_EXTENSIONS,
	// comma-separated) wins. Otherwise: empty for the vanilla
	// "computer" image (no extension dir baked); for any other
	// image, default to the computer-use extension path.
	if raw := os.Getenv("KARKHANA_PI_EXTENSIONS"); raw != "" {
		for _, p := range strings.Split(raw, ",") {
			p = strings.TrimSpace(p)
			if p != "" {
				cfg.PiExtensions = append(cfg.PiExtensions, p)
			}
		}
	} else if cfg.WorkerImage != "computer" {
		cfg.PiExtensions = []string{DefaultComputerUseExtensionPath}
	}

	return cfg, nil
}

// autoDetectPiProvider picks a provider based on which API keys are
// available. Prefers OpenRouter (broadest coverage, single key for
// many models) when both OpenRouter and a vendor key are set.
func autoDetectPiProvider(forcedModel string) (string, string) {
	switch {
	case os.Getenv("OPENROUTER_API_KEY") != "":
		model := forcedModel
		if model == "" {
			model = "anthropic/claude-sonnet-4"
		}
		return "openrouter", model
	case os.Getenv("ANTHROPIC_API_KEY") != "":
		model := forcedModel
		if model == "" {
			// Empty model lets pi pick its default; safe.
		}
		return "anthropic", model
	case os.Getenv("OPENAI_API_KEY") != "":
		model := forcedModel
		if model == "" {
			model = "gpt-4o"
		}
		return "openai", model
	case os.Getenv("GOOGLE_API_KEY") != "":
		return "google", forcedModel
	}
	// No keys found; pi will fail at first prompt. Return empty so
	// the operator gets a clear error rather than silent misroute.
	return "", ""
}

// loadEnvFiles loads variables from .env files into the process
// env. Existing env vars are NOT overwritten (env wins over file).
// Tries paths in order: ./.env, ~/Projects/karkhana/.env, then
// the path in KARKHANA_ENV_FILE if set.
func loadEnvFiles() {
	paths := []string{".env"}
	if home, err := os.UserHomeDir(); err == nil {
		paths = append(paths, filepath.Join(home, "Projects", "karkhana", ".env"))
	}
	if explicit := os.Getenv("KARKHANA_ENV_FILE"); explicit != "" {
		paths = append(paths, explicit)
	}
	seen := map[string]bool{}
	for _, p := range paths {
		if seen[p] {
			continue
		}
		seen[p] = true
		if n, err := loadEnvFile(p); err == nil && n > 0 {
			slog.Info("loaded env file", "path", p, "vars", n)
		}
	}
}

// loadEnvFile parses a simple KEY=VALUE .env file and sets each
// variable in the process environment iff it's not already set.
// Tolerates: blank lines, # comments, optional `export ` prefix,
// surrounding single or double quotes on the value.
func loadEnvFile(path string) (int, error) {
	f, err := os.Open(path)
	if err != nil {
		return 0, err
	}
	defer f.Close()

	n := 0
	scanner := bufio.NewScanner(f)
	for scanner.Scan() {
		line := strings.TrimSpace(scanner.Text())
		if line == "" || strings.HasPrefix(line, "#") {
			continue
		}
		line = strings.TrimPrefix(line, "export ")
		eq := strings.IndexByte(line, '=')
		if eq <= 0 {
			continue
		}
		key := strings.TrimSpace(line[:eq])
		val := strings.TrimSpace(line[eq+1:])
		// Strip matching surrounding quotes
		if len(val) >= 2 {
			if (val[0] == '"' && val[len(val)-1] == '"') ||
				(val[0] == '\'' && val[len(val)-1] == '\'') {
				val = val[1 : len(val)-1]
			}
		}
		if _, exists := os.LookupEnv(key); exists {
			continue
		}
		if err := os.Setenv(key, val); err == nil {
			n++
		}
	}
	return n, scanner.Err()
}

func loadBhattiCLI(path string) (*bhattiCLIConfig, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return nil, err
	}
	var c bhattiCLIConfig
	if err := yaml.Unmarshal(b, &c); err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	if c.APIURL == "" || c.AuthToken == "" {
		return nil, fmt.Errorf("%s missing api_url or auth_token", path)
	}
	return &c, nil
}

func envOr(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
