// Package recipes loads and validates Karkhana's worker
// recipes — declarative bhatti compositions that fix a
// worker's image, resources, tools, preamble template, and
// lifecycle policy.
//
// A recipe is the thing the driver picks when it calls
// spawn_worker. Picking "desktop-watch" gives the agent a
// headful chromium desktop. Picking "headless-dev" gives it a
// fast shell with git/grep/edit. The recipe IS the worker's
// shape; everything from the OS image to the LLM preamble flows
// from one YAML file.
//
// Like the prompts package, recipes live as *.yaml files in
// this directory. Production embeds them via go:embed. Dev mode
// (KARKHANA_DEV=1) re-reads from disk on every Get call so an
// operator can iterate on a recipe and see the change on the
// next spawn without a rebuild.
//
// Layout:
//
//	recipes/
//	    desktop-watch.yaml  Headful XFCE + chromium + computer-use.
//	    headless-dev.yaml   Fast shell for code work, no GUI.
//	    mixed.yaml          Both. Use when the task shape is
//	                        genuinely unclear.
package recipes

import (
	"bytes"
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"sync"

	"gopkg.in/yaml.v3"
)

//go:embed *.yaml
var embedded embed.FS

// Recipe is one resolved worker configuration. Loaded from a
// single YAML file in this directory.
//
// Field-naming convention: YAML uses snake_case, Go uses
// CamelCase, struct tags bridge.
type Recipe struct {
	Name        string    `yaml:"name"`
	Description string    `yaml:"description,omitempty"`
	Image       string    `yaml:"image"`
	Resources   Resources `yaml:"resources"`

	// Secrets is the list of bhatti secret names to inject into
	// the sandbox at boot. Operator runs `bhatti secret set
	// <name> <value>` once; karkhana never sees the value.
	Secrets []string `yaml:"secrets,omitempty"`

	// Extensions is the list of pi `--extension <path>` args.
	// Paths are interpreted INSIDE the sandbox filesystem, so
	// they assume bake-image.sh / Dockerfile dropped them there.
	Extensions []string `yaml:"extensions,omitempty"`

	// Prompt is the name (without .tmpl) of the preamble
	// template in the prompts/ directory.
	Prompt string `yaml:"prompt"`

	// AllowHTTP is a list of hostnames (or glob patterns) the
	// worker is allowed to reach over HTTP. Today this field is
	// documented but not yet enforced at the substrate level —
	// the curl regex block in computer-use/index.ts is recipe-
	// agnostic. Enforcement lands in a follow-up; the field is
	// here now so recipes that need it can declare it.
	AllowHTTP []string `yaml:"allow_http,omitempty"`

	// DenyCurlToOthers, when true, asks the worker's bash tool
	// to refuse curl/wget against public URLs not in AllowHTTP.
	// Same caveat as AllowHTTP — declared now, enforced later.
	DenyCurlToOthers bool `yaml:"deny_curl_to_others,omitempty"`

	AutoPublish *AutoPublishPolicy `yaml:"auto_publish,omitempty"`
	Idle        *IdlePolicy        `yaml:"idle,omitempty"`
	Canvas      CanvasHints        `yaml:"canvas,omitempty"`
}

// Resources are the bhatti sandbox sizing knobs.
type Resources struct {
	CPU         float32 `yaml:"cpu"`
	MemoryMB    int     `yaml:"memory_mb"`
	TimeoutSecs int     `yaml:"timeout_secs,omitempty"`
}

// AutoPublishPolicy turns bhatti.ListeningPorts diffs into
// automatic Publish calls. Not yet wired into the runtime —
// declared so recipes can express intent; the discoverer lands
// later in the plan.
type AutoPublishPolicy struct {
	PortRange     [2]int `yaml:"port_range"`
	AliasTemplate string `yaml:"alias_template,omitempty"`
	TTLSecs       int    `yaml:"ttl_secs,omitempty"`
}

// IdlePolicy controls when a worker is paused or stopped after
// inactivity. Not yet wired; same shape rationale as AutoPublish.
type IdlePolicy struct {
	PauseAfterSecs int `yaml:"pause_after_secs,omitempty"`
	StopAfterSecs  int `yaml:"stop_after_secs,omitempty"`
}

// CanvasHints inform the UI which tile shape to render for a
// worker of this recipe.
type CanvasHints struct {
	PrimaryTile       string `yaml:"primary_tile,omitempty"` // "desktop" | "log"
	ShowPublishedURLs bool   `yaml:"show_published_urls,omitempty"`
}

// Registry is the loaded set of recipes. Safe for concurrent use.
type Registry struct {
	mu       sync.RWMutex
	recipes  map[string]*Recipe
	prompts  map[string]bool // valid prompt-template names, for validation
	devMode  bool
	disk     string // KARKHANA_RECIPES_DIR override path (dev only)
	defaultR string
}

// Load parses every *.yaml under the recipes source — embedded
// in production, on disk in KARKHANA_DEV=1 mode — and returns a
// validated Registry. The list of valid prompt names is passed
// in so the loader can fail on a recipe that references a
// missing prompt template (catches typos at startup, not at
// first spawn).
//
// defaultName is the name a caller will resolve when the driver
// invokes spawn_worker without an explicit `recipe` argument.
// Must be present in the loaded set; Load returns an error if
// not.
func Load(validPromptNames []string, defaultName string) (*Registry, error) {
	r := &Registry{
		prompts:  make(map[string]bool, len(validPromptNames)),
		defaultR: defaultName,
	}
	for _, p := range validPromptNames {
		r.prompts[p] = true
	}
	if devMode() {
		r.devMode = true
		r.disk = recipesDir()
	}
	if err := r.reload(); err != nil {
		return nil, err
	}
	if _, ok := r.recipes[defaultName]; !ok {
		return nil, fmt.Errorf("default recipe %q not found (have: %s)",
			defaultName, strings.Join(r.Names(), ", "))
	}
	return r, nil
}

func devMode() bool {
	return os.Getenv("KARKHANA_DEV") == "1"
}

func recipesDir() string {
	if d := os.Getenv("KARKHANA_RECIPES_DIR"); d != "" {
		return d
	}
	return "recipes"
}

// reload parses all recipes from the configured source and
// installs them atomically. Called from Load and from Get when
// in dev mode (cheap; YAML parse on a few files is sub-ms).
func (r *Registry) reload() error {
	var files map[string][]byte
	var err error
	if r.devMode {
		files, err = readDir(r.disk)
	} else {
		files, err = readEmbed()
	}
	if err != nil {
		return err
	}
	parsed := make(map[string]*Recipe, len(files))
	for path, body := range files {
		var rec Recipe
		dec := yaml.NewDecoder(bytes.NewReader(body))
		dec.KnownFields(true) // refuse unknown YAML keys = catches typos
		if err := dec.Decode(&rec); err != nil {
			return fmt.Errorf("parse %s: %w", path, err)
		}
		if err := r.validate(&rec, path); err != nil {
			return err
		}
		if other, dup := parsed[rec.Name]; dup {
			return fmt.Errorf("duplicate recipe name %q in %s (already loaded from %s)",
				rec.Name, path, other.Name)
		}
		parsed[rec.Name] = &rec
	}
	r.mu.Lock()
	r.recipes = parsed
	r.mu.Unlock()
	return nil
}

var nameRe = regexp.MustCompile(`^[a-z][a-z0-9-]{0,30}$`)

func (r *Registry) validate(rec *Recipe, path string) error {
	if !nameRe.MatchString(rec.Name) {
		return fmt.Errorf("%s: name %q must match %s", path, rec.Name, nameRe)
	}
	if rec.Image == "" {
		return fmt.Errorf("%s: image is required", path)
	}
	if rec.Prompt == "" {
		return fmt.Errorf("%s: prompt is required", path)
	}
	if !r.prompts[rec.Prompt] {
		return fmt.Errorf("%s: prompt %q does not exist (run prompts.List() to see valid names)",
			path, rec.Prompt)
	}
	if rec.Resources.CPU <= 0 {
		return fmt.Errorf("%s: resources.cpu must be > 0", path)
	}
	if rec.Resources.MemoryMB <= 0 {
		return fmt.Errorf("%s: resources.memory_mb must be > 0", path)
	}
	if rec.AutoPublish != nil {
		lo, hi := rec.AutoPublish.PortRange[0], rec.AutoPublish.PortRange[1]
		if lo <= 0 || hi <= lo || hi > 65535 {
			return fmt.Errorf("%s: auto_publish.port_range invalid: [%d,%d]", path, lo, hi)
		}
	}
	if rec.Canvas.PrimaryTile != "" &&
		rec.Canvas.PrimaryTile != "desktop" &&
		rec.Canvas.PrimaryTile != "log" {
		return fmt.Errorf("%s: canvas.primary_tile must be 'desktop' or 'log', got %q",
			path, rec.Canvas.PrimaryTile)
	}
	return nil
}

// Get returns the named recipe. In dev mode this re-reads from
// disk before looking up, so edits to a YAML file take effect
// on the next spawn without a karkhana restart.
func (r *Registry) Get(name string) (*Recipe, error) {
	if r.devMode {
		if err := r.reload(); err != nil {
			return nil, fmt.Errorf("recipe reload: %w", err)
		}
	}
	if name == "" {
		name = r.defaultR
	}
	r.mu.RLock()
	rec, ok := r.recipes[name]
	r.mu.RUnlock()
	if !ok {
		return nil, fmt.Errorf("recipe %q not found (have: %s)",
			name, strings.Join(r.Names(), ", "))
	}
	return rec, nil
}

// Default returns the configured default recipe. Convenience
// for "spawn with whatever the operator configured."
func (r *Registry) Default() (*Recipe, error) {
	return r.Get(r.defaultR)
}

// DefaultName returns the configured default recipe's name,
// useful for log/debug lines.
func (r *Registry) DefaultName() string {
	return r.defaultR
}

// Names returns the sorted list of recipe names.
func (r *Registry) Names() []string {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]string, 0, len(r.recipes))
	for n := range r.recipes {
		out = append(out, n)
	}
	sort.Strings(out)
	return out
}

// List returns a stable-ordered snapshot of all loaded recipes.
// Useful for the future "what recipes does this karkhana
// expose" API endpoint.
func (r *Registry) List() []*Recipe {
	r.mu.RLock()
	defer r.mu.RUnlock()
	out := make([]*Recipe, 0, len(r.recipes))
	for _, rec := range r.recipes {
		out = append(out, rec)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}

// --- source readers ---

func readEmbed() (map[string][]byte, error) {
	out := map[string][]byte{}
	entries, err := fs.ReadDir(embedded, ".")
	if err != nil {
		return nil, fmt.Errorf("list embedded recipes: %w", err)
	}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if !strings.HasSuffix(e.Name(), ".yaml") &&
			!strings.HasSuffix(e.Name(), ".yml") {
			continue
		}
		body, err := embedded.ReadFile(e.Name())
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", e.Name(), err)
		}
		out["recipes/"+e.Name()] = body
	}
	return out, nil
}

func readDir(dir string) (map[string][]byte, error) {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return nil, fmt.Errorf("read recipes dir %s: %w (set KARKHANA_RECIPES_DIR if elsewhere)", dir, err)
	}
	out := map[string][]byte{}
	for _, e := range entries {
		if e.IsDir() {
			continue
		}
		if !strings.HasSuffix(e.Name(), ".yaml") &&
			!strings.HasSuffix(e.Name(), ".yml") {
			continue
		}
		body, err := os.ReadFile(filepath.Join(dir, e.Name()))
		if err != nil {
			return nil, fmt.Errorf("read %s: %w", e.Name(), err)
		}
		out[filepath.Join(dir, e.Name())] = body
	}
	return out, nil
}
