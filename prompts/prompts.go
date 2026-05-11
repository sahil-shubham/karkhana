// Package prompts loads and renders Karkhana's LLM preamble
// templates.
//
// Templates live in this directory as *.tmpl files. In
// production they are embedded into the binary via go:embed; the
// karkhana binary is fully self-contained, no on-disk prompts/
// directory required at runtime.
//
// In KARKHANA_DEV=1 mode, templates are re-read from disk on
// every render (from $KARKHANA_PROMPTS_DIR, default ./prompts),
// so prompt iteration takes effect on the next mission/worker
// spawn without a rebuild. fsnotify-style watching is not needed
// — re-parsing a few KB of templates per spawn is ~1ms.
//
// Layout:
//
//	prompts/
//	    driver.tmpl                The supervisor preamble.
//	    worker.desktop-watch.tmpl  Worker on a headful XFCE +
//	                               chromium desktop with the
//	                               computer-use toolset.
//	    worker.bash-only.tmpl      Worker without the
//	                               computer-use tools (bash +
//	                               chromium-from-bash only).
//
// Call sites:
//
//	prompt, err := prompts.Render("driver", prompts.Context{
//	    Goal: m.Goal,
//	})
//
//	prompt, err := prompts.Render("worker.desktop-watch", prompts.Context{
//	    Task: worker.Task,
//	})
package prompts

import (
	"bytes"
	"embed"
	"fmt"
	"io/fs"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"text/template"
)

//go:embed *.tmpl
var embedded embed.FS

// Context is the data threaded into every template render.
// Different templates use different fields — see the .tmpl
// files for which. Unset fields render as the zero value (an
// empty string), which is what you want for "this field isn't
// relevant to this template."
type Context struct {
	// Goal is the operator's original mission goal. Used by
	// driver.tmpl.
	Goal string

	// Task is the per-worker task string the driver hands
	// down via spawn_worker. Used by worker.*.tmpl.
	Task string
}

// Render parses the template named name (without the ".tmpl"
// suffix) and renders it with ctx, returning the rendered
// string. In production mode (KARKHANA_DEV != "1") the embedded
// templates are parsed once and cached. In dev mode every call
// re-reads from disk.
func Render(name string, ctx Context) (string, error) {
	tmpl, err := load(name)
	if err != nil {
		return "", err
	}
	var buf bytes.Buffer
	if err := tmpl.Execute(&buf, ctx); err != nil {
		return "", fmt.Errorf("execute %s: %w", name, err)
	}
	return buf.String(), nil
}

// MustRender is Render that panics on error. Use only in
// startup paths where a missing template should fail the
// process loudly.
func MustRender(name string, ctx Context) string {
	out, err := Render(name, ctx)
	if err != nil {
		panic(err)
	}
	return out
}

// devMode reports whether we should re-read templates from disk
// on every render (true) or use the embedded copy (false).
func devMode() bool {
	return os.Getenv("KARKHANA_DEV") == "1"
}

func load(name string) (*template.Template, error) {
	if devMode() {
		return loadFromDisk(name)
	}
	return loadFromEmbed(name)
}

// Embedded path: parse all *.tmpl once on first use, cache.
var (
	prodOnce  sync.Once
	prodCache map[string]*template.Template
	prodErr   error
)

// ensureProdLoaded populates prodCache from the embedded FS exactly
// once. Subsequent calls are a no-op. Returns the cached load error
// (if any) so callers don't have to repeat that check.
func ensureProdLoaded() error {
	prodOnce.Do(func() {
		prodCache = map[string]*template.Template{}
		entries, err := fs.ReadDir(embedded, ".")
		if err != nil {
			prodErr = fmt.Errorf("list embedded prompts: %w", err)
			return
		}
		for _, e := range entries {
			if e.IsDir() || filepath.Ext(e.Name()) != ".tmpl" {
				continue
			}
			body, err := embedded.ReadFile(e.Name())
			if err != nil {
				prodErr = fmt.Errorf("read embedded %s: %w", e.Name(), err)
				return
			}
			tmplName := strings.TrimSuffix(e.Name(), ".tmpl")
			t, err := template.New(tmplName).Parse(string(body))
			if err != nil {
				prodErr = fmt.Errorf("parse embedded %s: %w", e.Name(), err)
				return
			}
			prodCache[tmplName] = t
		}
	})
	return prodErr
}

func loadFromEmbed(name string) (*template.Template, error) {
	if err := ensureProdLoaded(); err != nil {
		return nil, err
	}
	t, ok := prodCache[name]
	if !ok {
		return nil, fmt.Errorf("prompt template not found: %s (have: %s)",
			name, knownEmbedded())
	}
	return t, nil
}

func knownEmbedded() string {
	names := make([]string, 0, len(prodCache))
	for k := range prodCache {
		names = append(names, k)
	}
	return strings.Join(names, ", ")
}

// Disk path: re-read on every call.
func loadFromDisk(name string) (*template.Template, error) {
	dir := os.Getenv("KARKHANA_PROMPTS_DIR")
	if dir == "" {
		dir = "prompts"
	}
	path := filepath.Join(dir, name+".tmpl")
	body, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read %s: %w (set KARKHANA_PROMPTS_DIR if templates live elsewhere)", path, err)
	}
	t, err := template.New(name).Parse(string(body))
	if err != nil {
		return nil, fmt.Errorf("parse %s: %w", path, err)
	}
	return t, nil
}

// List returns the names of all available templates (without
// the .tmpl suffix). Useful for startup validation and for the
// recipe loader (so a recipe referencing a missing template can
// be caught early).
func List() []string {
	if devMode() {
		dir := os.Getenv("KARKHANA_PROMPTS_DIR")
		if dir == "" {
			dir = "prompts"
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			return nil
		}
		var out []string
		for _, e := range entries {
			if e.IsDir() || filepath.Ext(e.Name()) != ".tmpl" {
				continue
			}
			out = append(out, strings.TrimSuffix(e.Name(), ".tmpl"))
		}
		return out
	}
	// Production mode: enumerate the embedded cache.
	if err := ensureProdLoaded(); err != nil {
		return nil
	}
	out := make([]string, 0, len(prodCache))
	for k := range prodCache {
		out = append(out, k)
	}
	return out
}
