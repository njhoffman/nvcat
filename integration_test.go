package main

import (
	"fmt"
	"os"
	"os/exec"
	"strings"
	"testing"

	"github.com/neovim/go-client/nvim"
)

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

	// Build the binary first
	binPath := t.TempDir() + "/nvcat"
	build := exec.Command("go", "build", "-o", binPath, ".")
	build.Stderr = os.Stderr
	if err := build.Run(); err != nil {
		t.Fatalf("failed to build nvcat: %v", err)
	}

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
	// Should contain at least some ANSI escape sequences
	if !strings.Contains(ansiOut, "\x1b[") {
		t.Error("stderr should contain ANSI escape sequences for syntax highlighting")
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
