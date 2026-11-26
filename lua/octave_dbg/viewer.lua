-- Large-value viewer: a read-only buffer that shows one window of a value.
--
-- Octave never formats a whole large value: each key press sends a request
-- for one window (see octave_dbg_view.m), through the shared hook and the
-- request code in ask.lua. Dense values and the grid mode of sparse values
-- show `viewer_rows` x `viewer_cols` cells; the list mode of sparse values
-- shows `viewer_rows` nonzero entries (fewer when the window is lower, so
-- that every row that is fetched is also visible). The keys move a cursor
-- over the cells on screen, like in a spreadsheet; only at an edge is the
-- next window requested. The viewer is not refreshed by itself when the
-- debugger moves; `r` refreshes it.

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

--- The window and the cursor after a key, as in a spreadsheet: the cursor
--- moves over the cells on screen, and the window moves only when the
--- cursor is at an edge (or for page, first and last).
---@param v table view state: mode, row, col, rows, cols, nnz, total
---@param cur table cursor { r, c }, relative to the window (1-based)
---@param action string as for M.move
---@param shown table { rows, cols } on screen now
---@param nrows integer window height for the next request
---@param ncols integer window width for the next request
---@return integer row, integer col, table cursor { r, c }
function M.step(v, cur, action, shown, nrows, ncols)
  local row, col, r, c = v.row, v.col, cur.r, cur.c
  local srows, scols = math.max(1, shown.rows or 1), math.max(1, shown.cols or 1)
  local total_rows, total_cols = M.extent(v), v.cols or 0
  local grid = v.mode == "grid"
  if action == "down" then
    if r < srows then
      r = r + 1
    elseif row + srows - 1 < total_rows then
      row = row + 1
    end
  elseif action == "up" then
    if r > 1 then
      r = r - 1
    elseif row > 1 then
      row = row - 1
    end
  elseif grid and action == "right" then
    if c < scols then
      c = c + 1
    elseif col + scols - 1 < total_cols then
      col = col + 1
    end
  elseif grid and action == "left" then
    if c > 1 then
      c = c - 1
    elseif col > 1 then
      col = col - 1
    end
  elseif action == "page_down" or action == "page_up" or action == "first" or action == "last"
    or (grid and (action == "first_col" or action == "last_col")) then
    local new_row, new_col = M.move(v, action, nrows, ncols)
    if action == "first" then
      r = 1
    elseif action == "last" then
      r = math.max(1, math.min(nrows, total_rows - new_row + 1))
    elseif action == "page_down" and new_row == row then
      r = srows -- already at the end: go to the last row
    elseif action == "page_up" and new_row == row then
      r = 1
    elseif action == "first_col" then
      c = 1
    elseif action == "last_col" then
      c = math.max(1, math.min(ncols, total_cols - new_col + 1))
    end
    row, col = new_row, new_col
  end
  return row, col, { r = r, c = c }
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

--- The field name on row `r` of a struct answer (mode "fields"), or nil.
---@param a table parsed answer
---@param r integer 1-based row among the shown fields
function M.field_at(a, r)
  if not a or a.status ~= "ok" or a.mode ~= "fields" then
    return nil
  end
  local k = 0
  for _, line in ipairs(a.body) do
    if line ~= "" then
      k = k + 1
      if k == r then
        local name = line:match("^([^\t]+)")
        return name and name:match("^[%a][%w_]*$") and name or nil
      end
    end
  end
  return nil
end

--- The cell (row and column in the window, 1-based) at a cursor position,
--- for any motion: arrows, a mouse click, `w`, a search. nil on a header
--- line. Between two cells, the cell to the right counts (cells are
--- right-aligned). Outside a grid, the column is 1.
---@param layout table from M.render
---@param line integer 1-based buffer line
---@param col integer 0-based byte column
---@return integer|nil r, integer|nil c
function M.cell_at(layout, line, col)
  if not layout or not layout.data_line or (layout.count or 0) < 1 then
    return nil
  end
  local r = line - layout.data_line + 1
  if r < 1 or r > layout.count then
    return nil
  end
  local pos = layout.pos and layout.pos[r]
  if not pos or #pos == 0 then
    return r, 1
  end
  for c = 1, #pos do
    if col <= pos[c] then
      return r, c
    end
  end
  return r, #pos
end

--- The name of a field of `parent`: "mpc" and "bus" give "mpc.bus".
function M.child_name(parent, field)
  return parent .. "." .. field
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
  if v.mode == "fields" then
    table.insert(keys, "<CR> open field")
  end
  if (v.depth or 0) > 0 then
    table.insert(keys, "<BS> back")
  end
  vim.list_extend(keys, { "r refresh", "q close" })
  return table.concat(keys, "  ")
end

--- Lines, highlights and layout for an answer.
---@param a table parsed answer (ask.parse)
---@param v table view state
---@param cursor table|nil { r, c }: adds a line with the cell under it (grid)
---@return string[] lines, table[] hl { line, col_start, col_end, group },
---        table layout { data_line (1-based), count, cols, pos[row][col] = byte column }
function M.render(a, v, cursor)
  if a.status == "notvar" then
    return { ("%s: not a variable (%s)"):format(a.name, ask.scope_text(a)) }, {}, { data_line = 1, count = 0, cols = 0, pos = {} }
  elseif a.status ~= "ok" then
    return { ("%s: %s"):format(a.name, a.message or "error") }, {}, { data_line = 1, count = 0, cols = 0, pos = {} }
  end
  local lines = header_lines(a, v)
  local hl = { { 0, 0, -1, "Title" } }
  local body_rows = {}
  for _, line in ipairs(a.body) do
    if line ~= "" then
      table.insert(body_rows, vim.split(line, "\t", { plain = true }))
    end
  end
  if cursor and a.mode == "grid" then
    local cell = body_rows[cursor.r] and body_rows[cursor.r][cursor.c]
    if cell then
      table.insert(lines, ("cell (%d, %d): %s"):format((tonumber(a.row) or 1) + cursor.r - 1, (tonumber(a.col) or 1) + cursor.c - 1, cell))
      table.insert(hl, { #lines - 1, 0, -1, "Identifier" })
    end
  end
  if v.stale then
    table.insert(lines, "(the debugger moved; press r to refresh)")
    table.insert(hl, { #lines - 1, 0, -1, "WarningMsg" })
  end
  table.insert(lines, hint_line(v))
  table.insert(hl, { #lines - 1, 0, -1, "Comment" })
  table.insert(lines, "")

  local rows = body_rows
  local layout = { count = 0, cols = 0, pos = {} }

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
    layout.data_line = #lines + 1
    layout.cols = ncols
    for k, r in ipairs(rows) do
      local text = pad_left(tostring(r1 + k - 1), gutter)
      local pos = {}
      for c = 1, ncols do
        text = text .. "  " .. pad_left(r[c] or "", widths[c])
        pos[c] = #text - 1 -- the last byte of the cell
      end
      layout.pos[k] = pos
      table.insert(lines, text)
      table.insert(hl, { #lines - 1, 0, gutter, "LineNr" })
    end
  elseif a.mode == "list" then
    layout.data_line = #lines + 1
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
    layout.data_line = #lines + 1
    local w1, w2 = 1, 1
    for _, r in ipairs(rows) do
      w1 = math.max(w1, vim.fn.strdisplaywidth(r[1] or ""))
      w2 = math.max(w2, vim.fn.strdisplaywidth(r[2] or ""))
    end
    for _, r in ipairs(rows) do
      table.insert(lines, ("%s  %s  %s"):format(pad_right(r[1] or "", w1), pad_right(r[2] or "", w2), r[3] or ""))
    end
  else -- lines (char)
    layout.data_line = #lines + 1
    local r1 = tonumber(a.row) or 1
    local gutter = #tostring(r1 + #a.body)
    local k = 0
    for _, line in ipairs(a.body) do
      table.insert(lines, ("%s  %s"):format(pad_left(tostring(r1 + k), gutter), line))
      table.insert(hl, { #lines - 1, 0, gutter, "LineNr" })
      k = k + 1
    end
  end
  layout.count = #lines - layout.data_line + 1
  return lines, hl, layout
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

-- The window to request: at most viewer_rows x viewer_cols, no more rows
-- than fit below the header and no more columns than fit across, so that
-- every fetched cell is visible.
local function window_size()
  local b = state.source_buf
  local max_rows, max_cols = config.get("viewer_rows", b), config.get("viewer_cols", b)
  local before = state.layout and state.layout.data_line and (state.layout.data_line - 1) or 9
  local height = (state.win and vim.api.nvim_win_is_valid(state.win)) and vim.api.nvim_win_get_height(state.win) or max_rows
  local ncols = math.min(max_cols, state.fit_cols or max_cols)
  return math.max(1, math.min(max_rows, height - before)), math.max(1, ncols)
end

--- How many grid columns of a rendered window fit into `width` display
--- columns, and the display width of one column. Pure; exposed for tests.
---@param line string a rendered data row
---@param pos integer[] byte column of the last byte of each cell
---@param width integer
---@return integer fit, number col_width
function M.fit_columns(line, pos, width)
  local fit, last_end, first_end = 0, 0, nil
  for c = 1, #pos do
    local e = vim.fn.strdisplaywidth(line:sub(1, pos[c] + 1))
    first_end = first_end or e
    if e <= width then
      fit = c
    end
    last_end = e
  end
  local col_width = #pos > 1 and (last_end - first_end) / (#pos - 1) or last_end
  return fit, col_width
end

-- Defined below; redraw asks for a new window when the columns do not fit.
local request
-- Defined below; sets the float title when a field is opened.
local set_title

-- Draw the last answer with the cursor, and put the cursor on its cell.
local function redraw()
  if not (valid() and state.answer) then
    return
  end
  local lines, hl, layout = M.render(state.answer, state.view, state.cursor)
  state.layout = layout
  draw(lines, hl)
  local win = state.win
  if not (win and vim.api.nvim_win_is_valid(win)) then
    return
  end
  -- Too many columns for the float: ask again with as many as fit. Clearly
  -- more room (two spare columns): ask for more, up to viewer_cols.
  if state.answer.mode == "grid" and layout.count > 0 and layout.cols > 0 then
    local width = vim.api.nvim_win_get_width(win)
    local fit, col_width = M.fit_columns(lines[layout.data_line], layout.pos[1], width)
    local _, requested = window_size()
    local more_exist = (state.view.col + layout.cols - 1) < (state.view.cols or 0)
    local last_end = vim.fn.strdisplaywidth(lines[layout.data_line])
    if fit < layout.cols then
      state.fit_cols = math.max(1, fit)
      state.cursor.c = math.min(state.cursor.c, state.fit_cols)
      request()
    elseif more_exist and layout.cols >= requested and col_width > 0 and width - last_end >= 2 * col_width then
      local max_cols = config.get("viewer_cols", state.source_buf)
      local grow = math.floor((width - last_end) / col_width) - 1
      if layout.cols < max_cols and grow > 0 then
        state.fit_cols = math.min(max_cols, layout.cols + grow)
        request()
      end
    end
  end
  -- Rows that do not match the space under the header (the first request
  -- guesses the header height; a note can make it taller): ask again.
  if layout.count > 0 and (state.answer.mode == "grid" or state.answer.mode == "list") and not state.refit_rows then
    local nrows = window_size()
    local first_row = state.view.row
    local more_rows = (first_row + layout.count - 1) < M.extent(state.view)
    if layout.count > nrows or (layout.count < nrows and more_rows) then
      state.refit_rows = true -- once per answer, so that it cannot loop
      request()
    end
  end
  if layout.count and layout.count > 0 then
    local r = math.min(state.cursor.r, layout.count)
    local pos = layout.pos[r]
    local col = pos and pos[math.min(state.cursor.c, #pos)] or 0
    pcall(vim.api.nvim_win_set_cursor, win, { layout.data_line + r - 1, col })
  end
  -- Keep the left edge (and so the header) in view.
  vim.api.nvim_win_call(win, function()
    vim.fn.winrestview({ leftcol = 0 })
  end)
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
  state.refit_rows = false
  if answer.status == "ok" then
    -- Keep the cursor on the cells that came back.
    local count = tonumber(answer.nrows) or tonumber(answer.count) or 0
    local cols = tonumber(answer.ncols) or 1
    state.cursor.r = math.max(1, math.min(state.cursor.r, count))
    state.cursor.c = math.max(1, math.min(state.cursor.c, cols))
  end
  redraw()
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

function request()
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
    local shown = { rows = state.layout and state.layout.count or 1, cols = state.layout and state.layout.cols or 1 }
    local row, col, cursor = M.step(v, state.cursor, action, shown, nrows, ncols)
    state.cursor = cursor
    if row ~= v.row or col ~= v.col then
      v.row, v.col = row, col
      request()
    else
      redraw() -- only the cursor moved
    end
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
      state.cursor = { r = 1, c = 1 }
    else
      local tr = r or (v.row + state.cursor.r - 1)
      local tc = c or (v.col + state.cursor.c - 1)
      v.row, v.col = tr, tc
      local row, col = M.move(v, "none", nrows, ncols)
      v.row, v.col = row, col
      -- The cursor on the target cell; the window was clamped at the edges.
      state.cursor = { r = math.max(1, tr - row + 1), c = math.max(1, tc - col + 1) }
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
  -- The same with arrows and the page keys.
  map("<Down>", act("down"), "next row")
  map("<Up>", act("up"), "previous row")
  map("<Right>", act("right"), "next column")
  map("<Left>", act("left"), "previous column")
  map("<PageDown>", act("page_down"), "page down")
  map("<PageUp>", act("page_up"), "page up")
  map("<Home>", act("first_col"), "first column")
  map("<End>", act("last_col"), "last column")
  vim.keymap.set("n", "g", goto_prompt, { buffer = buf, desc = "octave-dbg viewer: go to row and column" })
  map("m", function()
    local v = state.view
    if v.kind == "sparse" then
      state.view = M.toggle_mode(v, v.first_entry)
      state.cursor = { r = 1, c = 1 }
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
  map("<CR>", function()
    local field = M.field_at(state.answer, state.cursor.r)
    if not field then
      if state.view.mode == "fields" then
        return
      end
      vim.notify("octave-dbg: <CR> opens a field of a struct; cell elements cannot be opened", vim.log.levels.INFO)
      return
    end
    -- Remember where we were, then open the field in the same window.
    table.insert(state.stack, { view = vim.deepcopy(state.view), cursor = vim.deepcopy(state.cursor) })
    local name = M.child_name(state.view.name, field)
    state.view = { name = name, mode = "list", row = 1, col = 1, polar = state.view.polar, depth = #state.stack }
    state.cursor = { r = 1, c = 1 }
    state.fit_cols = nil
    set_title(name)
    request()
  end, "open the field under the cursor")
  local function back()
    local prev = table.remove(state.stack)
    if not prev then
      return
    end
    state.view = prev.view
    state.cursor = prev.cursor
    state.fit_cols = nil
    set_title(state.view.name)
    request()
  end
  map("<BS>", back, "back to the parent struct")
  map("-", back, "back to the parent struct")
end

-- The float title shows the path, such as "octave-dbg: mpc.bus".
function set_title(name)
  local win = state and state.win
  if win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_config(win).relative ~= "" then
    pcall(vim.api.nvim_win_set_config, win, { title = " octave-dbg: " .. name .. " ", title_pos = "center" })
  end
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
    cursor = { r = 1, c = 1 }, -- relative to the window
    stack = {}, -- parents opened with <CR>: { view, cursor }
  }
  draw({ name .. ": waiting for Octave..." })
  vim.bo[buf].modifiable = false
  state.win = open_window(buf, "octave-dbg: " .. name)
  vim.wo[state.win].wrap = false
  vim.wo[state.win].cursorline = true
  -- The window always holds exactly what fits; scrolloff/sidescrolloff
  -- (LazyVim sets 4 and 8) would scroll the header out of view at the edges.
  vim.wo[state.win].scrolloff = 0
  vim.wo[state.win].sidescrolloff = 0
  set_keys(buf)
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true, callback = teardown })
  -- Any other motion (a mouse click, w, a search): take the cell from the
  -- real cursor, so that the cell line and <CR> follow what is on screen.
  vim.api.nvim_create_autocmd("CursorMoved", {
    buffer = buf,
    callback = function()
      if not (valid() and state.layout and state.win and vim.api.nvim_win_is_valid(state.win)) then
        return
      end
      local pos = vim.api.nvim_win_get_cursor(state.win)
      local r, c = M.cell_at(state.layout, pos[1], pos[2])
      if r and (r ~= state.cursor.r or c ~= state.cursor.c) then
        state.cursor = { r = r, c = c }
        redraw()
      end
    end,
  })
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
        redraw()
      end
    end,
  })
end

return M
