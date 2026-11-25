-- Variables panel: a split that shows the workspace and refreshes itself.
--
-- The shared Octave hook (see hook.lua) writes the variables of the current
-- scope (the base workspace, or the frame the debugger stopped in) to
-- whos.txt while the flag file panel.on exists. Opening and closing the panel
-- only create and remove that flag, so nothing is echoed in the REPL (apart
-- from the one command that starts the hook in a REPL job).
--
-- The panel checks whos.txt with a timer. File system events are not used:
-- on macOS they can arrive seconds late under load.

local config = require("octave_dbg.config")
local repl = require("octave_dbg.repl")
local hook = require("octave_dbg.hook")

local M = {}

local POLL_MS = 150

local state = {
  buf = nil, -- panel buffer
  timer = nil, -- poll timer
  stamp = nil, -- mtime and size of whos.txt at the last redraw
}

M.ns = vim.api.nvim_create_namespace("octave_dbg_panel")

--- Parse whos.txt as written by octave_dbg_hook.m.
---@param text string
---@return { scope: string, line: integer|nil, vars: table[] }
function M.parse(text)
  local data = { scope = "base", line = nil, vars = {} }
  for _, row in ipairs(vim.split(text, "\n", { plain = true, trimempty = true })) do
    local f = vim.split(row, "\t", { plain = true })
    if f[1] == "#" then
      data.scope = f[2] or "base"
      data.line = tonumber(f[3])
    elseif #f >= 4 then
      table.insert(data.vars, { name = f[1], size = f[2], class = f[3], bytes = tonumber(f[4]) or 0, value = f[5] or "" })
    end
  end
  return data
end

--- Lines shown in the panel for parsed data.
function M.format(data)
  local title = data.scope == "base" and "Variables: base workspace"
    or ("Variables: %s, line %s"):format(data.scope, tostring(data.line))
  local lines = { title }
  if #data.vars == 0 then
    table.insert(lines, "  (no variables)")
    return lines
  end
  local rows = { { "Name", "Size", "Class", "Bytes", "Value" } }
  for _, v in ipairs(data.vars) do
    table.insert(rows, { v.name, v.size, v.class, tostring(v.bytes), v.value })
  end
  local width = {}
  for _, row in ipairs(rows) do
    for i, cell in ipairs(row) do
      width[i] = math.max(width[i] or 0, vim.fn.strdisplaywidth(cell))
    end
  end
  for _, row in ipairs(rows) do
    local cells = {}
    for i, cell in ipairs(row) do
      cells[i] = i < #row and (cell .. string.rep(" ", width[i] - vim.fn.strdisplaywidth(cell))) or cell
    end
    table.insert(lines, "  " .. vim.trim(table.concat(cells, "  ")))
  end
  return lines
end

function M.is_open()
  return state.buf ~= nil and vim.api.nvim_buf_is_valid(state.buf)
end

local function render(text)
  if not M.is_open() then
    return
  end
  local lines = M.format(M.parse(text))
  local buf = state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
  if #lines > 2 then
    vim.api.nvim_buf_set_extmark(buf, M.ns, 1, 0, { end_col = #lines[2], hl_group = "Comment" })
  end
end

local function poll()
  if not M.is_open() then
    return
  end
  local st = vim.uv.fs_stat(hook.path("whos.txt"))
  if not st then
    return
  end
  local stamp = ("%d.%d:%d"):format(st.mtime.sec, st.mtime.nsec, st.size)
  if stamp == state.stamp then
    return
  end
  local text = hook.read("whos.txt")
  if text then
    state.stamp = stamp
    render(text)
  end
end

local function teardown()
  if state.timer and not state.timer:is_closing() then
    state.timer:close()
  end
  hook.remove("panel.on")
  hook.remove("whos.txt")
  state.buf, state.timer, state.stamp = nil, nil, nil
end

local function show_window()
  if #vim.fn.win_findbuf(state.buf) > 0 then
    return
  end
  local prev = vim.api.nvim_get_current_win()
  vim.cmd(config.get("panel_split"))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, state.buf)
  for opt, value in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false, winfixheight = true }) do
    vim.wo[win][opt] = value
  end
  vim.api.nvim_set_current_win(prev)
end

--- Open the panel (or show it again if its window was closed).
function M.open()
  if M.is_open() then
    show_window()
    return
  end
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].filetype = "octave_dbg_panel"
  vim.api.nvim_buf_set_name(state.buf, "octave-dbg://variables")
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, { "Variables: waiting for Octave..." })
  vim.bo[state.buf].modifiable = false
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = state.buf, once = true, callback = teardown })
  show_window()
  hook.remove("whos.txt")
  hook.write("panel.on", { "1" })
  state.timer = vim.uv.new_timer()
  state.timer:start(POLL_MS, POLL_MS, vim.schedule_wrap(poll))
  if repl.alive() then
    hook.ensure()
  else
    -- Starting the REPL fires OctaveDbgReplStarted, which starts the hook.
    repl.ensure()
  end
end

function M.close()
  if M.is_open() then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
end

function M.toggle()
  if M.is_open() and #vim.fn.win_findbuf(state.buf) > 0 then
    M.close()
  else
    M.open()
  end
end

function M.setup()
  local group = vim.api.nvim_create_augroup("octave_dbg_panel", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OctaveDbgReplStarted",
    callback = function()
      if M.is_open() then
        hook.ensure()
      end
    end,
  })
end

return M
