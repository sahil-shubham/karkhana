package recipes

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// promptsKnown is what the prompts package would tell us at
// startup. Hard-coded here to keep the tests independent of
// karkhana/prompts (no import cycle, no test-time setup of the
// prompts package). Real karkhana feeds prompts.List() in.
var promptsKnown = []string{
	"driver",
	"worker.desktop-watch",
	"worker.headless-dev",
	"worker.bash-only",
	"worker.mixed",
}

func TestLoadEmbedded(t *testing.T) {
	reg, err := Load(promptsKnown, "desktop-watch")
	if err != nil {
		t.Fatalf("load: %v", err)
	}
	want := []string{"desktop-watch", "headless-dev", "mixed"}
	got := reg.Names()
	if len(got) != len(want) {
		t.Fatalf("got %v, want %v", got, want)
	}
	for i, n := range want {
		if got[i] != n {
			t.Fatalf("[%d] got %q want %q", i, got[i], n)
		}
	}
}

func TestGetReturnsRecipe(t *testing.T) {
	reg, err := Load(promptsKnown, "desktop-watch")
	if err != nil {
		t.Fatal(err)
	}
	r, err := reg.Get("desktop-watch")
	if err != nil {
		t.Fatal(err)
	}
	if r.Image != "kk-base" {
		t.Errorf("image: got %q", r.Image)
	}
	if r.Prompt != "worker.desktop-watch" {
		t.Errorf("prompt: got %q", r.Prompt)
	}
	if r.Resources.CPU != 2 || r.Resources.MemoryMB != 4096 {
		t.Errorf("resources: got %+v", r.Resources)
	}
}

func TestGetEmptyStringResolvesToDefault(t *testing.T) {
	reg, err := Load(promptsKnown, "desktop-watch")
	if err != nil {
		t.Fatal(err)
	}
	r1, _ := reg.Get("")
	r2, _ := reg.Get("desktop-watch")
	if r1 != r2 {
		t.Errorf("empty-name lookup did not resolve to default")
	}
}

func TestUnknownRecipeError(t *testing.T) {
	reg, _ := Load(promptsKnown, "desktop-watch")
	_, err := reg.Get("nope")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "not found") {
		t.Fatalf("unexpected: %v", err)
	}
}

func TestLoadDefaultMustExist(t *testing.T) {
	_, err := Load(promptsKnown, "ghost")
	if err == nil {
		t.Fatal("expected error for missing default")
	}
	if !strings.Contains(err.Error(), "default recipe") {
		t.Fatalf("unexpected: %v", err)
	}
}

func TestValidationRefusesMissingPrompt(t *testing.T) {
	// Only known prompts here exclude worker.headless-dev — the
	// headless-dev recipe should fail to load against this
	// reduced set.
	limited := []string{"driver", "worker.desktop-watch", "worker.mixed", "worker.bash-only"}
	_, err := Load(limited, "desktop-watch")
	if err == nil {
		t.Fatal("expected load to fail on missing prompt")
	}
	if !strings.Contains(err.Error(), "worker.headless-dev") {
		t.Fatalf("error should reference the missing prompt; got: %v", err)
	}
}

func TestValidationRefusesBadName(t *testing.T) {
	dir := t.TempDir()
	writeYAML(t, dir, "bad.yaml", `
name: Has_Underscore_And_CamelCase
image: kk-base
resources: { cpu: 2, memory_mb: 1024 }
prompt: worker.desktop-watch
`)
	t.Setenv("KARKHANA_DEV", "1")
	t.Setenv("KARKHANA_RECIPES_DIR", dir)

	_, err := Load(promptsKnown, "anything")
	if err == nil {
		t.Fatal("expected error")
	}
	if !strings.Contains(err.Error(), "must match") {
		t.Fatalf("unexpected: %v", err)
	}
}

func TestValidationRefusesUnknownYAMLKey(t *testing.T) {
	dir := t.TempDir()
	writeYAML(t, dir, "typo.yaml", `
name: typo-recipe
image: kk-base
resources: { cpu: 2, memory_mb: 1024 }
prompt: worker.desktop-watch
typooed_field: oops
`)
	t.Setenv("KARKHANA_DEV", "1")
	t.Setenv("KARKHANA_RECIPES_DIR", dir)

	_, err := Load(promptsKnown, "typo-recipe")
	if err == nil {
		t.Fatal("expected unknown-field error")
	}
}

func TestDevModeReloadsOnEdit(t *testing.T) {
	dir := t.TempDir()
	writeYAML(t, dir, "edit.yaml", `
name: edit-recipe
image: img-v1
resources: { cpu: 1, memory_mb: 512 }
prompt: worker.desktop-watch
`)
	t.Setenv("KARKHANA_DEV", "1")
	t.Setenv("KARKHANA_RECIPES_DIR", dir)

	reg, err := Load(promptsKnown, "edit-recipe")
	if err != nil {
		t.Fatal(err)
	}
	r1, _ := reg.Get("edit-recipe")
	if r1.Image != "img-v1" {
		t.Fatalf("v1 image: %q", r1.Image)
	}

	// Edit on disk.
	writeYAML(t, dir, "edit.yaml", `
name: edit-recipe
image: img-v2
resources: { cpu: 1, memory_mb: 512 }
prompt: worker.desktop-watch
`)
	r2, err := reg.Get("edit-recipe")
	if err != nil {
		t.Fatal(err)
	}
	if r2.Image != "img-v2" {
		t.Fatalf("v2 image not reloaded: %q", r2.Image)
	}
}

func TestProdModeIgnoresDiskOverride(t *testing.T) {
	dir := t.TempDir()
	writeYAML(t, dir, "desktop-watch.yaml", `
name: desktop-watch
image: hijacked
resources: { cpu: 1, memory_mb: 1 }
prompt: worker.desktop-watch
`)
	t.Setenv("KARKHANA_DEV", "")
	t.Setenv("KARKHANA_RECIPES_DIR", dir)

	reg, err := Load(promptsKnown, "desktop-watch")
	if err != nil {
		t.Fatal(err)
	}
	r, _ := reg.Get("desktop-watch")
	if r.Image == "hijacked" {
		t.Fatalf("prod mode followed disk override (correctness bug)")
	}
	if r.Image != "kk-base" {
		t.Fatalf("expected embedded image kk-base, got %q", r.Image)
	}
}

func writeYAML(t *testing.T, dir, name, body string) {
	t.Helper()
	path := filepath.Join(dir, name)
	if err := os.WriteFile(path, []byte(strings.TrimLeft(body, "\n")), 0o644); err != nil {
		t.Fatalf("write %s: %v", path, err)
	}
}
