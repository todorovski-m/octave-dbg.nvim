-- Ask Octave which breakpoints it really has.
--
-- Octave moves a breakpoint on a comment or empty line to the next line that
-- runs code, and silently ignores one after the end of the file. To show the
-- truth, debug.lua adds the snippet from M.request() to each dbstop/dbclear
-- command. It runs octave/octave_dbg_bps.m, which writes dbstatus to a temp
-- file before Octave prints its next prompt. While a request is open, this
-- module reads that file after each chunk of REPL output and passes a new
-- answer to the handler. (File system events are not used: on macOS they
-- can arrive seconds late under load.)

local repl = require("octave_dbg.repl")

local M = {}

local helper_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/octave"

local state = {
  file = nil, -- file that Octave writes
  seq = 0, -- id of the last request
  done = 0, -- id of the last answer passed to the handler
  path_chan = nil, -- job that already has helper_dir on its path
  handler = nil, -- fun(id, lines_by_path)
}

--- Parse the helper's file.
--- Returns the request id and { [resolved path] = { sorted unique lines } }.
--- The id is nil when the file is incomplete (no "#end" line yet).
---@param text string
---@return integer|nil id, table<string, integer[]> lines
function M.parse(text)
  local id
  local complete = false
  local sets = {}
  for _, row in ipairs(vim.split(text, "\n", { plain = true, trimempty = true })) do
    local a, b = row:match("^(.-)\t(%d+)$")
    if row == "#end" then
      complete = true
    elseif a == "#" then
      id = tonumber(b)
    elseif a then
      local path = vim.fn.resolve(a)
      sets[path] = sets[path] or {}
      sets[path][tonumber(b)] = true
    end
  end
  local out = {}
  for path, set in pairs(sets) do
    local lines = vim.tbl_keys(set)
    table.sort(lines)
    out[path] = lines
  end
  return complete and id or nil, out
end

local function read()
  local f = state.file and io.open(state.file, "r")
  if not f then
    return
  end
  local text = f:read("*a")
  f:close()
  local id, lines = M.parse(text)
  if id and id > state.done then
    state.done = id
    if state.handler then
      state.handler(id, lines)
    end
  end
end

local function on_output()
  if state.done < state.seq then
    read()
  end
end

--- Set the function that receives answers: fn(id, lines_by_resolved_path).
function M.on_result(fn)
  state.handler = fn
end

--- Octave code to append to a command, and the id of this request.
---@return string snippet, integer id
function M.request()
  if not state.file then
    state.file = vim.fn.tempname() .. "-bps.txt"
    repl.on_output("bpstatus", function()
      -- Output listeners run inside the job callback; read outside of it.
      vim.schedule(on_output)
    end)
  end
  state.seq = state.seq + 1
  local prefix = ""
  local chan = repl.info().chan
  if chan ~= state.path_chan then
    prefix = "addpath(" .. repl.quote(helper_dir) .. "); "
    state.path_chan = chan
  end
  return ("%soctave_dbg_bps(%s, %d);"):format(prefix, repl.quote(state.file), state.seq), state.seq
end

return M
