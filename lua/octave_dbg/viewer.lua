-- Large-value viewer: a read-only buffer that shows one window of a value.
--
-- Octave never formats a whole large value: each key press sends a request
-- for one window (see octave_dbg_view.m), through the shared hook and the
-- request code in ask.lua. Dense values and the grid mode of sparse values
-- show `viewer_rows` x `viewer_cols` cells; the list mode of sparse values
-- shows `viewer_rows` nonzero entries. The viewer is not refreshed by itself
-- when the debugger moves; `r` refreshes it.

local config = require("octave_dbg.config")
local ask = require("octave_dbg.ask")

local M = {}

M.ns = vim.api.nvim_create_namespace("octave_dbg_viewer")

-- Milliseconds of quiet after a key before the window is requested, so that
-- holding a key sends one request and not one per repeat.
M.DEBOUNCE_MS = 40

local state = nil -- the open viewer, see M.open

-- Pure helpers (unit-tested) ------------------------------------------------

--- "1000x1000" -> { 1000, 1000 }. For N-D sizes, the first two dimensions.
function M.parse_size(text)
  local dims = {}
  for d in tostring(text or ""):gmatch("%d+") do
    table.insert(dims, tonumber(d))
  end
  return { dims[1] or 0, dims[2] or 0 }
end

--- The number of items the vertical position runs over: rows for a grid,
--- entries for a sparse list, fields for a struct, lines for char.
---@param v table view state: mode, rows, cols, nnz, total
function M.extent(v)
  if v.mode == "list" then
    return v.nnz or 0
  elseif v.mode == "fields" then
    return v.total or 0
  end
  return v.rows or 0
end

local function clamp(x, lo, hi)
  if hi < lo then
    hi = lo
  end
  return math.max(lo, math.min(hi, x))
end

--- The position after a move. Returns the new row and column.
---@param v table view state: mode, row, col, rows, cols, nnz, total
---@param action string "down" "up" "left" "right" "page_down" "page_up"
---                     "first" "last" "first_col" "last_col"
---@param nrows integer window height
---@param ncols integer window width
---@return integer row, integer col
function M.move(v, action, nrows, ncols)
  local row, col = v.row, v.col
  local last_row = math.max(1, M.extent(v) - nrows + 1)
  local last_col = math.max(1, (v.cols or 0) - ncols + 1)
  local horizontal = v.mode == "grid"
  if action == "down" then
    row = row + 1
  elseif action == "up" then
    row = row - 1
  elseif action == "page_down" then
    row = row + nrows
  elseif action == "page_up" then
    row = row - nrows
  elseif action == "first" then
    row = 1
  elseif action == "last" then
    row = last_row
  elseif horizontal and action == "right" then
    col = col + 1
  elseif horizontal and action == "left" then
    col = col - 1
  elseif horizontal and action == "first_col" then
    col = 1
  elseif horizontal and action == "last_col" then
    col = last_col
  end
  return clamp(row, 1, last_row), clamp(col, 1, last_col)
end

--- Parse the answer to "go to": "120 5", "120,5", "120" (keep the column)
--- or ",5" (keep the row). Returns row and col, either may be nil; nil, nil
--- for input that is not understood.
function M.parse_goto(input)
  input = vim.trim(input or "")
  local r, c = input:match("^(%d*)%s*[,%s]%s*(%d*)$")
  if not r then
    r = input:match("^(%d+)$")
    c = ""
  end
  if not r or (r == "" and c == "") then
    return nil, nil
  end
  return tonumber(r), tonumber(c)
end

--- The request fields for a view state: name, mode, row, col, nrows,
--- ncols, cplx. `find` asks for the list page at a row and column.
function M.request_fields(v, nrows, ncols)
  local mode, row, col = v.mode, v.row, v.col
  if v.find then
    mode, row, col = "find", v.find[1], v.find[2]
  elseif mode ~= "list" then
    mode = "grid"
  end
  return { v.name, mode, tostring(row), tostring(col), tostring(nrows), tostring(ncols), v.polar and "polar" or "cart" }
end

--- Switch a sparse view between the nonzero list and the grid. The grid
--- opens at the first listed entry; the list opens at the first entry at or
--- after the top-left cell of the grid.
---@param v table view state
---@param first_entry table|nil { i, j } of the first listed entry
function M.toggle_mode(v, first_entry)
  local n = vim.deepcopy(v)
  if v.kind ~= "sparse" then
    return n
  end
  if v.mode == "list" then
    n.mode = "grid"
    n.row = first_entry and first_entry[1] or 1
    n.col = first_entry and first_entry[2] or 1
  else
    n.mode = "list"
    n.find = { v.row, v.col }
  end
  return n
end

local function pad_left(s, w)
  return string.rep(" ", w - vim.fn.strdisplaywidth(s)) .. s
end

local function pad_right(s, w)
  return s .. string.rep(" ", w - vim.fn.strdisplaywidth(s))
end

local function header_lines(a, v)
  local lines = { ("%s  %s %s  (%s)"):format(a.name, a.size or "?", a.class or "?", ask.scope_text(a)) }
  if a.header and a.header ~= "" then
    table.insert(lines, a.header)
  elseif a.numel then
    table.insert(lines, ("%s elements"):format(a.numel))
  end
  if a.stats and a.stats ~= "" then
    table.insert(lines, a.stats)
  end
  if a.note and a.note ~= "" then
    table.insert(lines, "(" .. a.note .. ")")
  end
  local R, C = v.rows or 0, v.cols or 0
  local where
  if a.mode == "list" then
    local first, count = tonumber(a.first) or 1, tonumber(a.count) or 0
    where = count > 0 and ("nonzeros %d-%d of %d (column-major)"):format(first, first + count - 1, v.nnz or 0)
      or ("no nonzeros at or after this position (%d in total)"):format(v.nnz or 0)
  elseif a.mode == "grid" then
    local r1, c1 = tonumber(a.row) or 1, tonumber(a.col) or 1
    local nr, nc = tonumber(a.nrows) or 0, tonumber(a.ncols) or 0
    where = nr > 0 and ("rows %d-%d of %d, columns %d-%d of %d"):format(r1, r1 + nr - 1, R, c1, c1 + nc - 1, C)
      or "outside the value"
  elseif a.mode == "fields" then
    local r1, count = tonumber(a.row) or 1, tonumber(a.count) or 0
    where = ("fields %d-%d of %s"):format(r1, r1 + count - 1, a.total or "?")
  elseif a.mode == "lines" then
    local r1, count = tonumber(a.row) or 1, tonumber(a.count) or 0
    where = ("rows %d-%d of %d"):format(r1, r1 + count - 1, R)
  end
  if where then
    if v.polar then
      where = where .. "; magnitude and angle"
    end
    table.insert(lines, where)
  end
  return lines
end

local function hint_line(v)
  local keys = { "j/k move" }
  if v.mode == "grid" then
    keys = { "hjkl move" }
  end
  vim.list_extend(keys, { "C-d/C-u page", "gg/G first/last" })
  if v.mode == "grid" then
    table.insert(keys, "0/$ first/last column")
  end
  if v.mode == "grid" or v.mode == "list" then
    table.insert(keys, "g go to")
  end
  if v.kind == "sparse" then
    table.insert(keys, "m " .. (v.mode == "list" and "grid" or "list"))
  end
  if v.complex then
    table.insert(keys, "a " .. (v.polar and "re/im" or "mag/angle"))
  end
  vim.list_extend(keys, { "r refresh", "q close" })
  return table.concat(keys, "  ")
end

--- Lines and highlights for an answer.
---@param a table parsed answer (ask.parse)
---@param v table view state
---@return string[] lines, table[] hl { line, col_start, col_end, group }
function M.render(a, v)
  if a.status == "notvar" then
    return { ("%s: not a variable (%s)"):format(a.name, ask.scope_text(a)) }, {}
  elseif a.status ~= "ok" then
    return { ("%s: %s"):format(a.name, a.message or "error") }, {}
  end
  local lines = header_lines(a, v)
  local hl = { { 0, 0, -1, "Title" } }
  if v.stale then
    table.insert(lines, "(the debugger moved; press r to refresh)")
    table.insert(hl, { #lines - 1, 0, -1, "WarningMsg" })
  end
  table.insert(lines, hint_line(v))
  table.insert(hl, { #lines - 1, 0, -1, "Comment" })
  table.insert(lines, "")

  local rows = {}
  for _, line in ipairs(a.body) do
    if line ~= "" then
      table.insert(rows, vim.split(line, "\t", { plain = true }))
    end
  end

  if a.mode == "grid" then
    local r1, c1 = tonumber(a.row) or 1, tonumber(a.col) or 1
    local ncols = 0
    for _, r in ipairs(rows) do
      ncols = math.max(ncols, #r)
    end
    local gutter = #tostring(r1 + #rows - 1)
    local widths = {}
    for c = 1, ncols do
      widths[c] = #tostring(c1 + c - 1)
      for _, r in ipairs(rows) do
        widths[c] = math.max(widths[c], vim.fn.strdisplaywidth(r[c] or ""))
      end
    end
    local head = { string.rep(" ", gutter) }
    for c = 1, ncols do
      table.insert(head, pad_left(tostring(c1 + c - 1), widths[c]))
    end
    table.insert(lines, table.concat(head, "  "))
    table.insert(hl, { #lines - 1, 0, -1, "LineNr" })
    for k, r in ipairs(rows) do
      local cells = { pad_left(tostring(r1 + k - 1), gutter) }
      for c = 1, ncols do
        table.insert(cells, pad_left(r[c] or "", widths[c]))
      end
      table.insert(lines, table.concat(cells, "  "))
      table.insert(hl, { #lines - 1, 0, gutter, "LineNr" })
    end
  elseif a.mode == "list" then
    local first = tonumber(a.first) or 1
    local wi, wj, wk = 1, 1, #tostring(first + #rows - 1)
    for _, r in ipairs(rows) do
      wi = math.max(wi, #(r[1] or ""))
      wj = math.max(wj, #(r[2] or ""))
    end
    for k, r in ipairs(rows) do
      local pos = pad_left(tostring(first + k - 1), wk)
      table.insert(lines, ("%s  (%s, %s) -> %s"):format(pos, pad_left(r[1] or "", wi), pad_left(r[2] or "", wj), r[3] or ""))
      table.insert(hl, { #lines - 1, 0, wk, "LineNr" })
    end
  elseif a.mode == "fields" then
    local w1, w2 = 1, 1
    for _, r in ipairs(rows) do
      w1 = math.max(w1, vim.fn.strdisplaywidth(r[1] or ""))
      w2 = math.max(w2, vim.fn.strdisplaywidth(r[2] or ""))
    end
    for _, r in ipairs(rows) do
      table.insert(lines, ("%s  %s  %s"):format(pad_right(r[1] or "", w1), pad_right(r[2] or "", w2), r[3] or ""))
    end
  else -- lines (char)
    local r1 = tonumber(a.row) or 1
    local gutter = #tostring(r1 + #a.body)
    local k = 0
    for _, line in ipairs(a.body) do
      table.insert(lines, ("%s  %s"):format(pad_left(tostring(r1 + k), gutter), line))
      table.insert(hl, { #lines - 1, 0, gutter, "LineNr" })
      k = k + 1
    end
  end
  return lines, hl
end

-- The buffer -----------------------------------------------------------------

local function valid()
  return state and state.buf and vim.api.nvim_buf_is_valid(state.buf)
end

local function draw(lines, hl)
  if not valid() then
    return
  end
  local buf = state.buf
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, M.ns, 0, -1)
  for _, h in ipairs(hl or {}) do
    local text = lines[h[1] + 1] or ""
    local stop = h[3] < 0 and #text or math.min(h[3], #text)
    if stop > h[2] then
      vim.api.nvim_buf_set_extmark(buf, M.ns, h[1], h[2], { end_col = stop, hl_group = h[4] })
    end
  end
end

local function window_size()
  local b = state.source_buf
  return config.get("viewer_rows", b), config.get("viewer_cols", b)
end

local function on_answer(answer)
  if not valid() then
    return
  end
  local v = state.view
  v.find = nil
  if answer.status == "ok" then
    local dims = M.parse_size(answer.size)
    v.rows, v.cols = dims[1], dims[2]
    v.kind = answer.kind
    v.nnz = tonumber(answer.nnz)
    v.total = tonumber(answer.total)
    v.complex = (answer.class or ""):find("complex", 1, true) ~= nil
    v.mode = answer.mode or v.mode
    if answer.mode == "list" then
      v.row = tonumber(answer.first) or v.row
      local first = answer.body[1] and vim.split(answer.body[1], "\t", { plain = true })
      v.first_entry = first and first[2] and { tonumber(first[1]), tonumber(first[2]) } or nil
    end
  end
  state.answer = answer
  draw(M.render(answer, v))
end

local function request_now()
  if not valid() then
    return
  end
  local nrows, ncols = window_size()
  ask.request({
    kind = "view",
    channel = "viewer",
    fields = M.request_fields(state.view, nrows, ncols),
    timeout = config.get("viewer_timeout", state.source_buf),
    on_answer = on_answer,
    on_busy = function(timeout)
      if valid() then
        local lines = state.answer and M.render(state.answer, state.view) or {}
        table.insert(lines, 1, ("Octave is busy (no answer within %d ms); press r to try again"):format(timeout))
        draw(lines, { { 0, 0, -1, "WarningMsg" } })
      end
    end,
  })
end

local function request()
  if not valid() then
    return
  end
  state.timer = state.timer or vim.uv.new_timer()
  state.timer:stop()
  state.timer:start(M.DEBOUNCE_MS, 0, vim.schedule_wrap(request_now))
end

local function act(action)
  return function()
    local nrows, ncols = window_size()
    local v = state.view
    v.row, v.col = M.move(v, action, nrows, ncols)
    request()
  end
end

local function goto_prompt()
  local v = state.view
  if v.mode ~= "grid" and v.mode ~= "list" then
    return
  end
  vim.ui.input({ prompt = "Go to row, column: " }, function(input)
    if not valid() or not input then
      return
    end
    local r, c = M.parse_goto(input)
    if not r and not c then
      vim.notify("octave-dbg: expected 'row', 'row col' or ',col'", vim.log.levels.WARN)
      return
    end
    local nrows, ncols = window_size()
    if v.mode == "list" then
      v.find = { r or 1, c or 1 }
    else
      v.row = r or v.row
      v.col = c or v.col
      local row, col = M.move(v, "none", nrows, ncols)
      v.row, v.col = row, col
    end
    request()
  end)
end

local function close()
  if valid() then
    vim.api.nvim_buf_delete(state.buf, { force = true })
  end
end

local function teardown()
  if state and state.timer and not state.timer:is_closing() then
    state.timer:close()
  end
  ask.cancel("viewer")
  state = nil
end

local function set_keys(buf)
  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = buf, nowait = true, desc = "octave-dbg viewer: " .. desc })
  end
  map("j", act("down"), "next row")
  map("k", act("up"), "previous row")
  map("l", act("right"), "next column")
  map("h", act("left"), "previous column")
  map("<C-d>", act("page_down"), "page down")
  map("<C-u>", act("page_up"), "page up")
  map("gg", act("first"), "first row")
  map("G", act("last"), "last row")
  map("0", act("first_col"), "first column")
  map("$", act("last_col"), "last column")
  vim.keymap.set("n", "g", goto_prompt, { buffer = buf, desc = "octave-dbg viewer: go to row and column" })
  map("m", function()
    local v = state.view
    if v.kind == "sparse" then
      state.view = M.toggle_mode(v, v.first_entry)
      request()
    end
  end, "switch list and grid")
  map("a", function()
    if state.view.complex then
      state.view.polar = not state.view.polar
      request()
    end
  end, "switch re/im and magnitude/angle")
  map("r", function()
    state.view.stale = false
    request()
  end, "refresh")
  map("q", close, "close")
end

local function open_window(buf, title)
  local split = config.get("viewer_split", state.source_buf)
  if split == "float" or split == nil then
    local width = math.max(40, math.floor(vim.o.columns * 0.9))
    local height = math.max(10, math.floor((vim.o.lines - vim.o.cmdheight) * 0.8))
    return vim.api.nvim_open_win(buf, true, {
      relative = "editor",
      width = width,
      height = height,
      row = math.floor((vim.o.lines - height) / 2) - 1,
      col = math.floor((vim.o.columns - width) / 2),
      style = "minimal",
      border = config.get("viewer_border", state.source_buf),
      title = " " .. title .. " ",
      title_pos = "center",
    })
  end
  vim.cmd(split)
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  for opt, value in pairs({ number = false, relativenumber = false, signcolumn = "no", wrap = false }) do
    vim.wo[win][opt] = value
  end
  return win
end

--- Open the viewer for a variable or struct field. Without a name, the name
--- under the cursor is used.
---@param name string|nil
function M.open(name)
  local source_buf = vim.api.nvim_get_current_buf()
  if not name then
    name = ask.name_at(vim.api.nvim_get_current_line(), vim.api.nvim_win_get_cursor(0)[2])
    if not name then
      vim.notify("octave-dbg: no name under the cursor", vim.log.levels.INFO)
      return
    end
  end
  if not ask.valid_name(name) then
    vim.notify("octave-dbg: not a variable name: " .. name, vim.log.levels.WARN)
    return
  end
  close()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "octave_dbg_viewer"
  pcall(vim.api.nvim_buf_set_name, buf, "octave-dbg://view/" .. name)
  state = {
    buf = buf,
    source_buf = source_buf,
    -- The first request asks for the list: sparse values start there, and
    -- Octave answers other values with a grid.
    view = { name = name, mode = "list", row = 1, col = 1, polar = false },
  }
  draw({ name .. ": waiting for Octave..." })
  vim.bo[buf].modifiable = false
  state.win = open_window(buf, "octave-dbg: " .. name)
  vim.wo[state.win].wrap = false
  vim.wo[state.win].cursorline = false
  set_keys(buf)
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = teardown })
  request_now()
end

--- The view state of the open viewer (a copy), or nil.
function M.current()
  return state and vim.deepcopy(state.view) or nil
end

function M.setup()
  local group = vim.api.nvim_create_augroup("octave_dbg_viewer", { clear = true })
  vim.api.nvim_create_autocmd("User", {
    group = group,
    pattern = { "OctaveDbgStopped", "OctaveDbgEnded" },
    callback = function()
      -- Not refreshed by itself: only marked, so that the user decides.
      if valid() and state.answer and not state.view.stale then
        state.view.stale = true
        draw(M.render(state.answer, state.view))
      end
    end,
  })
end

return M
