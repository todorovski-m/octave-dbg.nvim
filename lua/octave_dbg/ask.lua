-- One request and answer with the shared Octave hook (see hook.lua), used by
-- the hover, the help popup and the value viewer.
--
-- A request is written to <kind>.req as "ID<TAB>field<TAB>...". The hook
-- answers in <kind>.ans, which starts with "#<TAB>ID" and ends with "#end".
-- The answer file is checked every POLL_MS milliseconds until the timeout;
-- then the caller is told that Octave is busy. Requests run on a channel: a
-- new request on a channel cancels the previous one on that channel, and an
-- answer with another id is ignored.

local repl = require("octave_dbg.repl")
local hook = require("octave_dbg.hook")

local M = {}

M.POLL_MS = 50
-- Extra time for the first request in a REPL job, which also starts the hook.
M.FIRST_USE_MS = 2000

local seq = 0 -- id of the last request, over all channels
local channels = {} -- { [name] = { timer = uv_timer, id = integer } }

--- True for a plain name or a dotted struct field path such as "s.a.b".
function M.valid_name(name)
  if type(name) ~= "string" or name == "" then
    return false
  end
  for _, part in ipairs(vim.split(name, ".", { plain = true })) do
    if not part:match("^[%a][%w_]*$") then
      return false
    end
  end
  return true
end

--- The variable or struct field path under a byte column.
--- In `s.a.b`, the cursor on `a` gives "s.a" and on `b` gives "s.a.b".
--- In `x(2)`, the cursor on `x` gives "x".
---@param line string
---@param col integer 0-based byte column
---@return string|nil
function M.name_at(line, col)
  local i = col + 1
  local function word(k)
    local c = line:sub(k, k)
    return c ~= "" and c:match("[%w_]") ~= nil
  end
  if not word(i) then
    return nil
  end
  -- Start: walk back over words and the dots between them.
  local first = i
  while first > 1 and (word(first - 1) or (line:sub(first - 1, first - 1) == "." and word(first - 2))) do
    first = first - 1
  end
  -- End: the end of the word under the cursor.
  local last = i
  while word(last + 1) do
    last = last + 1
  end
  local name = line:sub(first, last)
  return M.valid_name(name) and name or nil
end

--- Parse an answer file: "key<TAB>value" lines, then "#body", the body
--- lines, and "#end". "#<TAB>ID" gives `id`; "scope<TAB>NAME<TAB>LINE" gives
--- `scope` and `line`.
---@param text string
---@return table
function M.parse(text)
  local out = { body = {} }
  local in_body = false
  for _, row in ipairs(vim.split(text, "\n", { plain = true })) do
    if row == "#end" then
      break
    elseif in_body then
      table.insert(out.body, row)
    elseif row == "#body" then
      in_body = true
    else
      local key, value = row:match("^([^\t]+)\t(.*)$")
      if key == "#" then
        out.id = tonumber(value)
      elseif key == "scope" then
        local fname, lnum = value:match("^(.-)\t(%d+)$")
        out.scope = fname or value
        out.line = tonumber(lnum)
      elseif key then
        out[key] = value
      end
    end
  end
  return out
end

--- "base workspace", or "NAME, line N" for the frame the debugger stopped in.
function M.scope_text(a)
  if not a.scope or a.scope == "base" then
    return "base workspace"
  end
  return ("%s, line %s"):format(a.scope, tostring(a.line))
end

local function cancel(name)
  local ch = channels[name]
  if ch and ch.timer and not ch.timer:is_closing() then
    ch.timer:close()
  end
  channels[name] = nil
end

--- Stop waiting for the open request on a channel, if any.
M.cancel = cancel

--- Send a request and wait for the answer.
---@param opts table
---   kind string        "hover", "help" or "view": the .req and .ans files
---   channel string     requests on one channel replace each other
---   fields string[]    request fields after the id
---   timeout integer    milliseconds before on_busy
---   on_answer fun(answer: table)
---   on_busy fun(timeout: integer)
---@return boolean sent false when the REPL is not running
function M.request(opts)
  if not repl.alive() then
    vim.notify("octave-dbg: the REPL is not running", vim.log.levels.WARN)
    return false
  end
  local first_use = not hook.running()
  if not hook.ensure() then
    return false
  end
  cancel(opts.channel)
  seq = seq + 1
  local id = seq
  hook.remove(opts.kind .. ".ans")
  hook.write(opts.kind .. ".req", { table.concat(vim.list_extend({ tostring(id) }, opts.fields), "\t") })

  local timeout = opts.timeout + (first_use and M.FIRST_USE_MS or 0)
  local deadline = vim.uv.now() + timeout
  local timer = vim.uv.new_timer()
  channels[opts.channel] = { timer = timer, id = id }
  timer:start(
    M.POLL_MS,
    M.POLL_MS,
    vim.schedule_wrap(function()
      local ch = channels[opts.channel]
      if not ch or ch.id ~= id then
        return
      end
      local text = hook.read(opts.kind .. ".ans")
      local answer = text and M.parse(text)
      if answer and answer.id == id then
        cancel(opts.channel)
        opts.on_answer(answer)
      elseif vim.uv.now() >= deadline then
        cancel(opts.channel)
        hook.remove(opts.kind .. ".req")
        opts.on_busy(timeout)
      end
    end)
  )
  return true
end

return M
