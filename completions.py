"""Shell completion scripts for `nvcat completions SHELL`, generated from nvcat's argument parser so that they list
the options it has. Imported only for that command, which keeps it out of every other start."""

import shlex

SHELLS = ["bash", "zsh", "fish"]
FILETYPES = "nvcat --filetypes 2>/dev/null | cut -f1"  # Asked for when completing: the tables are per machine.
PAGERS = ["nvim", "less"]


class Option:
  def __init__(self, action):
    self.flags = action.option_strings
    self.shorts = [flag[1:] for flag in self.flags if not flag.startswith("--")]
    self.longs = [flag[2:] for flag in self.flags if flag.startswith("--")]
    self.dest = action.dest
    self.takes_value = action.nargs != 0
    self.choices = list(action.choices) if action.choices else None
    self.help = (action.help or "").split(". ")[0].split(";")[0].strip().rstrip(".")


def options(parser):
  return [Option(action) for action in parser._actions if action.option_strings]


def script(shell, parser):
  return {"bash": bash, "zsh": zsh, "fish": fish}[shell](parser)


def bash(parser):
  found = options(parser)
  words = " ".join(flag for option in found for flag in option.flags)
  cases = []
  for option in found:
    if not option.takes_value:
      continue
    pattern = "|".join(option.flags)
    if option.dest == "filetype":
      body = f'mapfile -t COMPREPLY < <(compgen -W "auto $({FILETYPES})" -- "$cur")'
    elif option.dest == "nvim":
      body = 'mapfile -t COMPREPLY < <(compgen -c -- "$cur")'
    elif option.choices or option.dest == "pager":
      values = " ".join(option.choices or PAGERS)
      body = f"mapfile -t COMPREPLY < <(compgen -W '{values}' -- \"$cur\")"
    else:
      body = ":"  # A number: nothing to offer, and not a file either.
    cases.append(f"    {pattern})\n      {body}\n      return\n      ;;")
  newline = "\n"
  return f'''# bash completion for nvcat. Load with: source <(nvcat completions bash)
_nvcat() {{
  local cur=${{COMP_WORDS[COMP_CWORD]}} prev=${{COMP_WORDS[COMP_CWORD-1]}}
  # --option=value: bash splits the word at the =.
  if [[ $cur == = ]]; then
    cur=
  elif [[ $prev == = ]]; then
    prev=${{COMP_WORDS[COMP_CWORD-2]}}
  fi
  COMPREPLY=()
  if ((COMP_CWORD == 2)) && [[ ${{COMP_WORDS[1]}} == completions ]]; then
    mapfile -t COMPREPLY < <(compgen -W '{" ".join(SHELLS)}' -- "$cur")
    return
  fi
  case $prev in
{newline.join(cases)}
  esac
  if [[ $cur == -* ]]; then
    mapfile -t COMPREPLY < <(compgen -W '{words}' -- "$cur")
    return
  fi
  compopt -o filenames 2>/dev/null
  mapfile -t COMPREPLY < <(compgen -f -- "$cur")
  if ((COMP_CWORD == 1)) && [[ completions == "$cur"* ]]; then
    COMPREPLY+=(completions)
  fi
}}
complete -F _nvcat nvcat
'''


def _zsh_text(text):
  """Text for inside a single-quoted _arguments spec's [description]."""
  return text.replace("\\", "\\\\").replace("'", "'\\''").replace("[", "\\[").replace("]", "\\]").replace(":", "\\:")


def zsh(parser):
  groups = {}
  for group in parser._mutually_exclusive_groups:
    flags = [flag for action in group._group_actions for flag in action.option_strings]
    for action in group._group_actions:
      groups[action.dest + str(action.option_strings)] = flags
  specs = []
  for action in parser._actions:
    if not action.option_strings:
      continue
    option = Option(action)
    excluded = list(dict.fromkeys(groups.get(action.dest + str(action.option_strings), []) + option.flags))
    exclusion = f"({' '.join(excluded)})" if len(excluded) > 1 else ""
    description = _zsh_text(option.help)
    if option.dest == "filetype":
      value = ":filetype:_nvcat_filetypes"
    elif option.dest == "nvim":
      value = ":command:_command_names -e"
    elif option.choices or option.dest == "pager":
      value = f":value:({' '.join(option.choices or PAGERS)})"
    elif option.takes_value:
      value = ":number: "
    else:
      value = ""
    for flag in option.flags:
      form = f"{flag}=" if option.takes_value and flag.startswith("--") else flag
      specs.append(f"    '{exclusion}{form}[{description}]{value}' \\")
  newline = "\n"
  return f'''#compdef nvcat
# zsh completion for nvcat. Load with: source <(nvcat completions zsh), or save as _nvcat in a directory on $fpath.
_nvcat_filetypes() {{
  local -a names
  names=(auto ${{(f)"$({FILETYPES})"}})
  compadd -a names
}}

_nvcat_first() {{
  compadd completions
  _files
}}

_nvcat_second() {{
  [[ ${{words[2]}} == completions ]] && compadd {" ".join(SHELLS)}
}}

_nvcat() {{
  _arguments -s -S \\
{newline.join(specs)}
    '1:file:_nvcat_first' \\
    '2:shell:_nvcat_second'
}}

if [[ ${{funcstack[1]}} == _nvcat ]]; then
  _nvcat "$@"
else
  compdef _nvcat nvcat
fi
'''


def fish(parser):
  lines = ["# fish completion for nvcat. Load with: nvcat completions fish | source, or save as",
           "# ~/.config/fish/completions/nvcat.fish",
           "complete -c nvcat -n 'test (count (commandline -opc)) -eq 1' -a completions "
           "-d 'Print a shell completion script'",
           "complete -c nvcat -n 'test (count (commandline -opc)) -eq 2; and test (commandline -opc)[2] = completions' "
           f"-f -a '{' '.join(SHELLS)}'"]
  for option in options(parser):
    parts = ["complete -c nvcat"]
    parts += [f"-s {short}" for short in option.shorts]
    parts += [f"-l {long}" for long in option.longs]
    if option.dest == "filetype":
      parts += ["-x", "-a", shlex.quote(f"auto ({FILETYPES})")]
    elif option.dest == "nvim":
      parts += ["-x", "-a", shlex.quote("(__fish_complete_command)")]
    elif option.choices or option.dest == "pager":
      parts += ["-x", "-a", shlex.quote(" ".join(option.choices or PAGERS))]
    elif option.takes_value:
      parts.append("-x")
    if option.help:
      parts += ["-d", shlex.quote(option.help)]
    lines.append(" ".join(parts))
  return "\n".join(lines) + "\n"
