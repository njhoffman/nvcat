"""nvcat configuration: defaults, ~/.config/nvcat/config.toml, and NVCAT_* overrides.

Every key is optional. Defaults follow the XDG base directories and lazy.nvim's plugin layout, so a stock
Neovim with render-markdown.nvim installed through lazy.nvim works without a file. See config.example.toml.
"""

import glob
import os
from pathlib import Path
import shutil

# key: (kind, description). Kinds: path, paths (list), string.
KEYS = {
  "nvim": ("string", "Neovim executable"),
  "plugin_dirs": ("paths", "Directories searched for plugin checkouts (globs allowed)"),
  "render_markdown": ("path", "render-markdown.nvim checkout (required)"),
  "icons": ("path", "mini.icons checkout (optional)"),
  "parser_dir": ("path", "Directory with parser/ and queries/, prepended to 'runtimepath' (optional)"),
  "lua_path": ("path", "Directory added to Lua's package.path, for themes that require() modules (optional)"),
  "theme": ("path", "Lua file returning a table with apply() (optional; takes precedence over colorscheme)"),
  "colorscheme": ("string", "Colorscheme name on the runtimepath (optional; Neovim's default otherwise)"),
  "markdown_options": ("path", "Lua file that calls require('render-markdown').setup(opts) or returns opts "
                               "(optional; render-markdown defaults otherwise)"),
  "pager": ("string", "Pager for complete output: nvim (built in), less (less -R), or a command line"),
  "hyperlinks": ("string", "OSC 8 hyperlinks for Markdown links: auto, always or never"),
}
OPTIONAL = {"icons", "parser_dir", "lua_path", "theme", "colorscheme", "markdown_options"}


class ConfigError(Exception):
  pass


def xdg(name, fallback):
  return Path(os.environ.get(name) or Path.home() / fallback)


def config_file():
  return Path(os.environ.get("NVCAT_CONFIG") or xdg("XDG_CONFIG_HOME", ".config") / "nvcat/config.toml")


def expand(value):
  return Path(os.path.expandvars(os.path.expanduser(str(value))))


def find_plugin(dirs, name):
  for directory in dirs:
    candidate = directory / name
    if candidate.is_dir():
      return candidate
  return None


def defaults():
  data = xdg("XDG_DATA_HOME", ".local/share")
  return {
    "nvim": shutil.which("nvim"),
    "plugin_dirs": [data / "nvim/lazy", data / "nvim/site/pack/*/start", data / "nvim/site/pack/*/opt"],
    "parser_dir": data / "nvim/site",
    "pager": "nvim",
    "hyperlinks": "auto",
  }


def environment_overrides():
  values = {}
  for key, (kind, _) in KEYS.items():
    raw = os.environ.get("NVCAT_" + key.upper())
    if raw is not None:
      values[key] = raw.split(os.pathsep) if kind == "paths" else raw
  return values


def load(path=None):
  """Return (settings, sources): settings maps every key to a resolved value or None."""
  path = Path(path) if path else config_file()
  values, sources = defaults(), {key: "default" for key in KEYS}
  if path.is_file():
    import tomllib  # Only with a config file: about 4 ms of every start otherwise.
    try:
      parsed = tomllib.loads(path.read_text())
    except tomllib.TOMLDecodeError as error:
      raise ConfigError(f"{path}: {error}") from error
    unknown = sorted(set(parsed) - set(KEYS))
    if unknown:
      raise ConfigError(f"{path}: unknown keys: {', '.join(unknown)}")
    values.update(parsed)
    sources.update({key: str(path) for key in parsed})
  overrides = environment_overrides()
  values.update(overrides)
  sources.update({key: "NVCAT_" + key.upper() for key in overrides})

  settings = {}
  for key, (kind, _) in KEYS.items():
    value = values.get(key)
    if value in (None, ""):
      settings[key] = None
    elif kind == "paths":
      if isinstance(value, (str, Path)):
        value = [value]
      settings[key] = [Path(match) for item in value for match in sorted(glob.glob(str(expand(item))))]
    elif kind == "path":
      settings[key] = expand(value)
    else:
      settings[key] = str(value)
  if settings["render_markdown"] is None:
    settings["render_markdown"] = find_plugin(settings["plugin_dirs"], "render-markdown.nvim")
    sources["render_markdown"] = "plugin_dirs"
  if settings["icons"] is None and "icons" not in values:
    settings["icons"] = find_plugin(settings["plugin_dirs"], "mini.icons")
    sources["icons"] = "plugin_dirs"
  return settings, sources


def problems(settings):
  """Return (errors, warnings) for missing required and optional pieces."""
  errors, warnings = [], []
  if not settings["nvim"]:
    errors.append("Neovim not found (set nvim, or put nvim on PATH)")
  elif not shutil.which(settings["nvim"]):
    errors.append(f"Neovim executable not found or not executable: {settings['nvim']} (nvim setting or --nvim)")
  render_markdown = settings["render_markdown"]
  if not render_markdown or not (render_markdown / "lua/render-markdown").is_dir():
    errors.append("render-markdown.nvim not found (set render_markdown, or install it under plugin_dirs)")
  if settings["hyperlinks"] not in (None, "auto", "always", "never"):
    errors.append(f"hyperlinks: {settings['hyperlinks']!r} is not auto, always or never")
  for key in sorted(OPTIONAL):
    value = settings[key]
    if isinstance(value, Path) and not value.exists():
      warnings.append(f"{key}: {value} does not exist; skipped")
  if settings["icons"] is None:
    warnings.append("icons: mini.icons not found; rendering without an icon provider")
  return errors, warnings


def runtime_paths(settings):
  """Settings for profile.lua, with missing optional paths dropped."""
  def existing(key):
    value = settings[key]
    return str(value) if isinstance(value, Path) and value.exists() else None
  paths = {
    "render_markdown": str(settings["render_markdown"]),
    "icons": existing("icons"),
    "parser_dir": existing("parser_dir"),
    "lua_path": existing("lua_path"),
    "theme": existing("theme"),
    "colorscheme": settings["colorscheme"],
    "markdown_options": existing("markdown_options"),
  }
  # Unset keys are dropped: msgpack nil arrives in Lua as vim.NIL, which is truthy.
  return {key: value for key, value in paths.items() if value is not None}
