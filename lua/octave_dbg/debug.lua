-- Breakpoints and stepping through Octave's CLI debugger.
--
-- Notes on Octave 11.1 (see README, "How it works"):
-- * dbstop/dbclear accept a function or script name, not a file path, and
--   the file's folder must be on the load path. So every command first runs
--   addpath('<absolute folder>') and then dbstop('<name>', '<line>').
-- * Breakpoints in scripts work when the script is started with run().
-- * Octave drops the breakpoints of a file when the file changes on disk,
--   so they are sent again after each save and after a REPL restart.
-- * Octave moves a breakpoint on a comment or empty line to the next code
--   line and silently ignores one after the end of the file. Each command
--   therefore asks Octave for dbstatus (see bpstatus.lua), and the stored
--   lines and the signs are set to what Octave reports.

local repl = require("octave_dbg.repl")
local signs = require("octave_dbg.signs")
local bpstatus = require("octave_dbg.bpstatus")
local marker = require("octave_dbg.marker")

local M = {}

-- Breakpoints by absolute file path: { [path] = { [line] = true } }
local breakpoints = {}
-- Id of the latest dbstatus request for each path.
local requested = {}
-- Paths with a re-send pending after a save: { [path] = token }.
local resend_pending = {}
-- Functions waiting until no re-send is pending (see after_resends).
local waiting = {}
-- Temporary breakpoint of "run to cursor":
-- { path, line, id = sync request id, actual = Octave's line, false when
--   Octave placed nothing new, nil until known; done = Octave stopped or
--   finished }
local temp = nil

local function file_of(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  return vim.fn.fnamemodify(name, ":p")
end

local function sorted_lines(set)
  local out = vim.tbl_keys(set or {})
  table.sort(out)
  return out
end

--- Octave name of a file (file name without folder and extension).
function M.octave_name(path)
  return vim.fn.fnamemodify(path, ":t:r")
end

--- True when Octave can address the file by name.
function M.valid_name(path)
  return M.octave_name(path):match("^[%a][%w_]*$") ~= nil and path:match("%.m$") ~= nil
end

local function db_cmd(fn, path, lines)
  local parts = { "addpath(" .. repl.quote(vim.fn.fnamemodify(path, ":h")) .. ")" }
  local name = repl.quote(M.octave_name(path))
  for _, line in ipairs(lines) do
    table.insert(parts, ("%s(%s, '%d')"):format(fn, name, line))
  end
  return table.concat(parts, "; ") .. ";"
end

--- Command that sets breakpoints at `lines` in `path`.
--- `[~] =` keeps dbstop from overwriting the user's `ans` with the line number.
function M.dbstop_cmd(path, lines)
  return db_cmd("[~] = dbstop", path, lines)
end

--- Command that removes breakpoints at `lines` in `path`.
function M.dbclear_cmd(path, lines)
  return db_cmd("dbclear", path, lines)
end

--- Save a modified buffer. Returns true when it was written.
local function save_if_modified(bufnr)
  if vim.bo[bufnr].modified then
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent write")
    end)
    return true
  end
  return false
end

local function check_file(bufnr)
  local path = file_of(bufnr)
  if not path then
    vim.notify("octave-dbg: buffer has no file name", vim.log.levels.WARN)
    return nil
  end
  if not M.valid_name(path) then
    vim.notify(
      "octave-dbg: Octave cannot address '" .. vim.fn.fnamemodify(path, ":t") .. "' (needs a valid identifier and .m)",
      vim.log.levels.WARN
    )
    return nil
  end
  return path
end

--- Send a dbstop/dbclear command with a dbstatus request for `path`.
local function send_synced(cmd, path)
  local snippet, id = bpstatus.request()
  requested[path] = id
  repl.send(cmd .. " " .. snippet, { raw = true })
end

--- Send the stored breakpoints of one file to Octave.
local function apply(path)
  local lines = sorted_lines(breakpoints[path])
  if #lines > 0 then
    send_synced(M.dbstop_cmd(path, lines), path)
  end
end

--- Send the breakpoints of `path` again a little over a second from now.
--- When dbstop arrives within the second of a write, Octave reloads the file
--- once more and drops the breakpoint again.
local function schedule_resend(path)
  local token = {}
  resend_pending[path] = token
  vim.defer_fn(function()
    if resend_pending[path] ~= token then
      return -- a later save scheduled its own re-send
    end
    resend_pending[path] = nil
    if repl.alive() and breakpoints[path] then
      apply(path)
    end
    if next(resend_pending) == nil then
      local fns = waiting
      waiting = {}
      for _, fn in ipairs(fns) do
        fn()
      end
    end
  end, 1100)
end

--- Call `fn` now, or after the pending re-sends when a file was just saved.
--- Running code before that would miss the breakpoints that Octave dropped
--- on the save.
local function after_resends(fn)
  if next(resend_pending) == nil then
    fn()
  else
    table.insert(waiting, fn)
  end
end

--- Message for a difference between the plugin's lines and Octave's lines.
---@param fname string file name for the message
---@param old integer[] lines the plugin had (sorted)
---@param new integer[] lines Octave reports (sorted)
---@return string|nil
function M.sync_message(fname, old, new)
  local in_new = {}
  for _, l in ipairs(new) do
    in_new[l] = true
  end
  local dropped = vim.tbl_filter(function(l)
    return not in_new[l]
  end, old)
  if #dropped == 0 then
    return nil
  end
  local function list(t)
    return table.concat(t, ", ")
  end
  if #new == 0 then
    return ("octave-dbg: %s: Octave did not accept a breakpoint at line %s"):format(fname, list(dropped))
  end
  return ("octave-dbg: %s: Octave has breakpoints at line %s, not at line %s"):format(fname, list(new), list(dropped))
end

local function loaded_buf(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and file_of(buf) == path then
      return buf
    end
  end
end

--- Set the breakpoints of `path` to the lines Octave reports.
local function set_lines(path, lines)
  local buf = loaded_buf(path)
  -- A breakpoint on a comment after the last code line of a script lands on
  -- a line after the end of the file (Octave 11). It cannot be shown or
  -- toggled, so remove it in Octave and treat it as not accepted.
  local count = buf and vim.api.nvim_buf_line_count(buf) or #vim.fn.readfile(path)
  local beyond = vim.tbl_filter(function(l)
    return l > count
  end, lines)
  if #beyond > 0 then
    lines = vim.tbl_filter(function(l)
      return l <= count
    end, lines)
    if repl.alive() then
      repl.send(M.dbclear_cmd(path, beyond), { raw = true })
    end
  end
  local old = sorted_lines(breakpoints[path])
  if vim.deep_equal(old, lines) then
    return
  end
  local set = {}
  for _, l in ipairs(lines) do
    set[l] = true
  end
  breakpoints[path] = next(set) and set or nil
  if buf then
    signs.render(buf, lines)
  end
  local msg = M.sync_message(vim.fn.fnamemodify(path, ":t"), old, lines)
  if msg then
    vim.notify(msg, vim.log.levels.INFO)
  end
end

--- Remove the temporary breakpoint of "run to cursor" from Octave.
local function finish_temp()
  local t = temp
  temp = nil
  if t and t.actual and repl.alive() then
    -- dbclear with the requested line also removes a breakpoint that Octave
    -- moved to the next code line.
    repl.send(M.dbclear_cmd(t.path, { t.line }), { raw = true })
  end
end

--- The line where Octave put a temporary breakpoint requested at `line`:
--- the first line at or after it that is not a stored breakpoint, or false.
---@param octave_lines integer[] sorted
---@param stored table<integer, boolean>
---@param line integer
function M.temp_line(octave_lines, stored, line)
  for _, l in ipairs(octave_lines) do
    if l >= line and not stored[l] then
      return l
    end
  end
  return false
end

-- An answer covers every request with the same or a lower id.
local function on_sync(id, lines_by_path)
  local t = temp
  if t and t.actual == nil and id >= t.id then
    t.actual = M.temp_line(lines_by_path[vim.fn.resolve(t.path)] or {}, breakpoints[t.path] or {}, t.line)
  end
  for path, req in pairs(requested) do
    if id >= req and not resend_pending[path] then
      requested[path] = nil
      local lines = lines_by_path[vim.fn.resolve(path)] or {}
      if t and t.actual and t.path == path and not (breakpoints[path] or {})[t.actual] then
        lines = vim.tbl_filter(function(l)
          return l ~= t.actual
        end, lines)
      end
      set_lines(path, lines)
    end
  end
  if t and t == temp and t.done and t.actual ~= nil then
    finish_temp()
  end
end

-- Watches the REPL output after "run to cursor": the next stop or prompt
-- means that Octave stopped or the run ended.
local function temp_listener(lines, partial)
  local t = temp
  if not t or t.done then
    return
  end
  local stopped = false
  for _, line in ipairs(lines) do
    if marker.parse_stop(line) then
      stopped = true
    end
  end
  if stopped or marker.prompt_kind(partial) then
    t.done = true
    repl.on_output("runto", nil)
    vim.schedule(function()
      if temp == t and t.actual ~= nil then
        finish_temp()
      end
    end)
  end
end

--- Toggle a breakpoint at `line` (default: cursor line).
function M.toggle(bufnr, line)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  line = line or vim.api.nvim_win_get_cursor(0)[1]
  local path = check_file(bufnr)
  if not path then
    return
  end
  local count = vim.api.nvim_buf_line_count(bufnr)
  if line < 1 or line > count then
    vim.notify(("octave-dbg: line %d is outside the file (1-%d)"):format(line, count), vim.log.levels.WARN)
    return
  end
  local wrote = save_if_modified(bufnr)
  local set = breakpoints[path] or {}
  breakpoints[path] = set
  local adding = not set[line]
  if adding then
    set[line] = true
    signs.place(bufnr, line)
  else
    set[line] = nil
    signs.remove(bufnr, line)
  end
  if next(set) == nil then
    breakpoints[path] = nil
  end
  if not repl.alive() then
    if adding then
      -- Starting the REPL applies every stored breakpoint, this one included.
      repl.ensure()
    end
    return
  end
  if wrote or resend_pending[path] then
    -- The file just changed on disk. The delayed re-send sends all stored
    -- lines, this change included.
    if not resend_pending[path] then
      schedule_resend(path)
    end
    return
  end
  local cmd = adding and M.dbstop_cmd(path, { line }) or M.dbclear_cmd(path, { line })
  send_synced(cmd, path)
end

--- Remove every breakpoint.
function M.clear_all()
  breakpoints = {}
  requested = {}
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      signs.clear(buf)
    end
  end
  if repl.alive() then
    repl.send("dbclear all;", { raw = true })
  end
end

--- Breakpoints as a sorted list: { { path = "...", lines = { ... } }, ... }
function M.list()
  local out = {}
  for _, path in ipairs(vim.tbl_keys(breakpoints)) do
    table.insert(out, { path = path, lines = sorted_lines(breakpoints[path]) })
  end
  table.sort(out, function(a, b)
    return a.path < b.path
  end)
  return out
end

--- Save and run the file of a buffer with run('<absolute path>').
function M.run(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local path = file_of(bufnr)
  if not path then
    vim.notify("octave-dbg: buffer has no file name", vim.log.levels.WARN)
    return
  end
  save_if_modified(bufnr)
  after_resends(function()
    repl.send("run(" .. repl.quote(path) .. ")", { raw = true })
  end)
end

--- Continue when the debugger is stopped, else run the file (F5 in MATLAB).
function M.run_or_continue(bufnr)
  if marker.current() then
    M.continue()
  else
    M.run(bufnr)
  end
end

--- Run or continue until the cursor line (MATLAB "Run to Cursor"). A
--- temporary breakpoint is set at the cursor and removed when Octave stops
--- (there or at another breakpoint) or the run ends. It gets no sign.
function M.run_to_cursor(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local path = check_file(bufnr)
  if not path then
    return
  end
  save_if_modified(bufnr)
  local go = marker.current() and "dbcont" or ("run(" .. repl.quote(path) .. ")")
  after_resends(function()
    if not repl.ensure() then
      return
    end
    if (breakpoints[path] or {})[line] then
      repl.send(go, { raw = true }) -- a real breakpoint is already there
      return
    end
    if temp then
      finish_temp()
    end
    local snippet, id = bpstatus.request()
    temp = { path = path, line = line, id = id, actual = nil, done = false }
    repl.on_output("runto", temp_listener)
    -- One command line: the prompt only comes back when Octave stops or the
    -- run ends, which is what temp_listener waits for.
    repl.send(M.dbstop_cmd(path, { line }) .. " " .. snippet .. " " .. go, { raw = true })
  end)
end

function M.step()
  repl.send("dbstep", { raw = true })
end

function M.step_in()
  repl.send("dbstep in", { raw = true })
end

function M.step_out()
  repl.send("dbstep out", { raw = true })
end

function M.continue()
  repl.send("dbcont", { raw = true })
end

function M.quit()
  repl.send("dbquit", { raw = true })
end

--- Autocommands that keep Octave, the stored state and the signs in sync.
function M.setup()
  local group = vim.api.nvim_create_augroup("octave_dbg_debug", { clear = true })
  bpstatus.on_result(on_sync)

  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = "OctaveDbgReplStarted",
    callback = function()
      for _, path in ipairs(vim.tbl_keys(breakpoints)) do
        apply(path)
      end
    end,
  })

  -- Octave forgets breakpoints when a file changes on disk. Take the lines
  -- from the signs (they followed any edits) and send them again.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = group,
    callback = function(ev)
      local path = file_of(ev.buf)
      if not (path and breakpoints[path]) then
        return
      end
      local set = {}
      for _, line in ipairs(signs.lines(ev.buf)) do
        set[line] = true
      end
      breakpoints[path] = next(set) and set or nil
      schedule_resend(path)
    end,
  })

  -- Draw signs again when a file with breakpoints is (re)loaded.
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter" }, {
    group = group,
    callback = function(ev)
      local path = file_of(ev.buf)
      -- Signs that are still there may have moved with unsaved edits; keep them.
      if path and breakpoints[path] and #signs.lines(ev.buf) == 0 then
        signs.render(ev.buf, sorted_lines(breakpoints[path]))
      end
    end,
  })
end

return M
