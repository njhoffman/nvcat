#!/usr/bin/env bats
# Ported from the historical check-languages.py: every code-fence language and alias is highlighted.

@test "every fence language and alias gets 3+ colors including String at 80 columns" {
  run python3 "$BATS_TEST_DIRNAME/helpers/languages.py" 80
  [ "$status" -eq 0 ] || { echo "$output" | tail -5; return 1; }
  [ "$(grep -cE '^(ok|skip) ' <<<"$output")" -eq 15 ]
}

@test "the same at 120 columns" {
  run python3 "$BATS_TEST_DIRNAME/helpers/languages.py" 120
  [ "$status" -eq 0 ] || { echo "$output" | tail -5; return 1; }
  [ "$(grep -cE '^(ok|skip) ' <<<"$output")" -eq 15 ]
}
