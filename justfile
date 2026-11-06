# nvcat: install links, dependency checks, tests, benchmarks. Run `just` for the list.

set shell := ["bash", "-euo", "pipefail", "-c"]

prefix := env("PREFIX", home_directory() / ".local")
bindir := env("BINDIR", prefix / "bin")
commands := "nvcat nvcat-dispatch"
python := "/usr/bin/python3"

# List the recipes
default:
    @just --list --unsorted

# Links, not copies: nvcat finds profile.lua, readonly.py and queries/ next to its real path.

# Generate nvcat-dispatch from this machine's bat, then link nvcat and it into BINDIR (PREFIX=... or BINDIR=...)
install: dispatch check
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p "{{ bindir }}"
    for command in {{ commands }}; do
      target="{{ bindir }}/$command"
      if [[ -e $target && ! -L $target ]]; then
        echo "$target exists and is not a symlink; move it away first" >&2
        exit 1
      fi
      ln -sfn "{{ justfile_directory() }}/$command" "$target" && echo "linked $target -> {{ justfile_directory() }}/$command"
    done

# Install shell completions for the shells on this machine; run again after updating nvcat
completions:
    #!/usr/bin/env bash
    set -euo pipefail
    nvcat="{{ justfile_directory() }}/nvcat"
    data=${XDG_DATA_HOME:-$HOME/.local/share}
    write() { mkdir -p "$(dirname "$2")" && "$nvcat" completions "$1" > "$2" && echo "wrote $2"; }
    if command -v bash >/dev/null; then write bash "$data/bash-completion/completions/nvcat"; fi
    if command -v fish >/dev/null; then write fish "${XDG_CONFIG_HOME:-$HOME/.config}/fish/completions/nvcat.fish"; fi
    if command -v zsh >/dev/null; then
      # The first directory of the user's own on zsh's fpath, which needs their zshrc; else one to add to it.
      directory=$(zsh -ic 'print -rl -- $fpath' 2>/dev/null </dev/null | grep -m1 "^$HOME/" || true)
      if [[ -n $directory ]]; then
        write zsh "$directory/_nvcat"
      else
        write zsh "$data/zsh/site-functions/_nvcat"
        echo "add to ~/.zshrc, before compinit: fpath=($data/zsh/site-functions \$fpath)"
      fi
    fi

# Remove the links install made, if they point into this checkout
uninstall:
    #!/usr/bin/env bash
    set -euo pipefail
    for command in {{ commands }}; do
      target="{{ bindir }}/$command"
      if [[ -L $target && $(readlink "$target") == "{{ justfile_directory() }}/$command" ]]; then
        rm "$target" && echo "removed $target"
      elif [[ -e $target ]]; then
        echo "skipped $target: not a link into {{ justfile_directory() }}"
      fi
    done

# Runtime dependencies and resolved configuration (nvcat --check)
check:
    @{{ python }} -c 'import sys; sys.exit("python 3.11 or later required (tomllib)") if sys.version_info < (3, 11) else None'
    @{{ python }} -c 'import msgpack' 2>/dev/null || { echo "python msgpack missing: run 'just deps' or install python3-msgpack" >&2; exit 1; }
    @./nvcat --check

# Development tools for the tests
check-dev:
    #!/usr/bin/env bash
    status=0
    for tool in bats script fzf bat less git hyperfine; do
      if command -v "$tool" >/dev/null 2>&1; then printf '  %-9s %s\n' "$tool" "$("$tool" --version 2>&1 | head -1)"
      else printf '  %-9s missing\n' "$tool"; status=1; fi
    done
    bats --version 2>/dev/null | awk '{ split($2, v, "."); if (v[1] < 1 || (v[1] == 1 && v[2] < 5)) { print "  bats 1.5 or later required"; exit 1 } }' || status=1
    exit $status

# Install the Python dependency for the current user (pip)
deps:
    {{ python }} -m pip install --user -r requirements.txt

# Run the bats suite; arguments go to bats (e.g. just test tests/dispatch.bats)
test *args="tests/":
    bats {{ args }}

# Run the bats suite as on a machine with no config file, with nvcat's default options
test-defaults *args="tests/":
    NVCAT_CONFIG=/nonexistent/nvcat/config.toml bats {{ args }}

# Run benchmarks/run (records history, updates SYNTAX.md)
bench:
    benchmarks/run

# Run benchmarks/compare (a Git ref against the working tree, also on a busy machine; records nothing)
bench-compare ref *args:
    benchmarks/compare {{ ref }} {{ args }}

# Run benchmarks/filetypes (records the baseline, updates docs/PERFORMANCE.md)
bench-filetypes *args: dispatch
    benchmarks/filetypes {{ args }}

# Run benchmarks/highlighter (the highlighter index on and off; --update rewrites docs/PERFORMANCE.md)
bench-highlighter *args:
    benchmarks/highlighter {{ args }}

# Generate nvcat-dispatch and filetypes.bat.json from the filetype tables and this machine's bat (not tracked)
dispatch:
    ./gen-dispatch

# Regenerate filetypes.regex.json and the generated SYNTAX.md sections, then nvcat-dispatch
filetypes:
    ./gen-filetypes
    ./gen-dispatch
