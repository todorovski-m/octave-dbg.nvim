-- Popups that ask the shared Octave hook (see hook.lua) about the name under
-- the cursor:
--
-- * hover: the value of a variable or struct field. Only names are looked
--   up, never expressions: the Octave side first checks that the base name
--   is a variable in the frame of the prompt, so nothing is run as code.
-- * help: the output of `help NAME`, as with F1 in MATLAB.
--
-- A request is written to <kind>.req; the answer comes back in <kind>.ans,
-- which is checked every POLL_MS milliseconds until `hover_timeout`.

local config = require("octave_dbg.config")
local repl = require("octave_dbg.repl")
local hook = require("octave_dbg.hook")

local M = {}

local POLL_MS = 50
-- Extra time for the first request in a REPL job, which also starts the hook.
local FIRST_USE_MS = 2000

M.ns = vim.api.nvim_create_namespace("octave_dbg_hover")

local state = {
  seq = 0, -- id of the last request
  timer = nil, -- poll timer of the open request
  win = nil, -- the popup window
}

local function valid_name(name)
  local parts = vim.split(name, ".", { plain = true })
  for _, part in ipairs(parts) do
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
  return valid_name(name) and name or nil
end

--- Parse hover.ans as written by octave_dbg_hook.m.
---@param text string
---@return table
function M.parse(text)
  local out = { body = {} }
  local rows = vim.split(text, "\n", { plain = true })
  local in_body = false
  for _, row in ipairs(rows) do
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

local function scope_text(a)
  if not a.scope or a.scope == "base" then
    return "base workspace"
  end
  return ("%s, line %s"):format(a.scope, tostring(a.line))
end

--- Lines shown in the help popup for a parsed answer.
---@param a table answer from M.parse
---@return string[]
function M.format_help(a)
  if a.status ~= "ok" then
    return { ("help %s: %s"):format(a.name, a.message or "error") }
  end
  local body = vim.deepcopy(a.body)
  while #body > 0 and vim.trim(body[1]) == "" do
    table.remove(body, 1)
  end
  while #body > 0 and vim.trim(body[#body]) == "" do
    table.remove(body)
  end
  local lines = { "help " .. a.name }
  vim.list_extend(lines, body)
  return lines
end

--- Lines shown in the floating window for a parsed answer.
---@param a table answer from M.parse
---@param max_lines integer
---@return string[]
function M.format(a, max_lines)
  if a.status == "notvar" then
    return { ("%s: not a variable (%s)"):format(a.name, scope_text(a)) }
  elseif a.status == "error" then
    return { ("%s: %s"):format(a.name, a.message or "error") }
  end
  local lines = { ("%s  %s %s  (%s)"):format(a.name, a.size or "?", a.class or "?", scope_text(a)) }
  if a.note and a.note ~= "" then
    table.insert(lines, "(" .. a.note .. ")")
  end
  local body = vim.deepcopy(a.body)
  while #body > 0 and vim.trim(body[1]) == "" do
    table.remove(body, 1)
  end
  while #body > 0 and vim.trim(body[#body]) == "" do
    table.remove(body)
  end
  local extra = #body - max_lines
  for k = 1, math.min(#body, max_lines) do
    table.insert(lines, body[k])
  end
  if extra > 0 then
    table.insert(lines, ("... %d more line%s"):format(extra, extra == 1 and "" or "s"))
  end
  return lines
end

local function stop_timer()
  if state.timer and not state.timer:is_closing() then
    state.timer:close()
  end
  state.timer = nil
end

local function show(lines, max_height)
  local buf, win = vim.lsp.util.open_floating_preview(lines, "", {
    border = config.get("hover_border"),
    focus_id = "octave_dbg_hover",
    max_height = max_height,
  })
  state.win = win
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_set_extmark(buf, M.ns, 0, 0, { end_col = #lines[1], hl_group = "Title" })
  end
end

-- A second press while the popup is open enters it, so that it can be
-- scrolled (as with LSP hover). Returns true when it did.
local function enter_open_popup()
  local win = state.win
  if win and vim.api.nvim_win_is_valid(win) and win ~= vim.api.nvim_get_current_win() then
    vim.api.nvim_set_current_win(win)
    return true
  end
  return false
end

--- Send a request to the hook and show the answer in a popup.
---@param kind string "hover" or "help": the files <kind>.req and <kind>.ans
---@param name string
---@param fields string[] request fields after the id
---@param render fun(answer: table): string[]
---@param max_height integer|nil
local function ask(kind, name, fields, render, max_height)
  if not repl.alive() then
    vim.notify("octave-dbg: the REPL is not running", vim.log.levels.WARN)
    return
  end
  local first_use = not hook.running()
  if not hook.ensure() then
    return
  end
  local win = vim.api.nvim_get_current_win()
  local buf = vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(win)
  stop_timer()
  state.seq = state.seq + 1
  local id = state.seq
  hook.remove(kind .. ".ans")
  hook.write(kind .. ".req", { table.concat(vim.list_extend({ tostring(id) }, fields), "\t") })

  local timeout = config.get("hover_timeout", buf) + (first_use and FIRST_USE_MS or 0)
  local deadline = vim.uv.now() + timeout
  local function still_here()
    return vim.api.nvim_get_current_win() == win and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
  end

  state.timer = vim.uv.new_timer()
  state.timer:start(
    POLL_MS,
    POLL_MS,
    vim.schedule_wrap(function()
      if id ~= state.seq then
        return
      end
      local text = hook.read(kind .. ".ans")
      local answer = text and M.parse(text)
      if answer and answer.id == id then
        stop_timer()
        if still_here() then
          show(render(answer), max_height)
        end
      elseif vim.uv.now() >= deadline then
        stop_timer()
        hook.remove(kind .. ".req")
        if still_here() then
          show({ ("%s: Octave is busy (no answer within %d ms)"):format(name, timeout) })
        end
      end
    end)
  )
end

local function name_under_cursor()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local name = M.name_at(vim.api.nvim_get_current_line(), col)
  if not name then
    vim.notify("octave-dbg: no name under the cursor", vim.log.levels.INFO)
  end
  return name
end

--- Show the value of the variable or struct field under the cursor.
function M.hover()
  if enter_open_popup() then
    return
  end
  local name = name_under_cursor()
  if not name then
    return
  end
  local buf = vim.api.nvim_get_current_buf()
  local max_lines = config.get("hover_max_lines", buf)
  ask("hover", name, { name, tostring(config.get("hover_max_elements", buf)) }, function(answer)
    return M.format(answer, max_lines)
  end)
end

--- Show `help NAME` for `name`, or for the name under the cursor.
--- Press the key again to enter the popup and scroll.
---@param name string|nil
function M.help(name)
  if not name and enter_open_popup() then
    return
  end
  name = name or name_under_cursor()
  if not name then
    return
  end
  if not valid_name(name) then
    vim.notify("octave-dbg: not a function name: " .. name, vim.log.levels.WARN)
    return
  end
  ask("help", name, { name }, M.format_help, config.get("help_max_height"))
end

return M
