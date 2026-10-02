package main

import (
	"os"
	"os/exec"
	"testing"

	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

// runMainEnv makes the test binary execute main() instead of the tests, so that the command line flags are parsed
// exactly like they are when the program is run by the GitHub action.
const runMainEnv = "GO_COVERAGE_REPORT_RUN_MAIN"

func TestMain(m *testing.M) {
	if os.Getenv(runMainEnv) == "1" {
		main()
		os.Exit(0)
	}
	os.Exit(m.Run())
}

func TestMainFlags(t *testing.T) {
	tests := []struct {
		name  string
		flags []string
	}{
		{"with projectPath flag", []string{"-root=github.com/fgrosse/prioqueue", "-projectPath="}},
		{"without projectPath flag", []string{"-root=github.com/fgrosse/prioqueue"}},
	}

	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			args := append(tt.flags,
				"testdata/01-old-coverage.txt",
				"testdata/01-new-coverage.txt",
				"testdata/01-changed-files.json",
			)

			cmd := exec.Command(os.Args[0], args...)
			cmd.Env = append(os.Environ(), runMainEnv+"=1")
			out, err := cmd.CombinedOutput()

			require.NoError(t, err, "output: %s", out)
			assert.Contains(t, string(out), "Coverage Δ")
		})
	}
}
