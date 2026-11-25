-- Breakpoint signs, drawn as extmarks so they follow edits to the buffer.

local config = require("octave_dbg.config")

local M = {}

M.ns = vim.api.nvim_create_namespace("octave_dbg_breakpoints")

local function marks_on(bufnr, line)
  return vim.api.nvim_buf_get_extmarks(bufnr, M.ns, { line - 1, 0 }, { line - 1, -1 }, {})
end

function M.has(bufnr, line)
  return #marks_on(bufnr, line) > 0
end

function M.place(bufnr, line)
  if M.has(bufnr, line) then
    return
  end
  vim.api.nvim_buf_set_extmark(bufnr, M.ns, line - 1, 0, {
    sign_text = config.get("sign_text", bufnr),
    sign_hl_group = config.get("sign_hl", bufnr),
    priority = 20,
  })
end

function M.remove(bufnr, line)
  for _, mark in ipairs(marks_on(bufnr, line)) do
    vim.api.nvim_buf_del_extmark(bufnr, M.ns, mark[1])
  end
end

--- Current sign lines (1-based, sorted, unique). They move as the buffer is edited.
function M.lines(bufnr)
  local seen, out = {}, {}
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, M.ns, 0, -1, {})) do
    local line = mark[2] + 1
    if not seen[line] then
      seen[line] = true
      table.insert(out, line)
    end
  end
  table.sort(out)
  return out
end

function M.clear(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
end

--- Replace the signs of a buffer with exactly `lines`.
function M.render(bufnr, lines)
  M.clear(bufnr)
  local count = vim.api.nvim_buf_line_count(bufnr)
  for _, line in ipairs(lines) do
    if line >= 1 and line <= count then
      M.place(bufnr, line)
    end
  end
end

return M
