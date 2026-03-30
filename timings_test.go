package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
	"time"
)

func TestTimingsFilePath(t *testing.T) {
	// With XDG_CONFIG_HOME set
	t.Setenv("XDG_CONFIG_HOME", "/tmp/test-xdg")
	got := timingsFilePath()
	want := "/tmp/test-xdg/nvcat/timings.json"
	if got != want {
		t.Errorf("timingsFilePath() = %q, want %q", got, want)
	}

	// Without XDG_CONFIG_HOME
	t.Setenv("XDG_CONFIG_HOME", "")
	got = timingsFilePath()
	home, _ := os.UserHomeDir()
	want = filepath.Join(home, ".config", "nvcat", "timings.json")
	if got != want {
		t.Errorf("timingsFilePath() = %q, want %q", got, want)
	}
}

func TestLoadTimings_NoFile(t *testing.T) {
	t.Setenv("XDG_CONFIG_HOME", t.TempDir())
	entries, err := loadTimings()
	if err != nil {
		t.Fatalf("loadTimings() error: %v", err)
	}
	if entries != nil {
		t.Errorf("expected nil entries for missing file, got %v", entries)
	}
}

func TestSaveAndLoadTimings(t *testing.T) {
	tmpDir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmpDir)

	entry1 := TimingEntry{
		Filetype:    "go",
		Lines:       100,
		DurationMs:  500.0,
		LinesPerSec: 200.0,
		Timestamp:   time.Now().Format(time.RFC3339),
	}
	if err := saveTimingEntry(entry1); err != nil {
		t.Fatalf("saveTimingEntry() error: %v", err)
	}

	entry2 := TimingEntry{
		Filetype:    "lua",
		Lines:       50,
		DurationMs:  200.0,
		LinesPerSec: 250.0,
		Timestamp:   time.Now().Format(time.RFC3339),
	}
	if err := saveTimingEntry(entry2); err != nil {
		t.Fatalf("saveTimingEntry() error: %v", err)
	}

	entries, err := loadTimings()
	if err != nil {
		t.Fatalf("loadTimings() error: %v", err)
	}
	if len(entries) != 2 {
		t.Fatalf("expected 2 entries, got %d", len(entries))
	}
	if entries[0].Filetype != "go" {
		t.Errorf("entries[0].Filetype = %q, want %q", entries[0].Filetype, "go")
	}
	if entries[1].Filetype != "lua" {
		t.Errorf("entries[1].Filetype = %q, want %q", entries[1].Filetype, "lua")
	}
}

func TestLoadTimings_InvalidJSON(t *testing.T) {
	tmpDir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmpDir)

	path := filepath.Join(tmpDir, "nvcat", "timings.json")
	os.MkdirAll(filepath.Dir(path), 0755)
	os.WriteFile(path, []byte("not json"), 0644)

	_, err := loadTimings()
	if err == nil {
		t.Error("expected error for invalid JSON, got nil")
	}
}

func TestSaveTimingEntry_JSONStructure(t *testing.T) {
	tmpDir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", tmpDir)

	entry := TimingEntry{
		Filetype:    "python",
		Lines:       200,
		DurationMs:  1000.0,
		LinesPerSec: 200.0,
		Timestamp:   "2026-03-29T12:00:00Z",
	}
	if err := saveTimingEntry(entry); err != nil {
		t.Fatalf("saveTimingEntry() error: %v", err)
	}

	data, err := os.ReadFile(filepath.Join(tmpDir, "nvcat", "timings.json"))
	if err != nil {
		t.Fatalf("ReadFile error: %v", err)
	}

	var entries []TimingEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		t.Fatalf("JSON unmarshal error: %v", err)
	}
	if len(entries) != 1 {
		t.Fatalf("expected 1 entry, got %d", len(entries))
	}
	if entries[0].Filetype != "python" || entries[0].Lines != 200 {
		t.Errorf("unexpected entry: %+v", entries[0])
	}
}
