# nvcat: install links, dependency checks, tests, benchmarks. Run `make help`.

PREFIX ?= $(HOME)/.local
BINDIR ?= $(PREFIX)/bin
COMMANDS := nvcat nvcat-dispatch
PYTHON := /usr/bin/python3

.PHONY: help install uninstall check check-dev deps test bench bench-filetypes dispatch filetypes

help:
	@echo "make install     link $(COMMANDS) into $(BINDIR) (PREFIX=$(PREFIX))"
	@echo "make uninstall   remove those links if they point into this checkout"
	@echo "make check       runtime dependencies and resolved configuration (nvcat --check)"
	@echo "make check-dev   development tools for the tests"
	@echo "make deps        install the Python dependency for the current user (pip)"
	@echo "make test        run the bats test suite"
	@echo "make bench       run benchmarks/run (records history, updates SYNTAX.md)"
	@echo "make bench-filetypes  run benchmarks/filetypes (records the baseline, updates docs/PERFORMANCE.md)"
	@echo "make dispatch    regenerate nvcat-dispatch and filetypes.bat.json from the filetype tables and bat"
	@echo "make filetypes   regenerate filetypes.regex.json and its SYNTAX.md table, then nvcat-dispatch"

# Links, not copies: nvcat finds profile.lua, readonly.py and queries/ next to its real path.
install: check
	@mkdir -p "$(BINDIR)"
	@for command in $(COMMANDS); do \
	  target="$(BINDIR)/$$command"; \
	  if [ -e "$$target" ] && [ ! -L "$$target" ]; then \
	    echo "$$target exists and is not a symlink; move it away first" >&2; exit 1; \
	  fi; \
	  ln -sfn "$(CURDIR)/$$command" "$$target" && echo "linked $$target -> $(CURDIR)/$$command"; \
	done

uninstall:
	@for command in $(COMMANDS); do \
	  target="$(BINDIR)/$$command"; \
	  if [ -L "$$target" ] && [ "$$(readlink "$$target")" = "$(CURDIR)/$$command" ]; then \
	    rm "$$target" && echo "removed $$target"; \
	  elif [ -e "$$target" ]; then \
	    echo "skipped $$target: not a link into $(CURDIR)"; \
	  fi; \
	done

check:
	@$(PYTHON) -c 'import sys; sys.exit("python 3.11 or later required (tomllib)") if sys.version_info < (3, 11) else None'
	@$(PYTHON) -c 'import msgpack' 2>/dev/null || { echo "python msgpack missing: run 'make deps' or install python3-msgpack" >&2; exit 1; }
	@./nvcat --check

check-dev:
	@status=0; \
	for tool in bats script fzf bat less git hyperfine; do \
	  if command -v $$tool >/dev/null 2>&1; then printf '  %-6s %s\n' $$tool "$$($$tool --version 2>&1 | head -1)"; \
	  else printf '  %-6s missing\n' $$tool; status=1; fi; \
	done; \
	bats --version 2>/dev/null | awk '{ split($$2, v, "."); if (v[1] < 1 || (v[1] == 1 && v[2] < 5)) { print "  bats 1.5 or later required"; exit 1 } }' || status=1; \
	exit $$status

deps:
	$(PYTHON) -m pip install --user -r requirements.txt

test:
	bats tests/

bench:
	benchmarks/run

bench-filetypes:
	benchmarks/filetypes

dispatch:
	./gen-dispatch

filetypes:
	./gen-filetypes
	./gen-dispatch
