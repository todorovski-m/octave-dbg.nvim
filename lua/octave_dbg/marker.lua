-- Current-line marker: shows where the debugger stopped.
--
-- Octave prints `stopped in <name> at line <n> [<absolute path>]` when it
-- stops, then waits at the `debug>` prompt. When the normal prompt
-- (`octave:N>`) comes back, the debug session is over. The REPL output is
-- scanned as it arrives; the marker itself is updated after a short quiet
-- time (option `marker_debounce`), so fast stepping does not redraw for every
-- chunk of output.

local config = require("octave_dbg.config")
local repl = require("octave_dbg.repl")

local M = {}

M.ns = vim.api.nvim_create_namespace("octave_dbg_current_line")

local current = nil -- { name, line, path, buf } of the shown stop
local pending = nil -- { kind = "stop", stop = ... } or { kind = "clear" }
local timer = nil

--- Parse one output line. Returns { name, line, path } for a stop line.
---@param line string
function M.parse_stop(line)
  local name, lnum, path = line:match("stopped in (%S+) at line (%d+) %[(.-)%]")
  if name then
    return { name = name, line = tonumber(lnum), path = path }
  end
end

--- Kind of prompt in `text`: "debug", "normal" or nil.
---@param text string
---@param patterns? string[] normal prompt patterns
---@param debug_pattern? string
function M.prompt_kind(text, patterns, debug_pattern)
  debug_pattern = debug_pattern or config.get("debug_prompt_pattern")
  if text:match(debug_pattern) then
    return "debug"
  end
  for _, pat in ipairs(patterns or config.get("prompt_patterns")) do
    if text:match(pat) then
      return "normal"
    end
  end
  return nil
end

--- Fold one chunk of output into the pending update.
--- Pure apart from the patterns; exposed for tests.
---@param state table|nil previous pending update
---@param lines string[]
---@param partial string
---@return table|nil
function M.reduce(state, lines, partial, patterns, debug_pattern)
  for _, line in ipairs(lines) do
    local stop = M.parse_stop(line)
    if stop then
      state = { kind = "stop", stop = stop }
    end
  end
  if M.prompt_kind(partial, patterns, debug_pattern) == "normal" then
    state = { kind = "clear" }
  end
  return state
end

local function find_buf(path)
  local target = vim.fn.resolve(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name ~= "" and vim.fn.resolve(vim.fn.fnamemodify(name, ":p")) == target then
        return buf
      end
    end
  end
end

local function is_source_win(win)
  local buf = vim.api.nvim_win_get_buf(win)
  return vim.bo[buf].buftype == "" and vim.api.nvim_win_get_config(win).relative == ""
end

-- Window for showing a file: one that already shows it, else the current
-- window if it holds a normal file, else the first such window.
local function source_win(buf)
  if buf then
    for _, win in ipairs(vim.fn.win_findbuf(buf)) do
      return win
    end
  end
  local cur = vim.api.nvim_get_current_win()
  if is_source_win(cur) then
    return cur
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_source_win(win) then
      return win
    end
  end
end

function M.clear()
  if current and current.buf and vim.api.nvim_buf_is_valid(current.buf) then
    vim.api.nvim_buf_clear_namespace(current.buf, M.ns, 0, -1)
  end
  current = nil
end

--- Show the marker for a stop. Opens the file when `follow` is on.
function M.show(stop)
  M.clear()
  current = vim.deepcopy(stop)
  local buf = find_buf(stop.path)
  local win
  if config.get("follow") then
    win = source_win(buf)
    if win and not buf then
      pcall(vim.api.nvim_win_call, win, function()
        vim.cmd("edit " .. vim.fn.fnameescape(stop.path))
      end)
      buf = find_buf(stop.path)
    elseif win and buf and vim.api.nvim_win_get_buf(win) ~= buf then
      vim.api.nvim_win_set_buf(win, buf)
    end
  end
  if not buf or stop.line > vim.api.nvim_buf_line_count(buf) then
    return
  end
  current.buf = buf
  vim.api.nvim_buf_set_extmark(buf, M.ns, stop.line - 1, 0, {
    sign_text = config.get("marker_sign_text", buf),
    sign_hl_group = config.get("marker_sign_hl", buf),
    line_hl_group = config.get("marker_line_hl", buf),
    priority = 30,
  })
  if win and vim.api.nvim_win_get_buf(win) == buf then
    pcall(vim.api.nvim_win_set_cursor, win, { stop.line, 0 })
  end
end

--- The stop that is shown now, or nil.
function M.current()
  return current and vim.deepcopy(current) or nil
end

local function flush()
  local update = pending
  pending = nil
  if not update or not config.get("marker") then
    return
  end
  if update.kind == "stop" then
    M.show(update.stop)
    vim.api.nvim_exec_autocmds("User", { pattern = "OctaveDbgStopped", modeline = false, data = update.stop })
  elseif current then
    M.clear()
    vim.api.nvim_exec_autocmds("User", { pattern = "OctaveDbgEnded", modeline = false })
  end
end

local function on_output(lines, partial)
  local before = pending
  pending = M.reduce(pending, lines, partial)
  if pending == before then
    return
  end
  timer = timer or vim.uv.new_timer()
  timer:stop()
  timer:start(config.get("marker_debounce"), 0, vim.schedule_wrap(flush))
end

local function set_hl()
  vim.api.nvim_set_hl(0, "OctaveDbgCurrentLine", { default = true, link = "Visual" })
end

function M.setup()
  set_hl()
  repl.on_output("marker", on_output)
  local group = vim.api.nvim_create_augroup("octave_dbg_marker", { clear = true })
  vim.api.nvim_create_autocmd("ColorScheme", { group = group, callback = set_hl })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OctaveDbgReplExited",
    callback = function()
      pending = nil
      M.clear()
    end,
  })
end

return M
