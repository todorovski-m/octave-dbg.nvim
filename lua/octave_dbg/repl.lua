-- One Octave REPL terminal job per Neovim session.
--
-- The REPL opens in a split, the source window keeps focus, and text goes
-- to the job with chansend. If the job dies, the next send restarts it, up
-- to `max_restarts` times.

local config = require("octave_dbg.config")

local M = {}

local state = {
  buf = nil, -- terminal buffer
  chan = nil, -- job / channel id while the job runs
  cmd = nil, -- command that started the current job
  started = false, -- a job was started at least once
  stopping = false, -- the job is being stopped on purpose
  died = false, -- the last job exited without being asked to
  restarts = 0, -- automatic restarts since the last manual start
  sent = {}, -- recent commands: { time = "...", text = "..." }
  output = {}, -- recent output lines, escape codes removed
  partial = "", -- unfinished output line
}

-- Output listeners by key, see M.on_output.
local listeners = {}

local function push(list, item)
  table.insert(list, item)
  local max = config.get("log_size")
  while #list > max do
    table.remove(list, 1)
  end
end

--- Remove terminal escape sequences and carriage returns.
function M.strip_ansi(s)
  s = s:gsub("\27%[[%d;?]*[%a@`~]", "")
  s = s:gsub("\27%][^\7\27]*\7", "")
  s = s:gsub("\27[%(%)][%w]", "")
  s = s:gsub("\27[=>]", "")
  s = s:gsub("\r", "")
  return s
end

local function on_output(_, data)
  if not data then
    return
  end
  -- data[1] continues the previous partial line; the last item is a new
  -- partial line (or "" when the chunk ended with a newline).
  data[1] = state.partial .. data[1]
  state.partial = table.remove(data)
  local lines = {}
  for i, line in ipairs(data) do
    lines[i] = M.strip_ansi(line)
    push(state.output, lines[i])
  end
  local partial = M.strip_ansi(state.partial)
  for _, fn in pairs(listeners) do
    local ok, err = pcall(fn, lines, partial)
    if not ok then
      vim.schedule(function()
        vim.notify("octave-dbg: output listener failed: " .. tostring(err), vim.log.levels.ERROR)
      end)
    end
  end
end

--- Call `fn(lines, partial)` for each chunk of REPL output. `lines` are the
--- complete lines of the chunk and `partial` is the unfinished last line
--- (usually the prompt), both without escape codes. A second call with the
--- same key replaces the first.
---@param key string
---@param fn fun(lines: string[], partial: string)
function M.on_output(key, fn)
  listeners[key] = fn
end

local function on_exit(chan, code)
  if state.chan ~= chan then
    return
  end
  state.chan = nil
  vim.schedule(function()
    vim.api.nvim_exec_autocmds("User", { pattern = "OctaveDbgReplExited", modeline = false })
  end)
  if state.stopping then
    state.stopping = false
    return
  end
  state.died = true
  vim.schedule(function()
    vim.notify(("octave-dbg: Octave exited (code %d)"):format(code), vim.log.levels.WARN)
  end)
end

local function visible_win()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
    return nil
  end
  local wins = vim.fn.win_findbuf(state.buf)
  return wins[1]
end

--- True while the Octave job is running.
function M.alive()
  return state.chan ~= nil and vim.fn.jobwait({ state.chan }, 0)[1] == -1
end

--- Open a window that shows the REPL buffer, keeping focus where it was.
function M.show()
  if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) or visible_win() then
    return
  end
  local prev = vim.api.nvim_get_current_win()
  vim.cmd(config.get("split"))
  vim.api.nvim_win_set_buf(0, state.buf)
  vim.api.nvim_set_current_win(prev)
end

local function open_terminal(cmd)
  local prev = vim.api.nvim_get_current_win()
  local old_buf = state.buf
  local win = visible_win()
  if win then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd(config.get("split"))
  end
  local buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_win_set_buf(0, buf)
  local job_opts = { on_stdout = on_output, on_exit = on_exit }
  local chan
  if vim.fn.has("nvim-0.11") == 1 then
    job_opts.term = true
    chan = vim.fn.jobstart(cmd, job_opts)
  else
    chan = vim.fn.termopen(cmd, job_opts)
  end
  vim.bo[buf].bufhidden = "hide"
  if old_buf and old_buf ~= buf and vim.api.nvim_buf_is_valid(old_buf) then
    pcall(vim.api.nvim_buf_delete, old_buf, { force = true })
  end
  if vim.api.nvim_win_is_valid(prev) then
    vim.api.nvim_set_current_win(prev)
  end
  return buf, chan
end

--- Start the REPL (or show it if it already runs).
---@param opts? { manual?: boolean }  manual starts reset the restart counter
---@return integer|nil chan
function M.start(opts)
  opts = opts or {}
  if M.alive() then
    M.show()
    return state.chan
  end
  local cmd = config.get("cmd")
  local buf, chan = open_terminal(cmd)
  if not chan or chan <= 0 then
    vim.notify("octave-dbg: could not start " .. vim.inspect(cmd), vim.log.levels.ERROR)
    return nil
  end
  state.buf, state.chan, state.cmd = buf, chan, cmd
  state.started, state.died, state.partial = true, false, ""
  if opts.manual then
    state.restarts = 0
  end
  vim.api.nvim_exec_autocmds("User", { pattern = "OctaveDbgReplStarted", modeline = false })
  return chan
end

--- Make sure a job runs, restarting a dead one within the retry cap.
---@return boolean
function M.ensure()
  if M.alive() then
    return true
  end
  if state.died then
    local max = config.get("max_restarts")
    if state.restarts >= max then
      vim.notify(
        ("octave-dbg: Octave died %d times; run :OctaveDbg repl to start it again"):format(state.restarts + 1),
        vim.log.levels.ERROR
      )
      return false
    end
    state.restarts = state.restarts + 1
    vim.notify(("octave-dbg: restarting Octave (%d/%d)"):format(state.restarts, max), vim.log.levels.WARN)
  end
  return M.start() ~= nil
end

--- Stop the job on purpose (no automatic restart).
---
--- Octave is asked to exit first. Stopped by a signal (as jobstop does),
--- Octave writes its variables to an "octave-workspace" crash dump in its
--- working folder. So: Ctrl+U (clear a half-typed line) and "exit"; if
--- Octave is still there after a second, Ctrl+C (stop a running command)
--- and "exit" again; a signal only as the last resort. This waits for up to
--- about 2.5 seconds.
function M.stop()
  if not M.alive() then
    return
  end
  state.stopping = true
  local chan = state.chan
  local function exited(ms)
    return vim.fn.jobwait({ chan }, ms)[1] ~= -1
  end
  pcall(vim.fn.chansend, chan, "\21exit\n")
  if exited(1000) then
    return
  end
  pcall(vim.fn.chansend, chan, "\3")
  exited(200) -- give Ctrl+C time to stop the command
  pcall(vim.fn.chansend, chan, "\21exit\n")
  if exited(1300) then
    return
  end
  vim.fn.jobstop(chan)
end

-- When Neovim quits right after Octave was stopped, or with Octave still
-- running, Octave can survive as an orphan process that keeps using CPU.
-- Stop it on exit (asking it to exit first, see M.stop) and wait for it
-- (Neovim sends SIGKILL after 2 seconds).
vim.api.nvim_create_autocmd("VimLeavePre", {
  group = vim.api.nvim_create_augroup("octave_dbg_repl", { clear = true }),
  callback = function()
    if state.chan then
      local chan = state.chan
      M.stop()
      vim.fn.jobwait({ chan }, 3000)
    end
  end,
})

local function scroll_to_end()
  vim.schedule(function()
    if not (state.buf and vim.api.nvim_buf_is_valid(state.buf)) then
      return
    end
    local last = vim.api.nvim_buf_line_count(state.buf)
    for _, win in ipairs(vim.fn.win_findbuf(state.buf)) do
      pcall(vim.api.nvim_win_set_cursor, win, { last, 0 })
    end
  end)
end

--- Send text to Octave. A newline is added.
---@param text string
---@param opts? { raw?: boolean }  raw skips bracketed paste
---@return boolean sent
function M.send(text, opts)
  opts = opts or {}
  text = text:gsub("\n+$", "")
  if text:match("^%s*$") then
    return false
  end
  if not M.ensure() then
    return false
  end
  local payload = text .. "\n"
  if not opts.raw and text:find("\n") and config.get("bracketed_paste") then
    payload = "\27[200~" .. text .. "\27[201~\n"
  end
  push(state.sent, { time = os.date("%H:%M:%S"), text = text })
  vim.fn.chansend(state.chan, payload)
  scroll_to_end()
  return true
end

--- Send Ctrl+C to Octave, which stops a running command (like Ctrl+C in
--- MATLAB's Command Window). Does nothing when the REPL is not running.
---@return boolean sent
function M.interrupt()
  if not M.alive() then
    vim.notify("octave-dbg: the REPL is not running", vim.log.levels.WARN)
    return false
  end
  push(state.sent, { time = os.date("%H:%M:%S"), text = "<Ctrl-C>" })
  vim.fn.chansend(state.chan, "\3")
  return true
end

--- Quote a string as an Octave single-quoted literal.
function M.quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

--- Send lines l1..l2 (1-based, inclusive) of a buffer.
function M.send_lines(bufnr, l1, l2)
  local lines = vim.api.nvim_buf_get_lines(bufnr, l1 - 1, l2, false)
  return M.send(table.concat(lines, "\n"))
end

--- Send the current visual selection (charwise, linewise or blockwise).
function M.send_selection()
  local mode = vim.fn.mode()
  local lines
  if mode:match("^[vV\22]") then
    lines = vim.fn.getregion(vim.fn.getpos("v"), vim.fn.getpos("."), { type = mode })
    vim.api.nvim_feedkeys(vim.keycode("<Esc>"), "nx", false)
  else
    lines = vim.fn.getregion(vim.fn.getpos("'<"), vim.fn.getpos("'>"), { type = vim.fn.visualmode() })
  end
  return M.send(table.concat(lines, "\n"))
end

--- Find the cell around `row` in `lines`.
--- A cell starts after a delimiter line and ends before the next one.
---@param lines string[]
---@param row integer 1-based cursor line
---@param pattern string Vim regex for delimiter lines
---@return integer first, integer last  1-based, inclusive; first > last when empty
function M.cell_bounds(lines, row, pattern)
  local re = vim.regex(pattern)
  local function is_delim(i)
    return re:match_str(lines[i]) ~= nil
  end
  local first = 1
  for i = row, 1, -1 do
    if is_delim(i) then
      first = i + 1
      break
    end
  end
  local last = #lines
  for i = math.max(row + 1, first), #lines do
    if is_delim(i) then
      last = i - 1
      break
    end
  end
  return first, last
end

--- Send the %% cell under the cursor.
function M.send_cell(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local first, last = M.cell_bounds(lines, row, config.get("cell_delimiter", bufnr))
  if first > last then
    return false
  end
  return M.send_lines(bufnr, first, last)
end

--- Snapshot of the REPL state for status and debug views.
function M.info()
  return {
    alive = M.alive(),
    started = state.started,
    died = state.died,
    chan = state.chan,
    buf = state.buf,
    cmd = state.cmd,
    restarts = state.restarts,
    max_restarts = config.get("max_restarts"),
    sent = vim.deepcopy(state.sent),
    output = vim.deepcopy(state.output),
  }
end

return M
