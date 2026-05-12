package prompts

import (
	"flag"
	"os"
	"path/filepath"
	"testing"
)

// Snapshot tests for the rendered preambles.
//
// Each template gets rendered with a fixed Context and the full
// output is compared against a committed golden file in
// prompts/testdata/. To regenerate goldens after an intentional
// prompt change:
//
//	go test ./prompts/ -update
//
// The golden files are the authoritative record of "what does the
// LLM actually see." Reviewing prompt-change PRs is reviewing the
// golden diff.

var update = flag.Bool("update", false, "regenerate golden files instead of comparing against them")

type snapshotCase struct {
	templateName string // e.g. "driver"
	goldenName   string // e.g. "driver.golden"
	ctx          Context
}

func snapshotCases() []snapshotCase {
	return []snapshotCase{
		{
			templateName: "driver",
			goldenName:   "driver.golden",
			ctx:          Context{Goal: "research the top 8 PM tools"},
		},
		{
			templateName: "worker.desktop-watch",
			goldenName:   "worker.desktop-watch.golden",
			ctx:          Context{Task: "open bhatti.sh and screenshot the landing page"},
		},
		{
			templateName: "worker.headless-dev",
			goldenName:   "worker.headless-dev.golden",
			ctx:          Context{Task: "clone bhatti, scan its top-level Go packages, write_note('arch', ...)"},
		},
		{
			templateName: "worker.mixed",
			goldenName:   "worker.mixed.golden",
			ctx:          Context{Task: "explore bhatti.sh and the bhatti github repo together"},
		},
		{
			templateName: "worker.bash-only",
			goldenName:   "worker.bash-only.golden",
			ctx:          Context{Task: "list files in /tmp and pick the three largest"},
		},
	}
}

func TestSnapshots(t *testing.T) {
	for _, c := range snapshotCases() {
		c := c
		t.Run(c.templateName, func(t *testing.T) {
			got, err := Render(c.templateName, c.ctx)
			if err != nil {
				t.Fatalf("render %s: %v", c.templateName, err)
			}
			goldenPath := filepath.Join("testdata", c.goldenName)

			if *update {
				if err := os.MkdirAll("testdata", 0o755); err != nil {
					t.Fatalf("mkdir testdata: %v", err)
				}
				if err := os.WriteFile(goldenPath, []byte(got), 0o644); err != nil {
					t.Fatalf("write golden %s: %v", goldenPath, err)
				}
				t.Logf("updated %s (%d bytes)", goldenPath, len(got))
				return
			}

			want, err := os.ReadFile(goldenPath)
			if err != nil {
				t.Fatalf("read golden %s: %v (run `go test ./prompts/ -update` to create it)",
					goldenPath, err)
			}
			if string(want) != got {
				t.Fatalf("%s output does not match golden %s.\nrun `go test ./prompts/ -update` to accept.\nfirst-diff at byte %d:\n  want: %q\n  got:  %q",
					c.templateName, goldenPath,
					firstDiff(string(want), got),
					excerpt(string(want), firstDiff(string(want), got)),
					excerpt(got, firstDiff(string(want), got)),
				)
			}
		})
	}
}

func firstDiff(a, b string) int {
	min := len(a)
	if len(b) < min {
		min = len(b)
	}
	for i := 0; i < min; i++ {
		if a[i] != b[i] {
			return i
		}
	}
	if len(a) != len(b) {
		return min
	}
	return -1
}

func excerpt(s string, around int) string {
	start := around - 40
	if start < 0 {
		start = 0
	}
	end := around + 40
	if end > len(s) {
		end = len(s)
	}
	return s[start:end]
}
