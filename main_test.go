package main

import (
	"testing"
)

func TestRgbToAnsi(t *testing.T) {
	tests := []struct {
		name  string
		color uint64
		want  string
	}{
		{"red", 0xFF0000, "\x1b[38;2;255;0;0m"},
		{"green", 0x00FF00, "\x1b[38;2;0;255;0m"},
		{"blue", 0x0000FF, "\x1b[38;2;0;0;255m"},
		{"white", 0xFFFFFF, "\x1b[38;2;255;255;255m"},
		{"black", 0x000000, "\x1b[38;2;0;0;0m"},
		{"tokyonight_blue", 0x7AA2F7, "\x1b[38;2;122;162;247m"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := rgbToAnsi(tt.color)
			if got != tt.want {
				t.Errorf("rgbToAnsi(0x%06X) = %q, want %q", tt.color, got, tt.want)
			}
		})
	}
}

func TestRgbToAnsiBg(t *testing.T) {
	tests := []struct {
		name  string
		color uint64
		want  string
	}{
		{"red", 0xFF0000, "\x1b[48;2;255;0;0m"},
		{"green", 0x00FF00, "\x1b[48;2;0;255;0m"},
		{"blue", 0x0000FF, "\x1b[48;2;0;0;255m"},
		{"white", 0xFFFFFF, "\x1b[48;2;255;255;255m"},
		{"black", 0x000000, "\x1b[48;2;0;0;0m"},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got := rgbToAnsiBg(tt.color)
			if got != tt.want {
				t.Errorf("rgbToAnsiBg(0x%06X) = %q, want %q", tt.color, got, tt.want)
			}
		})
	}
}

func TestGetAnsiFromHl(t *testing.T) {
	tests := []struct {
		name string
		hl   map[string]any
		want string
	}{
		{
			name: "empty_returns_reset",
			hl:   map[string]any{},
			want: AnsiReset,
		},
		{
			name: "fg_only",
			hl:   map[string]any{"fg": uint64(0xFF0000)},
			want: "\x1b[38;2;255;0;0m",
		},
		{
			name: "bg_only",
			hl:   map[string]any{"bg": uint64(0x00FF00)},
			want: "\x1b[48;2;0;255;0m",
		},
		{
			name: "fg_and_bg",
			hl: map[string]any{
				"fg": uint64(0xFF0000),
				"bg": uint64(0x00FF00),
			},
			want: "\x1b[38;2;255;0;0m\x1b[48;2;0;255;0m",
		},
		{
			name: "bold",
			hl:   map[string]any{"bold": true},
			want: AnsiBold,
		},
		{
			name: "italic",
			hl:   map[string]any{"italic": true},
			want: AnsiItalic,
		},
		{
			name: "underline",
			hl:   map[string]any{"underline": true},
			want: AnsiUnderline,
		},
		{
			name: "all_attributes",
			hl: map[string]any{
				"fg":        uint64(0x7AA2F7),
				"bg":        uint64(0x1A1B26),
				"bold":      true,
				"italic":    true,
				"underline": true,
			},
			want: "\x1b[38;2;122;162;247m\x1b[48;2;26;27;38m" + AnsiBold + AnsiItalic + AnsiUnderline,
		},
		{
			name: "false_bold_ignored",
			hl:   map[string]any{"bold": false},
			want: AnsiReset,
		},
		{
			name: "wrong_type_fg_ignored",
			hl:   map[string]any{"fg": "not_a_number"},
			want: AnsiReset,
		},
		{
			name: "wrong_type_bg_ignored",
			hl:   map[string]any{"bg": int64(0xFF0000)},
			want: AnsiReset,
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			got, err := getAnsiFromHl(tt.hl)
			if err != nil {
				t.Fatalf("getAnsiFromHl() returned error: %v", err)
			}
			if got != tt.want {
				t.Errorf("getAnsiFromHl(%v) = %q, want %q", tt.hl, got, tt.want)
			}
		})
	}
}

func BenchmarkRgbToAnsi(b *testing.B) {
	for b.Loop() {
		rgbToAnsi(0x7AA2F7)
	}
}

func BenchmarkRgbToAnsiBg(b *testing.B) {
	for b.Loop() {
		rgbToAnsiBg(0x1A1B26)
	}
}

func BenchmarkGetAnsiFromHl_FgOnly(b *testing.B) {
	hl := map[string]any{"fg": uint64(0x7AA2F7)}
	for b.Loop() {
		getAnsiFromHl(hl)
	}
}

func BenchmarkGetAnsiFromHl_AllAttrs(b *testing.B) {
	hl := map[string]any{
		"fg":        uint64(0x7AA2F7),
		"bg":        uint64(0x1A1B26),
		"bold":      true,
		"italic":    true,
		"underline": true,
	}
	for b.Loop() {
		getAnsiFromHl(hl)
	}
}

func BenchmarkGetAnsiFromHl_Empty(b *testing.B) {
	hl := map[string]any{}
	for b.Loop() {
		getAnsiFromHl(hl)
	}
}
