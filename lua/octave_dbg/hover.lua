-- Popups that ask the shared Octave hook (see hook.lua) about the name under
-- the cursor:
--
-- * hover: the value of a variable or struct field. Only names are looked
--   up, never expressions: the Octave side first checks that the base name
--   is a variable in the frame of the prompt, so nothing is run as code.
-- * help: the output of `help NAME`, as with F1 in MATLAB.
--
-- The request and answer code is shared with the viewer, see ask.lua.

local config = require("octave_dbg.config")
local ask = require("octave_dbg.ask")

local M = {}

M.ns = vim.api.nvim_create_namespace("octave_dbg_hover")

local state = {
  win = nil, -- the popup window
}

-- Shared with the viewer; kept here for callers and tests.
M.name_at = ask.name_at
M.parse = ask.parse
local scope_text = ask.scope_text

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
  return buf, win
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

--- Ask the hook and show the answer in a popup, but only when the cursor
--- has not moved in the meantime.
---@param kind string "hover" or "help"
---@param name string
---@param fields string[] request fields after the id
---@param render fun(answer: table): string[]
---@param max_height integer|nil
---@param after fun(answer: table, buf: integer, win: integer)|nil
local function popup_request(kind, name, fields, render, max_height, after)
  local win = vim.api.nvim_get_current_win()
  local cursor = vim.api.nvim_win_get_cursor(win)
  local function still_here()
    return vim.api.nvim_get_current_win() == win and vim.deep_equal(vim.api.nvim_win_get_cursor(win), cursor)
  end
  ask.request({
    kind = kind,
    channel = "popup",
    fields = fields,
    timeout = config.get("hover_timeout"),
    on_answer = function(answer)
      if still_here() then
        local pbuf, pwin = show(render(answer), max_height)
        if after then
          after(answer, pbuf, pwin)
        end
      end
    end,
    on_busy = function(timeout)
      if still_here() then
        show({ ("%s: Octave is busy (no answer within %d ms)"):format(name, timeout) })
      end
    end,
  })
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
  -- A large value (shown as a summary) or a struct: <CR> opens the viewer,
  -- where the fields of a struct can be opened one by one.
  local function large(answer)
    return answer.status == "ok" and ((answer.note ~= nil and answer.note ~= "") or answer.class == "struct")
  end
  popup_request("hover", name, { name, tostring(config.get("hover_max_elements", buf)) }, function(answer)
    local lines = M.format(answer, max_lines)
    if large(answer) then
      -- Right under the header, so that it stays visible in a long popup.
      table.insert(lines, 2, "(Enter in this popup: open the viewer)")
    end
    return lines
  end, nil, function(answer, pbuf, pwin)
    -- A large value: <CR> in the popup opens the full-value viewer.
    if large(answer) and pbuf and vim.api.nvim_buf_is_valid(pbuf) then
      vim.keymap.set("n", "<CR>", function()
        if pwin and vim.api.nvim_win_is_valid(pwin) then
          vim.api.nvim_win_close(pwin, true)
        end
        require("octave_dbg.viewer").open(answer.name)
      end, { buffer = pbuf, desc = "octave-dbg: open the value viewer" })
    end
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
  if not ask.valid_name(name) then
    vim.notify("octave-dbg: not a function name: " .. name, vim.log.levels.WARN)
    return
  end
  popup_request("help", name, { name }, M.format_help, config.get("help_max_height"))
end

return M
