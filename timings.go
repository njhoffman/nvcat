package main

import (
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"time"
)

type TimingEntry struct {
	Filetype   string  `json:"filetype"`
	Lines      int     `json:"lines"`
	DurationMs float64 `json:"duration_ms"`
	LinesPerSec float64 `json:"lines_per_sec"`
	Timestamp  string  `json:"timestamp"`
}

func timingsFilePath() string {
	configDir := os.Getenv("XDG_CONFIG_HOME")
	if configDir == "" {
		home, err := os.UserHomeDir()
		if err != nil {
			configDir = filepath.Join(os.TempDir(), "nvcat")
		} else {
			configDir = filepath.Join(home, ".config")
		}
	}
	return filepath.Join(configDir, "nvcat", "timings.json")
}

func loadTimings() ([]TimingEntry, error) {
	path := timingsFilePath()
	data, err := os.ReadFile(path)
	if err != nil {
		if os.IsNotExist(err) {
			return nil, nil
		}
		return nil, err
	}
	var entries []TimingEntry
	if err := json.Unmarshal(data, &entries); err != nil {
		return nil, fmt.Errorf("failed to parse %s: %w", path, err)
	}
	return entries, nil
}

func saveTimingEntry(entry TimingEntry) error {
	entries, err := loadTimings()
	if err != nil {
		entries = nil
	}
	entries = append(entries, entry)

	path := timingsFilePath()
	if err := os.MkdirAll(filepath.Dir(path), 0755); err != nil {
		return err
	}
	data, err := json.MarshalIndent(entries, "", "  ")
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0644)
}

func recordTiming(filetype string, lines int, duration time.Duration) {
	ms := float64(duration.Microseconds()) / 1000.0
	lps := 0.0
	if duration > 0 {
		lps = float64(lines) / duration.Seconds()
	}

	entry := TimingEntry{
		Filetype:    filetype,
		Lines:       lines,
		DurationMs:  ms,
		LinesPerSec: lps,
		Timestamp:   time.Now().Format(time.RFC3339),
	}

	fmt.Fprintf(os.Stderr, "\nTime: %.1fms | %d lines | %.1f lines/sec [%s]\n",
		ms, lines, lps, filetype)

	if err := saveTimingEntry(entry); err != nil {
		fmt.Fprintf(os.Stderr, "Warning: failed to save timing data: %v\n", err)
	}
}

type filetypeStats struct {
	Filetype    string
	Runs        int
	TotalLines  int
	AvgLinesPerSec float64
	AvgDurationMs  float64
}

func printTimings() {
	entries, err := loadTimings()
	if err != nil {
		fmt.Fprintf(os.Stderr, "Error reading timings: %v\n", err)
		os.Exit(1)
	}
	if len(entries) == 0 {
		fmt.Fprintf(os.Stderr, "No timing data found. Use --time to record timings.\n")
		os.Exit(0)
	}

	byType := make(map[string][]TimingEntry)
	for _, e := range entries {
		byType[e.Filetype] = append(byType[e.Filetype], e)
	}

	var stats []filetypeStats
	for ft, ftEntries := range byType {
		var totalLPS, totalMs float64
		var totalLines int
		for _, e := range ftEntries {
			totalLPS += e.LinesPerSec
			totalMs += e.DurationMs
			totalLines += e.Lines
		}
		n := float64(len(ftEntries))
		stats = append(stats, filetypeStats{
			Filetype:       ft,
			Runs:           len(ftEntries),
			TotalLines:     totalLines,
			AvgLinesPerSec: totalLPS / n,
			AvgDurationMs:  totalMs / n,
		})
	}

	sort.Slice(stats, func(i, j int) bool {
		return stats[i].AvgLinesPerSec > stats[j].AvgLinesPerSec
	})

	fmt.Printf("%-15s %6s %10s %14s %12s\n", "Filetype", "Runs", "Lines", "Avg lines/sec", "Avg time(ms)")
	fmt.Printf("%-15s %6s %10s %14s %12s\n", "--------", "----", "-----", "-------------", "-----------")
	for _, s := range stats {
		fmt.Printf("%-15s %6d %10d %14.1f %12.1f\n",
			s.Filetype, s.Runs, s.TotalLines, s.AvgLinesPerSec, s.AvgDurationMs)
	}
}
