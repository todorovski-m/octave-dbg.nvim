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
- Browse large matrices, including sparse and complex ones, in a viewer
  that only ever asks Octave for the part on screen.
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
| `run` | Save the changed Octave buffers and run the main script, or the current file |
| `runfile` | Run the current file, even when a main script is set |
| `main [path\|clear]` | Set the main script (default: the current file), or forget it |
| `runto` | Run, or continue, to the cursor line |
| `interrupt` | Send Ctrl+C to Octave (stops a running command) |
| `break [N]` | Toggle a breakpoint on the cursor line (or line N) |
| `step` / `in` / `out` | `dbstep` / `dbstep in` / `dbstep out` |
| `continue` / `quit` | `dbcont` / `dbquit` |
| `clear` | Remove all breakpoints (`dbclear all`) |
| `whos` / `clc` / `close` | `whos` / `clc` / `close all` |
| `panel` | Toggle the variables panel |
| `hover` | Show the variable or struct field under the cursor in a popup |
| `view [name]` | Open the value viewer for a name or path such as `mpc.bus` or `c{2,3}` (default: the name under the cursor) |
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
| `f` | run main script (or this file) | `O` | step out |
| `w` | whos | `r` | continue |
| `v` | variables panel | `t` | run to cursor |
| `h` | hover | `k` | interrupt (Ctrl+C) |
| `d` | help for name under cursor | `q` | quit debugging |
| `V` | value viewer | `F` | run this file |
| `C` | clc | `x` | close all figures |

`K` (option `help_key`) also shows Octave's help for the name under the
cursor, like `<leader>od`. In Octave buffers it replaces LSP hover, which
LazyVim maps to `K` when a language server (such as Copilot) attaches; the
plugin sets it again shortly after an attach and when an Octave buffer is
entered. Set `help_key = false` to keep the LSP's `K`.

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

## Main script

When you work on a function that a script calls, set the script as the
main script once: open `main.m` and run `:OctaveDbg main` (or
`:OctaveDbg main path/to/main.m` from anywhere). From then on, F5,
`<leader>of` and `:OctaveDbg run` run `main.m` from whichever Octave file
you are in, and breakpoints in the function stop there. Run to cursor
(`Ctrl+F10`) in the function sets its temporary breakpoint there and runs
`main.m`. `<leader>oF` (`:OctaveDbg runfile`) runs the current file instead.

- **Remembered per folder.** The main script is stored for its own folder
  and the folder it was set from, in Neovim's data folder
  (`stdpath("data")/octave-dbg/main.json`), so no project file changes. From
  the current file, the folders are searched upwards, so a function in
  `lib/` finds the main script of the project. `:OctaveDbg status` shows it;
  `:OctaveDbg main clear` forgets it.
- **Only changed files are saved.** Before a run, every Octave buffer with
  unsaved changes is written; files without changes keep their
  modification time, so synced folders see no needless changes.
- **A function can be the main program.** Without a main script, a function
  file runs too: it is called by name without arguments (so defaults for
  `nargin == 0` take effect), and `ans` is shown, as with F5 in MATLAB. A
  script runs with `run('<absolute path>')`. A file counts as a function file
  when its first line of code starts with `function`.
- The option `main` gives a main script where none was set: a path, a
  `function(bufnr)`, or `vim.b.octave_dbg_main`.

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
max, mean and the top-left 5x5; for a sparse value, Octave's header and the
first nonzero entries). Only names are looked up: if the name is not a
variable, the popup says so, and nothing is run. A struct with a large
field shows the list of its fields instead of every value. Press the key
again to enter the popup. For a large value or a struct, `<CR>` in the
popup opens the value viewer.

**Value viewer.** `:OctaveDbg view [name]` (or `<leader>oV`) opens a
read-only buffer, by default in a float, that shows one window of a value:
as many rows and columns as fit in the float, at most `viewer_rows` x
`viewer_cols` (50 x 15), with row and column indices. The keys move a
cursor over the cells, as in a spreadsheet; at an edge, the viewer asks
Octave for the next window, so the whole value is never formatted. The
header shows the name, size, class, scope, statistics, the shown range and
the cell under the cursor, and for sparse values Octave's own line
`Compressed Column Sparse (rows = R, cols = C, nnz = N [P%])`.

| Key | Action |
|-----|--------|
| `j` / `k` / `h` / `l`, arrows | the cursor one row down or up, one column right or left; at an edge, the window moves |
| `<C-d>` / `<C-u>`, `<PageDown>` / `<PageUp>` | one page down or up |
| `gg` / `G` | first or last row |
| `0` / `$`, `<Home>` / `<End>` | first or last column |
| `g` | go to a row and column (`120 5`, `120`, or `,5`), with the cursor on that cell |
| `m` | sparse: switch between the nonzero list and the grid |
| `a` | complex: switch between real and imaginary parts and magnitude and angle |
| `<CR>` | open the struct field or cell element under the cursor |
| `<BS>` or `-` | back to the parent struct |
| `r` | refresh |
| `q` | close |

- **Other motions** (a mouse click, `w`, a search) also move the cursor
  to a cell: the cell line and `<CR>` always follow the cursor on screen.
- **Sparse values** open in the nonzero list: `(i, j) -> value` in
  column-major order, a page of `viewer_rows` entries at a time. The grid
  shows a window of the matrix with zeros as dots. `g` moves the grid to a
  row and column, and in the list it goes to the first nonzero at or after
  them.
- **Complex values** show real and imaginary parts, or magnitude and angle
  in degrees after `a`.
- **Structs** show their fields with size, class and a short value. `<CR>`
  opens the field under the cursor in the same window (`mpc` -> `mpc.bus`),
  as deep as the fields go; `<BS>` goes back, with the cursor on the field
  you came from. The float title shows the path.
- **Cells** show a window of one-line summaries. `<CR>` opens the element
  under the cursor (`c` -> `c{2,3}`), and from there fields and elements go
  on (`c{2,1}{1,2}.x`). Paths accept only plain positive integers as
  indices (no `end`, no variables, no expressions); both Neovim and Octave
  check them, and Octave walks them without evaluating anything.
- **char** arrays show a window of lines. N-D arrays show their first page.
  Other classes get a message.
- The viewer is **not refreshed** when the debugger stops again; it is
  marked, and `r` refreshes it.

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
  help_key = "K",            -- help for the name under the cursor; false: none
  main = false,              -- main script when :OctaveDbg main set none: path or function(bufnr)
  viewer_rows = 50,          -- most rows (or sparse list entries) per window
  viewer_cols = 15,          -- most columns per window
  viewer_timeout = 2000,     -- ms before the viewer says "Octave is busy"
  viewer_border = "rounded",
  viewer_split = "float",    -- or an Ex command, such as "botright 20split"
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
od.run() od.run_file() od.run_or_continue() od.run_to_cursor() od.interrupt()
od.set_main(path?) od.clear_main() od.get_main()
od.toggle_breakpoint(line?) od.clear_breakpoints()
od.step() od.step_in() od.step_out() od.continue() od.quit()
od.whos() od.clc() od.close_figures() od.status() od.debug()
od.panel() od.open_panel() od.close_panel()
od.hover() od.help(name?) od.view(name?)
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
- **Scripts and functions.** A breakpoint in a plain script fires when the
  script is started with `run('/abs/path/script.m')`, which is what
  `:OctaveDbg run` sends for a script. Breakpoints in a function fire
  whichever script calls it, because `dbstop` adds the function's folder to
  the load path. A function file is run by calling it by name.
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
  when the REPL starts or restarts. When Neovim quits, the plugin asks
  Octave to exit (Ctrl+U and `exit`; if Octave is busy, Ctrl+C and `exit`
  again) and waits for it, so that no orphaned Octave process is left.
  Stopped by a signal instead, Octave writes its variables to an
  `octave-workspace` crash dump in its working folder; a signal is used only
  when Octave does not exit within about 2.5 seconds.
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
- **Sparse values** are judged by their number of nonzeros, not by rows
  times columns, so a 10000x10000 sparse matrix with a few thousand
  nonzeros is shown with its header and entries. Their statistics come from
  the nonzeros only: `mean` over all elements of such a matrix takes
  minutes, and the hook runs in Octave's main thread. For complex values,
  the statistics use `abs`.
- **The viewer** sends a request with the name, the mode, the window
  position and size, and real/imaginary or magnitude/angle. Octave answers
  with that window only (`octave/octave_dbg_view.m`): a slice of a dense
  matrix, `full()` of a slice of a sparse one, or a page of `find()` for the
  nonzero list.

## Limitations

- Breakpoints typed by hand in the REPL (`dbstop ...`) are not shown as
  signs.
- Between an edit and the next save, the signs move but Octave's
  breakpoints stay on the old lines.
- The panel, the hover and the help popup only update while Octave waits at
  a prompt; while a command runs, the popup says that Octave is busy.
- If Octave is killed by a signal, for example when Neovim itself crashes or
  Octave does not answer `exit`, Octave writes an `octave-workspace` crash
  dump into its working folder.
- The viewer shows values but cannot edit them. It shows one struct, not
  struct arrays, and the first page of N-D arrays. Indices in a path are
  plain integers only, so `c{end}` or `s(2).x` cannot be opened. Numbers
  are shown with 5 significant digits (integers exactly), not in Octave's
  current `format`.

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

End-to-end tests drive Neovim and a real Octave (`octave` on `PATH`; no
plenary needed). They run in a temporary folder with their own
`XDG_DATA_HOME`, so the repository and your Neovim data stay untouched, and
the exit code is 0 only when every check passed:

```sh
test/e2e/run.sh              # all suites, a few minutes
test/e2e/run.sh hover keys   # some suites
```

The suites are `stage1` (REPL, run, breakpoints, restart, health), `stage2`
(marker, panel), `bpsync` (breakpoints kept in sync with `dbstatus`),
`hover`, `keys` (MATLAB keys, run to cursor, interrupt, help), `viewer`,
`viewer_wiring`, `main` and `main_restart` (the main script).

For manual tests, `test/demo_script.m` (a script with two cells) and
`test/demo_add.m` (a function it calls) are small files; `test/main_demo/`
is a small project with a main script, a function with defaults and a
function in `lib/`, with the steps in `main.m`; `test/view_dense.m`,
`test/view_sparse.m`, `test/view_complex.m` and `test/view_struct.m` set up
values for the viewer and say what to try.

In the Octave helpers, write `min(5, n)` and not `min (5, n)` inside
`[...]` or `{...}`: there, Octave reads a space as an element separator.

## License

MIT, see [LICENSE](LICENSE).
