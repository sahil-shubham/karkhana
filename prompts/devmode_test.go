package prompts

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Verifies KARKHANA_DEV=1 reads templates from disk on every render
// and picks up edits without a process restart. This is the
// iteration-velocity claim of the prompts package; if this test
// passes, prompt iteration genuinely is "edit + next spawn."

func TestDevModeReadsFromDisk(t *testing.T) {
	dir := t.TempDir()
	tmpl := filepath.Join(dir, "smoke.tmpl")
	if err := os.WriteFile(tmpl, []byte("hello {{ .Goal }} from disk v1"), 0o644); err != nil {
		t.Fatalf("write template: %v", err)
	}

	t.Setenv("KARKHANA_DEV", "1")
	t.Setenv("KARKHANA_PROMPTS_DIR", dir)

	got, err := Render("smoke", Context{Goal: "world"})
	if err != nil {
		t.Fatalf("render v1: %v", err)
	}
	if got != "hello world from disk v1" {
		t.Fatalf("v1 unexpected: %q", got)
	}
}

func TestDevModeReloadsOnEdit(t *testing.T) {
	dir := t.TempDir()
	tmpl := filepath.Join(dir, "reload.tmpl")

	t.Setenv("KARKHANA_DEV", "1")
	t.Setenv("KARKHANA_PROMPTS_DIR", dir)

	if err := os.WriteFile(tmpl, []byte("v1: {{ .Goal }}"), 0o644); err != nil {
		t.Fatalf("write v1: %v", err)
	}
	got1, err := Render("reload", Context{Goal: "x"})
	if err != nil {
		t.Fatalf("render v1: %v", err)
	}
	if got1 != "v1: x" {
		t.Fatalf("v1 unexpected: %q", got1)
	}

	// Edit the template in place.
	if err := os.WriteFile(tmpl, []byte("v2: {{ .Goal }}!"), 0o644); err != nil {
		t.Fatalf("write v2: %v", err)
	}
	got2, err := Render("reload", Context{Goal: "x"})
	if err != nil {
		t.Fatalf("render v2: %v", err)
	}
	if got2 != "v2: x!" {
		t.Fatalf("v2 unexpected: %q (hot reload did not take effect)", got2)
	}
}

func TestDevModeMissingFileError(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KARKHANA_DEV", "1")
	t.Setenv("KARKHANA_PROMPTS_DIR", dir)

	_, err := Render("ghost", Context{})
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "ghost.tmpl") {
		t.Fatalf("error should reference the missing path; got: %v", err)
	}
}

func TestDevModeListUsesDisk(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("KARKHANA_DEV", "1")
	t.Setenv("KARKHANA_PROMPTS_DIR", dir)

	for _, name := range []string{"a.tmpl", "b.tmpl", "ignore.txt"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o644); err != nil {
			t.Fatalf("write %s: %v", name, err)
		}
	}
	got := List()
	want := map[string]bool{"a": true, "b": true}
	for _, n := range got {
		if !want[n] {
			t.Errorf("List() returned unexpected %q (got %v)", n, got)
		}
		delete(want, n)
	}
	for n := range want {
		t.Errorf("List() missing %q (got %v)", n, got)
	}
}

func TestProdModeIgnoresDiskOverride(t *testing.T) {
	// Even with KARKHANA_PROMPTS_DIR set, if KARKHANA_DEV != "1"
	// we use the embedded templates and the override is ignored.
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "driver.tmpl"), []byte("hijacked: {{ .Goal }}"), 0o644); err != nil {
		t.Fatalf("write: %v", err)
	}
	t.Setenv("KARKHANA_DEV", "")
	t.Setenv("KARKHANA_PROMPTS_DIR", dir)

	got, err := Render("driver", Context{Goal: "x"})
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if strings.Contains(got, "hijacked") {
		t.Fatalf("prod mode followed disk override (security/correctness bug); got: %q", got[:50])
	}
	if !strings.Contains(got, "SUPERVISOR") {
		t.Fatalf("expected embedded driver template content; got: %q", got[:50])
	}
}
