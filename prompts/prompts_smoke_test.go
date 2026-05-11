package prompts

import (
	"strings"
	"testing"
)

// These tests don't compare against a golden file — that comes in
// Day 2 with snapshot tests. They just confirm the templates parse,
// render, and produce output that contains the operator's goal/task
// in the right structural slot (inside the <goal> block).

func TestDriverRendersGoal(t *testing.T) {
	out, err := Render("driver", Context{Goal: "research the top 8 PM tools"})
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if !strings.Contains(out, "<environment>") || !strings.Contains(out, "</environment>") {
		t.Fatalf("env block missing:\n%s", out)
	}
	if !strings.Contains(out, "<goal>\nresearch the top 8 PM tools\n</goal>") {
		t.Fatalf("goal block missing or malformed; got tail:\n%q", tail(out, 200))
	}
	if strings.HasSuffix(out, "\n") {
		t.Fatalf("output should not end in newline; got tail %q", tail(out, 50))
	}
}

func TestWorkerDesktopWatchRendersTask(t *testing.T) {
	out, err := Render("worker.desktop-watch", Context{Task: "open bhatti.sh and screenshot"})
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if !strings.Contains(out, "computer-use toolset") {
		t.Fatalf("expected desktop-watch body, got:\n%s", out[:200])
	}
	if !strings.Contains(out, "<goal>\nopen bhatti.sh and screenshot\n</goal>") {
		t.Fatalf("goal block missing or malformed; tail:\n%q", tail(out, 200))
	}
}

func TestWorkerBashOnlyRendersTask(t *testing.T) {
	out, err := Render("worker.bash-only", Context{Task: "list files in /tmp"})
	if err != nil {
		t.Fatalf("render: %v", err)
	}
	if strings.Contains(out, "screenshot()") {
		t.Fatalf("bash-only template should not mention screenshot tool")
	}
	if !strings.Contains(out, "<goal>\nlist files in /tmp\n</goal>") {
		t.Fatalf("goal block missing or malformed; tail:\n%q", tail(out, 200))
	}
}

func TestMissingTemplateError(t *testing.T) {
	_, err := Render("does-not-exist", Context{})
	if err == nil {
		t.Fatalf("expected error for missing template")
	}
	if !strings.Contains(err.Error(), "prompt template not found") {
		t.Fatalf("unexpected error: %v", err)
	}
}

func TestListIncludesAllThree(t *testing.T) {
	names := List()
	want := map[string]bool{
		"driver":              false,
		"worker.desktop-watch": false,
		"worker.bash-only":    false,
	}
	for _, n := range names {
		if _, ok := want[n]; ok {
			want[n] = true
		}
	}
	for n, found := range want {
		if !found {
			t.Errorf("List() missing %q (got %v)", n, names)
		}
	}
}

func tail(s string, n int) string {
	if len(s) <= n {
		return s
	}
	return s[len(s)-n:]
}
