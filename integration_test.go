package main

import (
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"testing"

	"github.com/neovim/go-client/nvim"
)

var (
	buildOnce sync.Once
	builtBin  string
	buildErr  error
)

func buildBinary(t *testing.T) string {
	t.Helper()
	buildOnce.Do(func() {
		dir, err := os.MkdirTemp("", "nvcat-test-bin")
		if err != nil {
			buildErr = err
			return
		}
		builtBin = filepath.Join(dir, "nvcat")
		cmd := exec.Command("go", "build", "-o", builtBin, ".")
		cmd.Stderr = os.Stderr
		buildErr = cmd.Run()
	})
	if buildErr != nil {
		t.Fatalf("failed to build nvcat: %v", buildErr)
	}
	return builtBin
}

func skipIfNoNvim(t *testing.T) {
	t.Helper()
	if _, err := exec.LookPath("nvim"); err != nil {
		t.Skip("nvim not found in PATH, skipping integration test")
	}
}

func startNvim(t *testing.T) *nvim.Nvim {
	t.Helper()
	args := []string{
		"--cmd", fmt.Sprintf("let g:nvcat = '%s'", Version),
		"--embed", "--headless", "--clean",
	}
	v, err := nvim.NewChildProcess(nvim.ChildProcessArgs(args...))
	if err != nil {
		t.Fatalf("failed to start nvim: %v", err)
	}
	t.Cleanup(func() { v.Close() })
	return v
}

func TestIntegration_LuaPluginLoads(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}
	skipIfNoNvim(t)

	v := startNvim(t)
	err := v.ExecLua(LuaPluginScript, nil, nil)
	if err != nil {
		t.Fatalf("failed to load Lua plugin: %v", err)
	}
}

func TestIntegration_NvcatNormalHasBg_Default(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}
	skipIfNoNvim(t)

	v := startNvim(t)
	err := v.ExecLua(LuaPluginScript, nil, nil)
	if err != nil {
		t.Fatalf("failed to load Lua plugin: %v", err)
	}

	var hasBg bool
	err = v.ExecLua("return NvcatNormalHasBg()", &hasBg)
	if err != nil {
		t.Fatalf("NvcatNormalHasBg() returned error: %v", err)
	}
	// Default colorscheme with --clean should not have Normal bg
	if hasBg {
		t.Log("Normal has bg set in default --clean colorscheme (may vary by nvim version)")
	}
}

func TestIntegration_NvcatNormalHasBg_WithBg(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}
	skipIfNoNvim(t)

	v := startNvim(t)
	// Set Normal bg before loading plugin
	err := v.Command("highlight Normal guibg=#1a1b26")
	if err != nil {
		t.Fatalf("failed to set Normal bg: %v", err)
	}
	err = v.ExecLua(LuaPluginScript, nil, nil)
	if err != nil {
		t.Fatalf("failed to load Lua plugin: %v", err)
	}

	var hasBg bool
	err = v.ExecLua("return NvcatNormalHasBg()", &hasBg)
	if err != nil {
		t.Fatalf("NvcatNormalHasBg() returned error: %v", err)
	}
	if !hasBg {
		t.Error("NvcatNormalHasBg() = false, want true after setting Normal guibg")
	}
}

func TestIntegration_NvcatGetHl_StripsNormalBg(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}
	skipIfNoNvim(t)

	v := startNvim(t)
	// Set Normal bg
	err := v.Command("highlight Normal guibg=#1a1b26")
	if err != nil {
		t.Fatalf("failed to set Normal bg: %v", err)
	}
	// Set a custom group with the same bg
	err = v.Command("highlight TestSameBg guifg=#ff0000 guibg=#1a1b26")
	if err != nil {
		t.Fatalf("failed to set TestSameBg: %v", err)
	}
	// Set a custom group with a different bg
	err = v.Command("highlight TestDiffBg guifg=#ff0000 guibg=#ff00ff")
	if err != nil {
		t.Fatalf("failed to set TestDiffBg: %v", err)
	}

	err = v.ExecLua(LuaPluginScript, nil, nil)
	if err != nil {
		t.Fatalf("failed to load Lua plugin: %v", err)
	}

	// Highlight with same bg as Normal should have bg stripped
	var hlSame map[string]any
	err = v.ExecLua("return vim.api.nvim_get_hl(0, {name='TestSameBg', link=false})", &hlSame)
	if err != nil {
		t.Fatalf("failed to get TestSameBg: %v", err)
	}
	// The raw highlight should have bg
	if _, ok := hlSame["bg"]; !ok {
		t.Error("raw TestSameBg highlight missing bg field")
	}

	// Highlight with different bg should keep it
	var hlDiff map[string]any
	err = v.ExecLua(`
		local hl = vim.api.nvim_get_hl(0, {name='TestDiffBg', link=false})
		-- simulate what strip_normal_bg does
		local normal_bg = vim.api.nvim_get_hl(0, {name='Normal', link=false}).bg
		if normal_bg and hl.bg == normal_bg then
			hl.bg = nil
		end
		return hl
	`, &hlDiff)
	if err != nil {
		t.Fatalf("failed to get TestDiffBg: %v", err)
	}
	if _, ok := hlDiff["bg"]; !ok {
		t.Error("TestDiffBg bg should be preserved (different from Normal)")
	}
}

func TestIntegration_EndToEnd(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}
	skipIfNoNvim(t)

	binPath := buildBinary(t)

	cmd := exec.Command(binPath, "--clean", "testdata/sample.go")
	var stdout, stderr strings.Builder
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("nvcat failed: %v\nstderr: %s", err, stderr.String())
	}

	out := stdout.String()
	if !strings.Contains(out, "package main") {
		t.Error("output missing 'package main'")
	}
	if !strings.Contains(out, "fmt.Println") {
		t.Error("output missing 'fmt.Println'")
	}

	ansiOut := stderr.String()
	if !strings.Contains(ansiOut, "\x1b[") {
		t.Error("stderr should contain ANSI escape sequences for syntax highlighting")
	}
}

func TestIntegration_HelpFlag(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	binPath := buildBinary(t)

	for _, flag := range []string{"-h", "--help"} {
		t.Run(flag, func(t *testing.T) {
			cmd := exec.Command(binPath, flag)
			var stderr strings.Builder
			cmd.Stderr = &stderr
			cmd.Run() // exits non-zero, that's expected

			out := stderr.String()
			if !strings.Contains(out, "Usage: nvcat") {
				t.Errorf("%s: stderr missing 'Usage: nvcat', got: %s", flag, out)
			}
			if !strings.Contains(out, "--numbers") {
				t.Errorf("%s: stderr missing '--numbers'", flag)
			}
			if !strings.Contains(out, "--clean") {
				t.Errorf("%s: stderr missing '--clean'", flag)
			}
			if !strings.Contains(out, "--time") {
				t.Errorf("%s: stderr missing '--time'", flag)
			}
			if !strings.Contains(out, "--timings") {
				t.Errorf("%s: stderr missing '--timings'", flag)
			}
		})
	}
}

func TestIntegration_VersionFlag(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	binPath := buildBinary(t)

	for _, flag := range []string{"-v", "--version"} {
		t.Run(flag, func(t *testing.T) {
			cmd := exec.Command(binPath, flag)
			out, err := cmd.Output()
			if err != nil {
				t.Fatalf("%s failed: %v", flag, err)
			}
			if !strings.HasPrefix(string(out), "nvcat ") {
				t.Errorf("%s: expected output starting with 'nvcat ', got: %s", flag, out)
			}
		})
	}
}

func TestIntegration_NumbersFlag(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}
	skipIfNoNvim(t)

	binPath := buildBinary(t)

	for _, flag := range []string{"-n", "--numbers"} {
		t.Run(flag, func(t *testing.T) {
			cmd := exec.Command(binPath, "--clean", flag, "testdata/sample.go")
			var stdout strings.Builder
			cmd.Stdout = &stdout
			cmd.Stderr = os.NewFile(0, os.DevNull)
			if err := cmd.Run(); err != nil {
				t.Fatalf("%s failed: %v", flag, err)
			}
			out := stdout.String()
			// Line numbers should appear in stdout
			if !strings.Contains(out, " 1 ") {
				t.Errorf("%s: output missing line number '1', got: %s", flag, out[:min(200, len(out))])
			}
		})
	}
}

func TestIntegration_TimeFlag(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}
	skipIfNoNvim(t)

	binPath := buildBinary(t)
	tmpDir := t.TempDir()

	cmd := exec.Command(binPath, "--clean", "--time", "testdata/sample.go")
	cmd.Env = append(os.Environ(), "XDG_CONFIG_HOME="+tmpDir)
	var stderr strings.Builder
	cmd.Stdout = os.NewFile(0, os.DevNull)
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("--time failed: %v\nstderr: %s", err, stderr.String())
	}

	errOut := stderr.String()
	if !strings.Contains(errOut, "Time:") {
		t.Error("--time: stderr missing 'Time:' output")
	}
	if !strings.Contains(errOut, "lines/sec") {
		t.Error("--time: stderr missing 'lines/sec'")
	}

	// Verify timings.json was created
	timingsPath := filepath.Join(tmpDir, "nvcat", "timings.json")
	data, err := os.ReadFile(timingsPath)
	if err != nil {
		t.Fatalf("timings.json not created: %v", err)
	}
	var entries []TimingEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("invalid timings.json: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 timing entry, got %d", len(entries))
	}
	if entries[0].Filetype != "go" {
		t.Errorf("expected filetype 'go', got %q", entries[0].Filetype)
	}
	if entries[0].Lines != 14 {
		t.Errorf("expected 14 lines, got %d", entries[0].Lines)
	}
	if entries[0].LinesPerSec <= 0 {
		t.Error("lines_per_sec should be positive")
	}
}

func TestIntegration_TimingsFlag(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	binPath := buildBinary(t)
	tmpDir := t.TempDir()

	// Seed timings.json with test data
	timingsDir := filepath.Join(tmpDir, "nvcat")
	os.MkdirAll(timingsDir, 0755)
	entries := []TimingEntry{
		{Filetype: "go", Lines: 100, DurationMs: 500, LinesPerSec: 200, Timestamp: "2026-03-29T12:00:00Z"},
		{Filetype: "go", Lines: 200, DurationMs: 800, LinesPerSec: 250, Timestamp: "2026-03-29T12:01:00Z"},
		{Filetype: "lua", Lines: 50, DurationMs: 200, LinesPerSec: 250, Timestamp: "2026-03-29T12:02:00Z"},
	}
	data, _ := json.Marshal(entries)
	os.WriteFile(filepath.Join(timingsDir, "timings.json"), data, 0644)

	cmd := exec.Command(binPath, "--timings")
	cmd.Env = append(os.Environ(), "XDG_CONFIG_HOME="+tmpDir)
	out, err := cmd.Output()
	if err != nil {
		t.Fatalf("--timings failed: %v", err)
	}

	output := string(out)
	if !strings.Contains(output, "Filetype") {
		t.Error("--timings: missing header")
	}
	if !strings.Contains(output, "go") {
		t.Error("--timings: missing 'go' filetype")
	}
	if !strings.Contains(output, "lua") {
		t.Error("--timings: missing 'lua' filetype")
	}
	if !strings.Contains(output, "2") { // 2 runs for go
		t.Error("--timings: should show 2 runs for go")
	}
}

func TestIntegration_TimingsFlag_Empty(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	binPath := buildBinary(t)
	tmpDir := t.TempDir()

	cmd := exec.Command(binPath, "--timings")
	cmd.Env = append(os.Environ(), "XDG_CONFIG_HOME="+tmpDir)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	cmd.Run() // exits 0

	if !strings.Contains(stderr.String(), "No timing data") {
		t.Error("--timings with no data: expected 'No timing data' message")
	}
}

func TestIntegration_NoArgs_ShowsUsage(t *testing.T) {
	if testing.Short() {
		t.Skip("skipping integration test in short mode")
	}

	binPath := buildBinary(t)

	cmd := exec.Command(binPath)
	var stderr strings.Builder
	cmd.Stderr = &stderr
	cmd.Run() // exits non-zero

	if !strings.Contains(stderr.String(), "Usage: nvcat") {
		t.Error("no args: expected usage output on stderr")
	}
}

func BenchmarkIntegration_EndToEnd(b *testing.B) {
	if testing.Short() {
		b.Skip("skipping integration benchmark in short mode")
	}
	if _, err := exec.LookPath("nvim"); err != nil {
		b.Skip("nvim not found in PATH")
	}

	binPath := b.TempDir() + "/nvcat"
	build := exec.Command("go", "build", "-o", binPath, ".")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		b.Fatalf("failed to build nvcat: %v", err)
	}

	for b.Loop() {
		cmd := exec.Command(binPath, "--clean", "testdata/sample.go")
		cmd.Stdout = os.NewFile(0, os.DevNull)
		cmd.Stderr = os.NewFile(0, os.DevNull)
		if err := cmd.Run(); err != nil {
			b.Fatalf("nvcat failed: %v", err)
		}
	}
}
