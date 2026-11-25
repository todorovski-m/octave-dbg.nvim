-- octave-dbg.nvim: Octave REPL and debugger driven from Neovim.

local config = require("octave_dbg.config")
local repl = require("octave_dbg.repl")
local dbg = require("octave_dbg.debug")
local marker = require("octave_dbg.marker")
local panel = require("octave_dbg.panel")
local hover = require("octave_dbg.hover")

local M = {}

-- Public API ---------------------------------------------------------------

M.repl = function()
  repl.start({ manual = true })
end
M.send = repl.send
M.send_line = function()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  repl.send_lines(0, row, row)
end
M.send_selection = repl.send_selection
M.send_cell = function()
  repl.send_cell(0)
end
M.run = function()
  dbg.run(0)
end
M.toggle_breakpoint = function(line)
  dbg.toggle(vim.api.nvim_get_current_buf(), line)
end
M.clear_breakpoints = dbg.clear_all
M.step = dbg.step
M.step_in = dbg.step_in
M.step_out = dbg.step_out
M.continue = dbg.continue
M.quit = dbg.quit
--- F5 in MATLAB: continue when stopped, else save and run the file.
M.run_or_continue = function()
  dbg.run_or_continue(0)
end
--- Run or continue to the cursor line (temporary breakpoint).
M.run_to_cursor = function()
  dbg.run_to_cursor(vim.api.nvim_get_current_buf())
end
--- Send Ctrl+C to Octave to stop a running command.
M.interrupt = repl.interrupt
M.whos = function()
  repl.send("whos")
end
M.clc = function()
  repl.send("clc")
end
M.close_figures = function()
  repl.send("close all")
end
M.panel = panel.toggle
M.open_panel = panel.open
M.close_panel = panel.close
--- Show the variable or struct field under the cursor in a floating window.
M.hover = hover.hover
--- Show `help NAME` in a popup, for `name` or the name under the cursor.
M.help = hover.help
--- Where the debugger stopped: { name, line, path } or nil.
M.location = marker.current

--- Set up the autocommands of all modules. Safe to call more than once.
function M._setup_modules()
  dbg.setup()
  marker.setup()
  panel.setup()
end

--- Lines shown by :OctaveDbg status.
function M.status_lines()
  local info = repl.info()
  local state = info.alive and ("running (job " .. info.chan .. ")")
    or (info.died and "dead") or (info.started and "stopped") or "not started"
  local lines = {
    "REPL: " .. state,
    "Command: " .. vim.inspect(info.cmd or config.get("cmd")),
    ("Automatic restarts: %d/%d"):format(info.restarts, info.max_restarts),
    "Commands sent: " .. #info.sent,
  }
  local stop = marker.current()
  table.insert(
    lines,
    stop and ("Stopped in: %s, line %d (%s)"):format(stop.name, stop.line, vim.fn.fnamemodify(stop.path, ":~"))
      or "Stopped in: not debugging"
  )
  table.insert(lines, "Variables panel: " .. (panel.is_open() and "open" or "closed"))
  local bps = dbg.list()
  if #bps == 0 then
    table.insert(lines, "Breakpoints: none")
  else
    table.insert(lines, "Breakpoints:")
    for _, bp in ipairs(bps) do
      table.insert(lines, ("  %s: %s"):format(vim.fn.fnamemodify(bp.path, ":~"), table.concat(bp.lines, ", ")))
    end
  end
  return lines
end

function M.status()
  vim.notify(table.concat(M.status_lines(), "\n"), vim.log.levels.INFO, { title = "octave-dbg" })
end

--- Scratch buffer with the exact commands sent and the recent REPL output.
function M.debug()
  local info = repl.info()
  local lines = { "# Commands sent to Octave (oldest first)", "" }
  for _, item in ipairs(info.sent) do
    local text = vim.split(item.text, "\n", { plain = true })
    table.insert(lines, ("[%s] %s"):format(item.time, text[1]))
    for i = 2, #text do
      table.insert(lines, "           " .. text[i])
    end
  end
  vim.list_extend(lines, { "", "# Recent REPL output", "" })
  vim.list_extend(lines, info.output)
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_set_name(buf, "octave-dbg://debug/" .. buf)
end

-- :OctaveDbg ---------------------------------------------------------------

M.subcommands = {
  repl = { desc = "Open or show the Octave REPL", fn = M.repl },
  send = {
    desc = "Send the current line or a line range",
    fn = function(cmd)
      if cmd.range > 0 then
        repl.send_lines(0, cmd.line1, cmd.line2)
      else
        M.send_line()
      end
    end,
  },
  cell = { desc = "Send the cell under the cursor", fn = M.send_cell },
  run = { desc = "Save and run the current file", fn = M.run },
  ["break"] = {
    desc = "Toggle a breakpoint on the cursor line (or the given line)",
    fn = function(cmd)
      M.toggle_breakpoint(tonumber(cmd.args[1]))
    end,
  },
  step = { desc = "dbstep", fn = M.step },
  ["in"] = { desc = "dbstep in", fn = M.step_in },
  out = { desc = "dbstep out", fn = M.step_out },
  continue = { desc = "dbcont", fn = M.continue },
  quit = { desc = "dbquit", fn = M.quit },
  clear = { desc = "Remove all breakpoints", fn = M.clear_breakpoints },
  whos = { desc = "Show the workspace", fn = M.whos },
  panel = { desc = "Toggle the auto-refreshing variables panel", fn = M.panel },
  hover = { desc = "Show the variable under the cursor", fn = M.hover },
  help = {
    desc = "Show Octave help for a name (default: the name under the cursor)",
    fn = function(cmd)
      M.help(cmd.args[1])
    end,
  },
  runto = { desc = "Run or continue to the cursor line", fn = M.run_to_cursor },
  interrupt = { desc = "Send Ctrl+C to Octave", fn = M.interrupt },
  clc = { desc = "Clear the Octave console", fn = M.clc },
  close = { desc = "Close all figures", fn = M.close_figures },
  status = { desc = "Show REPL and breakpoint state", fn = M.status },
  debug = { desc = "Show sent commands and recent output", fn = M.debug },
}

--- Split command arguments into a subcommand name and the rest.
---@param fargs string[]
---@return string|nil name, string[] rest
function M.parse(fargs)
  local name = fargs[1]
  return name, vim.list_slice(fargs, 2)
end

--- Completion for :OctaveDbg.
function M.complete(arglead, cmdline)
  local before = cmdline:gsub("^%s*%S+%s*", "", 1)
  -- Only the first argument is completed.
  if before:find("%s") then
    return {}
  end
  local names = vim.tbl_filter(function(name)
    return vim.startswith(name, arglead)
  end, vim.tbl_keys(M.subcommands))
  table.sort(names)
  return names
end

--- Entry point for :OctaveDbg (receives the nvim_create_user_command table).
function M.command(opts)
  local name, rest = M.parse(opts.fargs)
  if not name then
    M.status()
    return
  end
  local sub = M.subcommands[name]
  if not sub then
    vim.notify("octave-dbg: unknown subcommand '" .. name .. "'", vim.log.levels.ERROR)
    return
  end
  sub.fn({ args = rest, range = opts.range, line1 = opts.line1, line2 = opts.line2 })
end

-- Setup --------------------------------------------------------------------

--- Default MATLAB-style keys. `false` switches a key off.
M.matlab_key_defaults = {
  run = "<F5>", -- run file, or continue when stopped
  quit = "<S-F5>", -- quit debugging
  send = "<F9>", -- send line (normal) or selection (visual)
  step = "<F10>",
  step_in = "<F11>",
  step_out = "<S-F11>",
  breakpoint = "<F12>",
  run_to_cursor = "<C-F10>",
  cell = "<C-CR>", -- run section; needs a terminal that sends Ctrl+Enter
  interrupt = "<C-c>",
  help = "<F1>",
}

--- Resolve the `matlab_keys` option: true gives the defaults, a table
--- changes or (with false) removes single keys, false gives none.
---@param value boolean|table|nil
---@return table<string, string>
function M.resolve_matlab_keys(value)
  if not value then
    return {}
  end
  local keys = vim.deepcopy(M.matlab_key_defaults)
  if type(value) == "table" then
    for action, lhs in pairs(value) do
      if M.matlab_key_defaults[action] == nil then
        vim.notify("octave-dbg: unknown matlab_keys action '" .. tostring(action) .. "'", vim.log.levels.WARN)
      else
        keys[action] = lhs or nil
      end
    end
  end
  return keys
end

local function set_matlab_keys(bufnr)
  local keys = M.resolve_matlab_keys(config.get("matlab_keys", bufnr))
  -- Most keys also work in insert mode, as in MATLAB's editor.
  local actions = {
    run = { { "n", "i" }, M.run_or_continue, "run file / continue" },
    quit = { { "n", "i" }, M.quit, "quit debugging" },
    step = { { "n", "i" }, M.step, "step" },
    step_in = { { "n", "i" }, M.step_in, "step in" },
    step_out = { { "n", "i" }, M.step_out, "step out" },
    breakpoint = { { "n", "i" }, M.toggle_breakpoint, "toggle breakpoint" },
    run_to_cursor = { { "n", "i" }, M.run_to_cursor, "run to cursor" },
    cell = { { "n", "i" }, M.send_cell, "run section" },
    interrupt = { { "n" }, M.interrupt, "interrupt (Ctrl+C)" },
    help = { { "n", "i" }, M.help, "help for name under cursor" },
  }
  for action, lhs in pairs(keys) do
    if action == "send" then
      vim.keymap.set("n", lhs, M.send_line, { buffer = bufnr, desc = "Octave: send line" })
      vim.keymap.set("x", lhs, M.send_selection, { buffer = bufnr, desc = "Octave: send selection" })
    elseif actions[action] then
      local a = actions[action]
      vim.keymap.set(a[1], lhs, function()
        a[2]()
      end, { buffer = bufnr, desc = "Octave: " .. a[3] })
    end
  end
end

local function set_keymaps(bufnr)
  local p = config.get("keymap_prefix", bufnr)
  local function map(mode, lhs, rhs, desc)
    vim.keymap.set(mode, p .. lhs, rhs, { buffer = bufnr, desc = "Octave: " .. desc })
  end
  map("n", "o", M.repl, "open REPL")
  map("n", "l", M.send_line, "send line")
  map("x", "s", M.send_selection, "send selection")
  map("n", "c", M.send_cell, "send cell")
  map("n", "f", M.run, "run file")
  map("n", "w", M.whos, "whos")
  map("n", "v", M.panel, "toggle variables panel")
  map("n", "h", M.hover, "show variable under cursor")
  map("n", "d", function()
    M.help()
  end, "help for name under cursor")
  map("n", "C", M.clc, "clear console")
  map("n", "x", M.close_figures, "close figures")
  map("n", "b", M.toggle_breakpoint, "toggle breakpoint")
  map("n", "B", M.clear_breakpoints, "clear all breakpoints")
  map("n", "n", M.step, "step")
  map("n", "i", M.step_in, "step in")
  map("n", "O", M.step_out, "step out")
  map("n", "r", M.continue, "continue")
  map("n", "t", M.run_to_cursor, "run to cursor")
  map("n", "k", M.interrupt, "interrupt (Ctrl+C)")
  map("n", "q", M.quit, "quit debugging")
  -- Name the group in which-key (LazyVim), if it is installed.
  local ok, wk = pcall(require, "which-key")
  if ok and type(wk.add) == "function" then
    pcall(wk.add, { { p, group = "Octave", buffer = bufnr, icon = { cat = "filetype", name = "matlab" } } })
  end
end

local function set_buffer_maps(bufnr)
  if config.get("setup_keymap", bufnr) then
    set_keymaps(bufnr)
  end
  set_matlab_keys(bufnr)
end

function M.setup(opts)
  config.set(opts)
  M._setup_modules()
  local group = vim.api.nvim_create_augroup("octave_dbg_keymaps", { clear = true })
  if not (config.get("setup_keymap") or config.get("matlab_keys")) then
    return
  end
  local filetypes = config.get("filetypes")
  vim.api.nvim_create_autocmd("FileType", {
    group = group,
    pattern = filetypes,
    callback = function(ev)
      set_buffer_maps(ev.buf)
    end,
  })
  -- Buffers that were opened before setup ran.
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and vim.tbl_contains(filetypes, vim.bo[buf].filetype) then
      set_buffer_maps(buf)
    end
  end
end

return M
