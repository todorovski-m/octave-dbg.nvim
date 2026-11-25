# octave-dbg.nvim

An IDE-like GNU Octave workflow for Neovim: a REPL, and a debugger with
breakpoints, stepping, a current-line marker, a variables panel and value
popups. There is no DAP adapter for Octave, so the plugin drives Octave's own
command-line debugger (`dbstop`, `dbstep`, `dbcont`, `dbquit`) through one
terminal job.

- Send the current line, a selection or a `%%` cell to the REPL; run a file.
- Toggle breakpoints with signs that follow your edits and always show where
  Octave really has them.
- Step, step in, step out, continue, quit, run to cursor, interrupt.
- See where the debugger stopped: the line is marked, and the file opens in
  a source window.
- Watch the variables of the stopped frame in a panel that refreshes itself.
- Hover a variable or struct field to see its value; press F1 for Octave's
  help on the name under the cursor.
- Optional MATLAB-style keys: F5 run or continue, F10 step, F11 step in,
  F12 breakpoint, and more.

Pure Lua, no dependencies. Nothing is echoed in the REPL for the panel, the
hover or the help popup, apart from one command that starts a small Octave
helper.

## Requirements

- Neovim 0.10 or newer
- GNU Octave on `$PATH` (tested with Octave 11.1 on macOS)

## Installation

With [lazy.nvim](https://github.com/folke/lazy.nvim):

```lua
{
  "todorovski-m/octave-dbg.nvim",
  ft = { "octave", "matlab" },
  cmd = "OctaveDbg",
  opts = {
    setup_keymap = true, -- keymaps under <leader>o
    matlab_keys = true,  -- F5, F9, F10, F11, F12 and more
  },
}
```

Neovim often detects `.m` files as `matlab`; both filetypes are handled.
With other plugin managers, add the plugin to `'runtimepath'` and call
`require("octave_dbg").setup({ ... })`. The command works without `setup()`.

Run `:checkhealth octave_dbg` to check Neovim, Octave and the REPL job. With
a lazy-loaded spec like the one above, open a `.m` file first; before the
plugin has loaded, the health check is not found.

## Quick start

1. Open a script, for example `test/demo_script.m` from this repository.
2. `:OctaveDbg repl` (or `<leader>oo`) opens Octave in a split.
3. `:OctaveDbg break` (or `F12`) on a line sets a breakpoint.
4. `:OctaveDbg run` (or `F5`) runs the file; Octave stops at the
   breakpoint, and the line is marked.
5. Step with `F10`, step in with `F11`, continue with `F5`, quit with
   `Shift+F5`. `<leader>ov` opens the variables panel, and `<leader>oh`
   shows the value under the cursor.

The full reference is in `:help octave-dbg`.

## Commands

`:OctaveDbg {subcommand}`, with completion. Without a subcommand, it shows
the status.

| Subcommand | Action |
|------------|--------|
| `repl` | Open or show the REPL (also resets the restart counter) |
| `send` | Send the cursor line, or a range: `:'<,'>OctaveDbg send` |
| `cell` | Send the `%%` cell under the cursor |
| `run` | Save and `run('<absolute path>')` |
| `runto` | Run, or continue, to the cursor line |
| `interrupt` | Send Ctrl+C to Octave (stops a running command) |
| `break [N]` | Toggle a breakpoint on the cursor line (or line N) |
| `step` / `in` / `out` | `dbstep` / `dbstep in` / `dbstep out` |
| `continue` / `quit` | `dbcont` / `dbquit` |
| `clear` | Remove all breakpoints (`dbclear all`) |
| `whos` / `clc` / `close` | `whos` / `clc` / `close all` |
| `panel` | Toggle the variables panel |
| `hover` | Show the variable or struct field under the cursor in a popup |
| `help [name]` | Octave `help` for a name (default: under the cursor) in a popup |
| `status` | REPL state, stop location, panel and breakpoints |
| `debug` | Scratch buffer with the exact commands sent and recent output |

## Keymaps

There are no keymaps by default. Both sets below are buffer-local and are
created only in Octave buffers.

### Leader keys (`setup_keymap = true`)

Under `keymap_prefix` (default `<leader>o`). With which-key (for example in
LazyVim), the prefix shows as the group "Octave".

| Key | Action | Key | Action |
|-----|--------|-----|--------|
| `o` | open REPL | `b` | toggle breakpoint |
| `l` | send line | `B` | clear all breakpoints |
| `s` | send selection (visual) | `n` | step |
| `c` | send cell | `i` | step in |
| `f` | run file | `O` | step out |
| `w` | whos | `r` | continue |
| `v` | variables panel | `t` | run to cursor |
| `h` | hover | `k` | interrupt (Ctrl+C) |
| `d` | help for name under cursor | `q` | quit debugging |
| `C` | clc | `x` | close all figures |

### MATLAB keys (`matlab_keys = true`)

| Key | Action | Modes |
|-----|--------|-------|
| `F5` | run file; **continue** when the debugger is stopped | normal, insert |
| `Shift+F5` | quit debugging | normal, insert |
| `F9` | send line (normal) or selection (visual) | normal, visual |
| `F10` | step | normal, insert |
| `F11` | step in | normal, insert |
| `Shift+F11` | step out | normal, insert |
| `F12` | toggle breakpoint | normal, insert |
| `Ctrl+F10` | run to cursor | normal, insert |
| `Ctrl+Enter` | run section (`%%` cell) | normal, insert |
| `Ctrl+C` | interrupt Octave | normal |
| `F1` | help for the name under the cursor | normal, insert |

A table changes single keys, and `false` removes one:
`matlab_keys = { step = "<F8>", interrupt = false }`. The names are `run`,
`quit`, `send`, `step`, `step_in`, `step_out`, `breakpoint`,
`run_to_cursor`, `cell`, `interrupt` and `help`.

Some keys depend on the terminal and the system:

- **Ctrl+Enter** reaches Neovim only when the terminal sends it as a
  separate key. Inside tmux, this needs `set -g extended-keys on`;
  otherwise it arrives as a plain Enter. `<leader>oc` always works.
- **Shift+F5 / Shift+F11** arrive as `<S-F5>` / `<S-F11>` in most terminals
  (tmux needs `xterm-keys on`, the default). Some terminals send `<F17>` /
  `<F23>` instead; map those with the Lua API if needed.
- **macOS** sends F-keys only with `Fn` unless *System Settings → Keyboard
  → "Use F1, F2, etc. keys as standard function keys"* is on, and uses F11
  for "Show Desktop" by default.

## Debugging view

**Current-line marker.** When Octave stops, the stop line gets a `▶` sign
and a line highlight (`OctaveDbgCurrentLine`, linked to `Visual`). With
`follow = true`, a source window shows the file and its cursor moves to the
line; a file that is not open yet is opened. Focus does not move. The marker
goes away when Octave is back at its normal prompt.

**Variables panel.** `:OctaveDbg panel` opens a split with the name, size,
class, bytes and a short value of each variable. While the debugger is
stopped, it shows the variables of the stopped frame; otherwise those of
the base workspace. It refreshes by itself at every prompt.

**Hover.** `:OctaveDbg hover` shows the variable or struct field under the
cursor in a floating window: name, size, class, scope and Octave's own
`disp` output in the current `format`. With the cursor on `b` in `s.a.b`,
it shows `s.a.b`; on `a`, it shows `s.a`. Large values get a summary (min,
max, mean and the top-left 5x5). Only names are looked up: if the name is
not a variable, the popup says so, and nothing is run. Press the key again
to enter the popup.

**Help.** `:OctaveDbg help` shows `help NAME` for the name under the cursor
in a popup that can be scrolled.

## Options

Defaults:

```lua
require("octave_dbg").setup({
  cmd = { "octave", "--no-gui", "--quiet" }, -- string or list
  split = "vsplit",          -- Ex command that opens the REPL window
  cell_delimiter = "^%%",    -- Vim regex
  bracketed_paste = true,    -- wrap multi-line sends
  max_restarts = 3,          -- automatic restarts after the job dies
  setup_keymap = false,      -- leader keys, see Keymaps
  keymap_prefix = "<leader>o",
  matlab_keys = false,       -- MATLAB-style keys, see Keymaps
  filetypes = { "octave", "matlab" },
  sign_text = "●",
  sign_hl = "DiagnosticError",
  log_size = 200,            -- entries kept for :OctaveDbg debug
  marker = true,             -- show the current-line marker
  follow = true,             -- show the stop location in a source window
  marker_debounce = 80,      -- ms of quiet output before the marker moves
  marker_sign_text = "▶",
  marker_sign_hl = "DiagnosticWarn",
  marker_line_hl = "OctaveDbgCurrentLine",
  prompt_patterns = { "^octave:%d+>%s*$", "^>>%s*$" }, -- Lua patterns
  debug_prompt_pattern = "^debug>%s*$",
  panel_split = "botright 10split",
  hover_max_lines = 20,      -- most lines of disp output in the popup
  hover_timeout = 1000,      -- ms before "Octave is busy"
  hover_max_elements = 1000, -- larger values get a summary
  hover_border = "rounded",
  help_max_height = 20,      -- help popup height (it can be scrolled)
})
```

Any option may be a function `function(bufnr) return value end`. A buffer
variable `vim.b.octave_dbg_<option>` overrides it for one buffer, for
example `vim.b.octave_dbg_cmd = { "octave-cli" }`.

If you change Octave's `PS1`, set `prompt_patterns` to match it: the marker
uses the normal prompt to see that a debug session is over.

## Lua API

```lua
local od = require("octave_dbg")
od.repl() od.send(text) od.send_line() od.send_selection() od.send_cell()
od.run() od.run_or_continue() od.run_to_cursor() od.interrupt()
od.toggle_breakpoint(line?) od.clear_breakpoints()
od.step() od.step_in() od.step_out() od.continue() od.quit()
od.whos() od.clc() od.close_figures() od.status() od.debug()
od.panel() od.open_panel() od.close_panel()
od.hover() od.help(name?)
od.location() -- { name, line, path } where the debugger stopped, or nil
```

`User` autocommand events: `OctaveDbgReplStarted`, `OctaveDbgReplExited`,
`OctaveDbgStopped` (with `data = { name, line, path }`) and
`OctaveDbgEnded`.

## How it works

Notes on Octave's debugger that shape the plugin (Octave 11.1):

- **`dbstop` takes a name, not a path.** `dbstop('/abs/path/f.m', 3)` fails
  with "unable to find function"; `dbstop('f', '3')` works when the folder
  of `f.m` is on the load path. The plugin sends
  `addpath('<absolute folder>'); [~] = dbstop('<name>', '<line>');`, so file
  names must be valid Octave identifiers (no `-`, no leading digit). The
  `[~] =` keeps `dbstop` from overwriting `ans` with the line number.
- **Scripts.** A breakpoint in a plain script fires when the script is
  started with `run('/abs/path/script.m')`, which is what `:OctaveDbg run`
  sends.
- **The stop location** is printed as
  `stopped in <name> at line <n> [<absolute path>]`, followed by the
  `debug>` prompt. The marker parses this line.
- **Saving a file clears its breakpoints** in Octave. After a save, the
  plugin sends them again about a second later, with the lines taken from
  the signs (which follow your edits). A `dbstop` within the same second as
  the write would be lost. For the same reason, `run` and "run to cursor"
  wait for that re-send when the file was just saved.
- **Octave moves or ignores some breakpoints.** On a comment or empty line,
  the breakpoint goes to the next line that runs code; after the end of the
  file, `dbstop` does nothing and reports no error. So each `dbstop` and
  `dbclear` also asks Octave for `dbstatus`, and the signs show what Octave
  reports. A breakpoint that Octave places after the end of the file is
  cleared again and reported as not accepted.
- **REPL restarts.** The plugin keeps the breakpoint list and sends it again
  when the REPL starts or restarts. When Neovim quits, Octave is stopped and
  given up to 3 seconds to exit, so that no orphaned Octave process is left.
- **Reading the workspace without echo.** `octave/octave_dbg_hook.m`
  registers an `add_input_event_hook`, which Octave calls while it waits for
  input. Inside it, `evalin('caller', ...)` sees the workspace of the
  prompt: the stopped frame in debug mode, the base workspace otherwise.
  Neovim talks to the hook through small files in a temp folder (a flag for
  the panel, request and answer files for the hover and the help popup),
  each ending with `#end`, and checks them with a timer.
- **Run to cursor.** Octave has no such command. The plugin sends one line
  with a temporary `dbstop` at the cursor, a `dbstatus` request, and
  `run(...)` or `dbcont`. When Octave stops, or the run ends, the temporary
  breakpoint is removed again. It is never shown or stored.
- **Large values.** `disp` of a 1000x1000 matrix takes about 0.4 s and
  produces 13 MB of text, so the hover shows a summary for large values.
  It also turns `split_long_rows` off while it runs `disp`, so that wide
  rows are not split into "Columns 1 through 3" blocks, and restores the
  setting after.

## Limitations

- Breakpoints typed by hand in the REPL (`dbstop ...`) are not shown as
  signs.
- Between an edit and the next save, the signs move but Octave's
  breakpoints stay on the old lines.
- The panel, the hover and the help popup only update while Octave waits at
  a prompt; while a command runs, the popup says that Octave is busy.
- When Octave is killed, it may write an `octave-workspace` file in its
  working folder.

## Development

To work on the plugin, load a local clone with lazy.nvim:

```lua
{ dir = "/path/to/octave-dbg.nvim", ft = { "octave", "matlab" }, cmd = "OctaveDbg", opts = {} }
```

lazy.nvim does not generate help tags for a local `dir` plugin, so run
`:helptags /path/to/octave-dbg.nvim/doc` once, and again after the help file
changes.

Unit tests use [plenary.nvim](https://github.com/nvim-lua/plenary.nvim)
(found in lazy.nvim's data folder, or set `PLENARY_DIR`):

```sh
nvim --headless --noplugin -u test/minimal_init.lua \
  -c "PlenaryBustedDirectory test { minimal_init = 'test/minimal_init.lua' }"
```

`test/demo_script.m` (a script with two cells) and `test/demo_add.m` (a
function it calls) are small files for manual tests.

In the Octave helpers, write `min(5, n)` and not `min (5, n)` inside
`[...]` or `{...}`: there, Octave reads a space as an element separator.

## License

MIT, see [LICENSE](LICENSE).
