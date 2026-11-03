local hrtime = vim.uv.hrtime
-- timings: {name, milliseconds} per phase in first-recorded order, summed over repeats (nvcat --timings).
-- marks: hrtime (CLOCK_MONOTONIC nanoseconds) when this profile was sourced and when setup began, so nvcat
-- can split Neovim's startup.
local M = { token = 0, timings = {}, marks = { profile = hrtime() }, warnings = {} }
_G.nvcat = M

-- Add the time since start (an hrtime) to phase name; returns now, so consecutive phases can chain.
local function lap(name, start)
  local now = hrtime()
  for _, entry in ipairs(M.timings) do
    if entry[1] == name then
      entry[2] = entry[2] + (now - start) / 1e6
      return now
    end
  end
  table.insert(M.timings, { name, (now - start) / 1e6 })
  return now
end

for name, value in pairs({
  shadafile = "NONE", swapfile = false, undofile = false, backup = false,
  writebackup = false, modeline = false, readonly = true, number = false,
  relativenumber = false, signcolumn = "no", foldcolumn = "0", foldenable = false,
  laststatus = 0, showtabline = 0, showmode = false, ruler = false, cmdheight = 0,
  termguicolors = true, wrap = true, linebreak = true, list = false,
  cursorline = false, scrolloff = 0, sidescrolloff = 0, report = 999999,
}) do
  vim.o[name] = value
end
vim.opt.fillchars = { eob = " " }
vim.g.loaded_python3_provider = 0
vim.g.loaded_node_provider = 0
vim.g.loaded_ruby_provider = 0
vim.g.loaded_perl_provider = 0

local function notify_ready(win)
  local token = M.token
  if M.update_started then
    lap("render", M.update_started)
    M.update_started = nil
  end
  local scheduled = hrtime()
  vim.schedule(function()
    if token ~= M.token then
      return
    end
    -- render-markdown calls on.render three times per Markdown frame, and each redraws (see PERFORMANCE.md).
    M.callbacks = (M.callbacks or 0) + 1
    -- Other queued work (render-markdown's own callbacks, Tree-sitter's async parsing) runs before this.
    local start = lap("queued", scheduled)
    vim.cmd("redraw")
    lap("redraw", start)
    vim.rpcnotify(M.channel, "nvcat_ready", {
      token = token,
      buffer = vim.api.nvim_get_current_buf(),
      topline = vim.fn.winsaveview().topline,
      width = vim.api.nvim_win_get_width(win),
      height = vim.api.nvim_win_get_height(win),
    })
  end)
end

-- Read render-markdown options from a file that either calls require("render-markdown").setup(opts), as an
-- editor config does, or returns the options table. The editor's plugin manager is never started.
local function markdown_options(file)
  if not file then
    return {}
  end
  local captured
  package.loaded["render-markdown"] = { setup = function(value) captured = value end }
  local ok, returned = pcall(dofile, file)
  package.loaded["render-markdown"] = nil
  assert(ok, "markdown_options " .. file .. ": " .. tostring(returned))
  local options = captured or (type(returned) == "table" and returned)
  assert(options, "markdown_options " .. file .. " neither called setup() nor returned a table")
  return options
end

-- "Query error at 1:2. Invalid node type "x"" from an error raised with a Lua location and a source excerpt.
local function first_line(err)
  return (tostring(err):gsub("^.-%.lua:%d+: ", ""):match("^[^\n]*"):gsub(":$", ""))
end

-- The compile error of a query, naming the file that causes it (each of the query's files compiled alone).
local function query_problem(lang, name, err)
  for _, file in ipairs(vim.treesitter.query.get_files(lang, name)) do
    local handle = io.open(file, "r")
    if handle then
      local ok, file_err = pcall(vim.treesitter.query.parse, lang, handle:read("*a"))
      handle:close()
      if not ok then
        return first_line(file_err) .. " in " .. file
      end
    end
  end
  return first_line(err)
end

-- A query written for another version of its parser fails to compile ("Invalid node type"). Neovim's
-- ftplugins, the highlighter and injections all call query.get, so the error would abort the render with a
-- stack trace. Report it once as a warning and treat the query as missing: the language loses Tree-sitter
-- highlighting (highlight() switches it to regex syntax) and the rest of the document still renders.
local get_query = vim.treesitter.query.get
local reported = {}
local function guarded_get(lang, name)
  local ok, result = pcall(get_query, lang, name)
  if ok then
    return result
  end
  local key = lang .. "/" .. name
  if not reported[key] then
    reported[key] = true
    local problem = query_problem(lang, name, result)
    local advice = problem:find("Query error", 1, true)
        and "; update the " .. lang .. " parser and its queries together (see parser_dir in nvcat --check)"
      or ""
    table.insert(M.warnings, ("%s %s query failed: %s%s"):format(lang, name, problem, advice))
  end
  return nil
end
-- query.get is a memoized callable table on recent Neovim (query.set calls get:clear()), a function before.
if type(get_query) == "table" then
  vim.treesitter.query.get = setmetatable({}, {
    __index = get_query,
    __call = function(_, lang, name) return guarded_get(lang, name) end,
  })
else
  vim.treesitter.query.get = guarded_get
end

-- A parser file that exists but does not load (built for another Tree-sitter ABI, corrupt, missing symbol)
-- makes language.add raise. Report it once as a warning and keep raising, since Neovim's injection code tests
-- for a usable parser with pcall(language.add). A missing parser returns nil and is not reported; --check
-- lists those languages.
local add_language = vim.treesitter.language.add
vim.treesitter.language.add = function(lang, opts)
  local ok, loaded, err = pcall(add_language, lang, opts)
  if ok then
    return loaded, err
  end
  if not reported["parser/" .. lang] then
    reported["parser/" .. lang] = true
    local message = first_line(loaded)
    local advice = message:find("ABI version mismatch", 1, true)
        and "; rebuild it for this Neovim or update Neovim (see parser_dir in nvcat --check)"
      or "; reinstall it (see parser_dir in nvcat --check)"
    table.insert(M.warnings, ("%s parser failed to load: %s%s"):format(lang, message, advice))
  end
  error(loaded, 0)
end

local function parser_loads(lang)
  local ok, loaded = pcall(vim.treesitter.language.add, lang)
  return ok and loaded == true
end

-- ftplugins such as Neovim's own for Lua call vim.treesitter.start() unguarded, which raises without a
-- parser that loads; skip it then, so the buffer keeps regex syntax.
local start_treesitter = vim.treesitter.start
vim.treesitter.start = function(buf, lang)
  local buffer = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local name = lang or vim.treesitter.language.get_lang(vim.bo[buffer].filetype)
  if name and not parser_loads(name) then
    return
  end
  return start_treesitter(buf, lang)
end

-- Neovim's Tree-sitter highlighter (0.12 and later) calls on_range_impl for each drawn line, and that visits
-- every highlight state, one per tree in the window. Markdown injects a tree per inline span and code block,
-- so a long table visits thousands of states per line, and under 1% of those visits touch the line. Narrow
-- the list each call sees to the states whose root covers the range's rows, plus the first state starting
-- after them, which on_range_impl needs to report where the next tree begins. The states keep their order,
-- so extmark priorities and output are unchanged.
--
-- Neovim then also gets an accurate skip-ahead position. The stock loop includes trees that end above the
-- line in its minimum, so the position it returns is behind the line and Neovim calls on_range again for the
-- next one. Narrowed, the position is the next capture or tree start, and Neovim makes fewer calls.
--
-- These are private internals, so the patch checks each one it relies on and leaves the highlighter alone
-- when one is missing. NVCAT_HIGHLIGHT_INDEX=0 turns it off. Returns "on", "off", or "unavailable: <reason>",
-- shown as highlight_index in --timings.
local SPAN_LIMIT = 64 -- Ranges spanning more rows than this keep the full list.

local function upvalue(fn, wanted)
  for slot = 1, math.huge do
    local name, value = debug.getupvalue(fn, slot)
    if name == nil then
      return nil
    end
    if name == wanted then
      return slot, value
    end
  end
end

local function uses(fn, names)
  local ok, code = pcall(string.dump, fn)
  if not ok then
    return names[1]
  end
  for _, name in ipairs(names) do
    if not code:find(name, 1, true) then
      return name
    end
  end
end

function M.index_highlighter()
  if vim.env.NVCAT_HIGHLIGHT_INDEX == "0" then
    return "off"
  end
  local ok, H = pcall(require, "vim.treesitter.highlighter")
  if not ok or type(H) ~= "table" then
    return "unavailable: vim.treesitter.highlighter does not load"
  end
  if H._nvcat_indexed then
    return "on"
  end
  for _, name in ipairs({ "_on_range", "prepare_highlight_states", "for_each_highlight_state" }) do
    if type(H[name]) ~= "function" then
      return "unavailable: TSHighlighter." .. name .. " is missing"
    end
  end
  local slot, impl = upvalue(H._on_range, "on_range_impl")
  if type(impl) ~= "function" then
    return "unavailable: TSHighlighter._on_range does not call on_range_impl"
  end
  local missing = uses(impl, { "for_each_highlight_state", "tstree", "intercepts" })
    or uses(H.for_each_highlight_state, { "_highlight_states" })
    or uses(H.prepare_highlight_states, { "_highlight_states", "tstree" })
  if missing then
    return "unavailable: the highlighter no longer uses " .. missing
  end

  -- Per list of states, as prepare_highlight_states made it: the rows it covers and, built on first use,
  -- the per-row state indexes and the states ordered by root start.
  local bounds = setmetatable({}, { __mode = "k" })
  local indexes = setmetatable({}, { __mode = "k" })
  local prepare = H.prepare_highlight_states
  H.prepare_highlight_states = function(self, srow, erow)
    prepare(self, srow, erow)
    if type(self._highlight_states) == "table" then
      bounds[self._highlight_states] = { srow, erow }
    end
  end

  local function build(states, srow, erow)
    local rows, starts = {}, {}
    for i, state in ipairs(states) do
      local sr, sc, er = state.tstree:root():range()
      for row = math.max(sr, srow), math.min(er, erow) do
        local list = rows[row]
        if not list then
          list = {}
          rows[row] = list
        end
        list[#list + 1] = i
      end
      starts[#starts + 1] = { sr, sc, i }
    end
    table.sort(starts, function(a, b)
      if a[1] ~= b[1] then
        return a[1] < b[1]
      end
      if a[2] ~= b[2] then
        return a[2] < b[2]
      end
      return a[3] < b[3]
    end)
    return { rows = rows, starts = starts }
  end

  -- The states for rows br..er in their original order, or nil to keep the full list.
  local function narrow(states, br, er)
    local window = bounds[states]
    if not window or br < window[1] or er > window[2] or er - br > SPAN_LIMIT then
      return nil
    end
    local index = indexes[states]
    if not index then
      index = build(states, window[1], window[2])
      indexes[states] = index
    end
    local chosen, seen = {}, {}
    for row = br, er do
      for _, i in ipairs(index.rows[row] or {}) do
        if not seen[i] then
          seen[i] = true
          chosen[#chosen + 1] = i
        end
      end
    end
    -- The first state starting below the range (binary search over the starts).
    local starts, low, high = index.starts, 1, #index.starts + 1
    while low < high do
      local middle = math.floor((low + high) / 2)
      if starts[middle][1] > er then
        high = middle
      else
        low = middle + 1
      end
    end
    if starts[low] and not seen[starts[low][3]] then
      chosen[#chosen + 1] = starts[low][3]
    end
    table.sort(chosen)
    local narrowed = {}
    for k, i in ipairs(chosen) do
      narrowed[k] = states[i]
    end
    return narrowed
  end

  local function indexed(self, buf, br, bc, er, ec, ...)
    local states = self._highlight_states
    local narrowed = type(states) == "table" and narrow(states, br, er)
    if not narrowed then
      return impl(self, buf, br, bc, er, ec, ...)
    end
    self._highlight_states = narrowed
    local done, row, col = pcall(impl, self, buf, br, bc, er, ec, ...)
    self._highlight_states = states
    if not done then
      error(row, 0)
    end
    return row, col
  end
  debug.setupvalue(H._on_range, slot, indexed)
  H._nvcat_indexed = true
  return "on"
end

-- paths: settings from config.py runtime_paths(); every key except render_markdown may be nil.
-- channel: the RPC channel for the screen grab, or nil for the pager.
function M.setup(channel, paths)
  if vim.fn.has("nvim-0.11") == 0 then
    error(("Neovim 0.11 or later is required, found %s"):format(tostring(vim.version())), 0)
  end
  local start = hrtime()
  M.marks.setup = start
  M.channel = channel
  vim.opt.runtimepath:append(paths.render_markdown)
  if paths.icons then
    vim.opt.runtimepath:append(paths.icons)
  end
  vim.opt.runtimepath:append(paths.root) -- queries/ shipped with nvcat
  -- Prefer an installed parser/query directory over stale copies in plugin checkouts and the bundled ones.
  if paths.parser_dir then
    vim.opt.runtimepath:prepend(paths.parser_dir)
  end
  vim.treesitter.language.register("cpp", { "cxx", "cc" })
  vim.treesitter.language.register("bash", { "sh", "shell" })
  vim.treesitter.language.register("javascript", "js")
  vim.treesitter.language.register("python", "py")
  if paths.lua_path then
    package.path = paths.lua_path .. "/?.lua;" .. paths.lua_path .. "/?/init.lua;" .. package.path
  end
  start = lap("setup: runtimepath", start)
  M.highlight_index = M.index_highlighter()
  start = lap("setup: highlighter index", start)
  vim.cmd("highlight clear")
  if paths.theme then
    dofile(paths.theme).apply()
  elseif paths.colorscheme then
    vim.cmd.colorscheme(paths.colorscheme)
  end
  start = lap("setup: theme", start)

  local config = markdown_options(paths.markdown_options)
  -- render-markdown's debounce is a throttle: an update within `debounce` ms of the previous one is
  -- dropped, so the forced update after an --all resize could vanish and the render never signalled.
  config.debounce = 0
  config.log_level = "error"
  config.log_runtime = false
  config.completions = { lsp = { enabled = false } }
  -- --syntax regex: keep render-markdown off Markdown buffers. The flag is set before :edit, whose filetype
  -- detection already attaches the plugin.
  local ignore = config.ignore
  config.ignore = function(buf)
    return M.syntax == "regex" or not parser_loads("markdown") or (ignore ~= nil and ignore(buf) or false)
  end
  if M.channel then
    config.on = {
      render = function(context)
        if context.buf == vim.api.nvim_get_current_buf() then
          notify_ready(context.win)
        end
      end,
    }
  else
    -- Pager: render in every mode, and never reveal the raw Markdown of the cursor line. M.pager() waits for
    -- the first on.render before the screen is drawn.
    config.render_modes = true
    config.anti_conceal = { enabled = false }
    config.on = {
      render = function()
        M.pager_rendered = true
      end,
    }
  end
  start = lap("setup: render-markdown options", start)
  if paths.icons then
    require("mini.icons").setup()
  end
  start = lap("setup: icons", start)
  require("render-markdown").setup(config)
  dofile(paths.render_markdown .. "/plugin/render-markdown.lua")
  start = lap("setup: render-markdown", start)
  M.tune_markdown_queries()
  lap("setup: query tuning", start)
end

-- Neovim's Tree-sitter highlighter does per-line work proportional to the number of injected trees, and
-- Markdown injects one markdown_inline tree per paragraph and per table cell. conceal_lines in the
-- highlights query enables a per-line hook that re-parses and walks every tree, so line-height queries cost
-- rows x trees: a 20-line viewport of a 600-row table never finished. render-markdown draws code fences
-- itself, so drop conceal_lines. (Combining the inline injections was tried and hangs on some documents.)
local function rewrite_query(lang, name, rewrite)
  local sources = {}
  for _, file in ipairs(vim.treesitter.query.get_files(lang, name)) do
    local handle = assert(io.open(file, "r"))
    table.insert(sources, rewrite(handle:read("*a")))
    handle:close()
  end
  if #sources > 0 then
    vim.treesitter.query.set(lang, name, table.concat(sources, "\n"))
  end
end

function M.tune_markdown_queries()
  rewrite_query("markdown", "highlights", function(text)
    return (text:gsub('%(#set! conceal_lines ""%)', ""))
  end)
end

local function has_highlights(lang)
  return parser_loads(lang) and #vim.treesitter.query.get_files(lang, "highlights") > 0
end

-- Highlight a non-Markdown buffer with Tree-sitter when the language has a highlights query,
-- otherwise with Neovim's regex syntax file for the filetype.
-- syntax: "auto" uses Tree-sitter when lang has a highlights query, "regex" always uses Vim's syntax files.
local function highlight(filetype, lang, syntax)
  local start = hrtime()
  vim.bo.filetype = filetype
  start = lap("open: filetype", start)
  local treesitter = syntax ~= "regex" and has_highlights(lang)
  start = lap("open: parser load", start)
  if treesitter then
    vim.treesitter.start(0, lang)
    start = lap("open: treesitter start", start)
    if vim.treesitter.query.get(lang, "highlights") == nil then -- Did not compile (warned); memoized otherwise.
      vim.treesitter.stop(0)
      treesitter = false
    end
  end
  if treesitter then
    -- Parse synchronously, injections included, so the captured screen is fully highlighted.
    vim.treesitter.get_parser(0, lang):parse(true)
    lap("open: parse", start)
    M.engine = "treesitter"
  else
    if vim.treesitter.highlighter.active[vim.api.nvim_get_current_buf()] then
      vim.treesitter.stop(0) -- Started by the filetype's ftplugin, e.g. Neovim's own for Lua.
    end
    vim.cmd("syntax enable")
    vim.bo.syntax = filetype
    lap("open: regex syntax", start)
    M.engine = "syntax"
  end
end

-- Edit path and highlight it. spec: {filetype, lang} from nvcat, or nil to use Neovim's detection with a
-- Markdown fallback, or {accept} (--filetype auto) to use Neovim's detection only for a filetype in accept.
-- syntax: "auto" (default) or "regex"; regex Markdown skips render-markdown.
-- Returns the detected filetype ("" for none) when accept rules it out, before any highlighting.
local function load(path, spec, syntax)
  M.syntax = syntax
  local start = hrtime()
  vim.api.nvim_cmd({ cmd = "edit", args = { path }, magic = { file = false, bar = false }, mods = { silent = true } }, {})
  start = lap("open: edit", start)
  if spec == vim.NIL then
    spec = nil
  end
  if spec == nil or spec.accept then
    local detected = vim.filetype.match({ buf = 0, filename = path })
    if spec and not vim.list_contains(spec.accept, detected) then
      lap("open: filetype detection", start)
      return detected or ""
    end
    spec = { filetype = detected or "markdown", lang = vim.treesitter.language.get_lang(detected or "markdown") }
    lap("open: filetype detection", start)
  end
  M.filetype = spec.filetype
  -- render-markdown needs the Markdown parser; without one that loads, show Vim's markdown syntax instead.
  M.rendered = M.filetype == "markdown" and syntax ~= "regex" and parser_loads("markdown")
  if M.filetype == "markdown" and not M.rendered and syntax ~= "regex" then
    syntax = "regex"
    M.syntax = "regex" -- Keeps render-markdown off this buffer (see config.ignore in M.setup).
  end
  if M.rendered then
    start = hrtime()
    vim.bo.filetype = "markdown"
    start = lap("open: filetype", start)
    vim.treesitter.start(0, "markdown")
    lap("open: treesitter start", start)
    M.engine = "render-markdown"
  else
    highlight(M.filetype, spec.lang or M.filetype, syntax)
  end
end

function M.open(path, line, token, spec, syntax)
  M.token = token
  vim.v.errmsg = ""
  local unsupported = load(path, spec, syntax)
  if unsupported then
    return { unsupported = unsupported }
  end
  local last = vim.api.nvim_buf_line_count(0)
  assert(line <= last, "Requested line exceeds document length (" .. last .. ")")
  vim.api.nvim_win_set_cursor(0, { line, 0 })
  vim.fn.winrestview({ topline = line, leftcol = 0, skipcol = 0 })
  M.update("Preview")
  return vim.api.nvim_get_current_buf()
end

function M.update(event)
  M.update_started = hrtime()
  if M.rendered then
    require("render-markdown.core.ui").update(
      vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win(), event, true
    )
  else
    notify_ready(vim.api.nvim_get_current_win())
  end
end

function M.resized(token)
  M.token = token
  vim.fn.winrestview({ topline = 1, leftcol = 0, skipcol = 0 })
  M.update("PreviewResize")
end

function M.info()
  local view = vim.fn.winsaveview()
  local namespace = vim.api.nvim_get_namespaces()["render-markdown.nvim"]
  return {
    total_height = vim.api.nvim_win_text_height(0, {}).all,
    remaining_height = vim.api.nvim_win_text_height(0, { start_row = view.topline - 1 }).all,
    bottom_line = vim.fn.line("w$"),
    buffer_lines = vim.api.nvim_buf_line_count(0),
    width = vim.api.nvim_win_get_width(0),
    height = vim.api.nvim_win_get_height(0),
    topline = view.topline,
    error = vim.v.errmsg,
    filetype = M.filetype,
    engine = M.engine,
    highlight_index = M.highlight_index,
    extmarks = #vim.api.nvim_buf_get_extmarks(0, namespace, 0, -1, {}),
    normal = vim.api.nvim_get_hl(0, { name = "Normal", link = false }),
    timings = M.timings,
    warnings = M.warnings,
    marks = M.marks,
    callbacks = M.callbacks,
  }
end

-- Built-in pager: the document in this Neovim, attached to the user's terminal. session: {paths, path,
-- filetype} from nvcat's page_nvim(). Keys follow less where Neovim's own would edit the buffer.
-- nvcat --check: compile the highlights and injections queries of each language, and write a JSON report
-- to stdout: languages whose queries compile, those without a parser or a highlights query (shown with regex
-- syntax), and the compile failures (M.warnings).
-- installed: also every parser on the runtimepath, since code fences can inject any of them (slow).
function M.check_queries(langs, installed)
  local report = { ok = {}, no_parser = {}, no_highlights = {} }
  local seen = {}
  for _, lang in ipairs(langs) do
    seen[lang] = true
  end
  for _, file in ipairs(installed and vim.api.nvim_get_runtime_file("parser/*.so", true) or {}) do
    local lang = vim.fn.fnamemodify(file, ":t:r")
    if not seen[lang] then
      seen[lang] = true
      table.insert(langs, lang)
    end
  end
  for _, lang in ipairs(langs) do
    if not pcall(vim.treesitter.language.add, lang) then
      table.insert(report.no_parser, lang)
    elseif #vim.treesitter.query.get_files(lang, "highlights") == 0 then
      table.insert(report.no_highlights, lang)
    else
      local before = #M.warnings
      vim.treesitter.query.get(lang, "highlights")
      vim.treesitter.query.get(lang, "injections")
      if #M.warnings == before then
        table.insert(report.ok, lang)
      end
    end
  end
  report.warnings = M.warnings
  io.stdout:write(vim.json.encode(report))
end

function M.pager(session)
  vim.o.shortmess = vim.o.shortmess .. "IF"
  M.setup(nil, session.paths)
  load(session.path, session.filetype, session.syntax)
  if M.rendered then
    -- render-markdown renders from a scheduled callback, which would run after Neovim has drawn the raw text
    -- once. Process events until its on.render fires, so the first screen is the rendered one; this runs from
    -- -c, before the first draw. After the timeout the raw text shows briefly and renders when it can.
    M.pager_rendered = false
    require("render-markdown.api").render({
      buf = vim.api.nvim_get_current_buf(), win = vim.api.nvim_get_current_win(), event = "Pager",
    })
    vim.wait(1000, function() return M.pager_rendered end, 5)
  end
  vim.bo.modifiable = false
  vim.bo.modified = false
  if #M.warnings > 0 then
    -- One line that fits the screen: a longer message would stop at "Press ENTER" before the document is seen.
    -- The full text is in nvcat --check.
    local failed = {}
    for _, warning in ipairs(M.warnings) do
      failed[#failed + 1] = warning:match("^(.- query) failed") or warning:match("^(%S+ parser) failed") or warning
    end
    local message = ("nvcat: %s failed (details: nvcat --check)"):format(table.concat(failed, ", "))
    -- Echoed during startup, before the first screen, even one line waits for a key; echo after VimEnter.
    vim.api.nvim_create_autocmd("VimEnter", { once = true, callback = vim.schedule_wrap(function()
      if vim.fn.strdisplaywidth(message) >= vim.o.columns then
        message = vim.fn.strcharpart(message, 0, vim.o.columns - 2) .. "…"
      end
      vim.api.nvim_echo({ { message, "WarningMsg" } }, true, {})
    end) })
  end
  local map = function(lhs, rhs)
    vim.keymap.set("n", lhs, rhs, { buffer = true, nowait = true, silent = true })
  end
  map("q", "<Cmd>qa!<CR>")
  map("<Space>", "<C-f>")
  map("f", "<C-f>")
  map("b", "<C-b>")
  map("d", "<C-d>")
  map("u", "<C-u>")
  if session.follow then
    M.follow(session.path)
    map("F", "G") -- less: follow again.
  end
end

-- Follow mode (--follow): reload the file when it changes, like less +F or tail -f. While the cursor is on the
-- last line the view stays at the end; moving up pauses that, and G or F resumes it. An inotify watch reacts
-- at once and a one-second poll covers filesystems without events and a file that was replaced or removed.
local function signature(path)
  local stat = vim.uv.fs_stat(path)
  return stat and table.concat({ stat.ino, stat.size, stat.mtime.sec, stat.mtime.nsec }, ":") or nil
end

function M.follow(path)
  local buf, win = vim.api.nvim_get_current_buf(), vim.api.nvim_get_current_win()
  local last = signature(path)
  local following = true
  vim.cmd("normal! G")
  vim.api.nvim_create_autocmd("CursorMoved", { buffer = buf, callback = function()
    following = vim.api.nvim_win_get_cursor(win)[1] == vim.api.nvim_buf_line_count(buf)
  end })

  local watcher
  local function reload()
    local current = signature(path)
    if current == nil or current == last then
      return -- Removed (wait for it to come back) or unchanged.
    end
    last = current
    local view = vim.fn.winsaveview()
    vim.bo[buf].modifiable = true
    vim.cmd("silent edit!")
    vim.bo[buf].modifiable = false
    vim.bo[buf].modified = false
    -- render-markdown re-renders after :edit! by itself (pager.bats checks the reloaded screen).
    if following then
      vim.cmd("normal! G")
    else
      vim.fn.winrestview(view)
    end
  end

  local function watch()
    if watcher then
      watcher:stop()
    end
    watcher = vim.uv.new_fs_event()
    -- A rename or replacement leaves the watch on the old file: watch the path again after each event.
    watcher:start(path, {}, vim.schedule_wrap(function()
      reload()
      watch()
    end))
  end
  watch()
  local timer = vim.uv.new_timer()
  timer:start(1000, 1000, vim.schedule_wrap(function()
    if signature(path) ~= last then
      reload()
      watch()
    end
  end))
end
