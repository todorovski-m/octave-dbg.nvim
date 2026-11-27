-- The value viewer: dense, sparse, complex, struct, cell, char, errors,
-- busy, stale, and the keys.
local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
E.init("viewer", {})
local repl, check, press = E.repl, E.check, E.press
local viewer = require("octave_dbg.viewer")
local function lines_of() return vim.api.nvim_buf_get_lines(0, 0, -1, false) end
local function has(s)
  for _, l in ipairs(lines_of()) do
    if l:find(s, 1, true) then
      return true
    end
  end
  return false
end
local function wait_has(s, ms) return vim.wait(ms or 5000, function() return has(s) end, 20) end
local function line_with(pat)
  for _, l in ipairs(lines_of()) do
    if l:find(pat) then
      return l
    end
  end
end
local function win_pos()
  local l = line_with("^rows %d+%-%d+ of %d+, columns") or ""
  local r1, r2, _, c1, c2 = l:match("^rows (%d+)%-(%d+) of (%d+), columns (%d+)%-(%d+)")
  return tonumber(r1), tonumber(r2), tonumber(c1), tonumber(c2)
end
local function cell()
  local l = line_with("^cell %(") or ""
  local r, c = l:match("^cell %((%d+), (%d+)%)")
  return tonumber(r), tonumber(c)
end

repl.start()
vim.wait(2500)
repl.send("rand('seed', 1); M = reshape(1:1e6, 1000, 1000); S = sprand(10000, 10000, 3e-5); Zs = sparse([1+1i 0; 0 2-3i]); st.M = magic(4); st.name = 'demo'; ch = ['abc'; 'def']; c = {1, 'two', magic(4); {5, struct('x', [7 8])}, rand(40), 'last'};")
vim.wait(1500)

-- Dense: the window holds as many rows and columns as fit in the float.
viewer.open("M")
check("dense: first window", wait_has("of 1000, columns 1-"))
vim.wait(800)
local r1, r2, c1, c2 = win_pos()
local h, w = r2 - r1 + 1, c2 - c1 + 1
check("dense: window fits the float", h >= 1 and h <= 50 and w >= 1 and w <= 15, ("%d rows x %d cols"):format(h, w))
check("dense: column index header", line_with("^%s+1%s+2%s+3") ~= nil)
check("dense: value 1001 at row 1, column 2", line_with("^%s*1%s+1%s+1001%s") ~= nil, line_with("1001"))
check("dense: cell line at 1, 1", select(1, cell()) == 1 and select(2, cell()) == 1)
press("j")
vim.wait(300)
check("j moves the cursor, not the window", select(1, cell()) == 2 and select(1, win_pos()) == 1)
for _ = 1, h do
  press("j")
end
check("j past the bottom edge moves the window", vim.wait(4000, function() return select(1, win_pos()) == 3 end, 20), line_with("^rows"))
press("<C-d>")
check("C-d pages", vim.wait(4000, function() return select(1, win_pos()) == 3 + h end, 20), line_with("^rows"))
press("G")
check("G goes to the last rows", wait_has(("rows %d-1000 of 1000"):format(1000 - h + 1)) and select(1, cell()) == 1000)
press("j")
vim.wait(300)
check("j at the end stays", select(1, cell()) == 1000)
press("$")
check("$ goes to the last column", vim.wait(4000, function() return select(2, cell()) == 1000 end, 20), line_with("^cell"))
press("gg")
press("0")
check("gg and 0 go back to 1, 1", vim.wait(4000, function() local a, b = cell(); return a == 1 and b == 1 and select(1, win_pos()) == 1 end, 20))
press("<Down>")
press("<Right>")
vim.wait(300)
check("arrows move the cursor too", select(1, cell()) == 2 and select(2, cell()) == 2, line_with("^cell"))

-- Sparse.
viewer.open("S")
check("sparse: header like Octave", wait_has("Compressed Column Sparse (rows = 10000, cols = 10000, nnz = 3000 [0.003%])"))
check("sparse: list mode by default", line_with("^nonzeros 1%-%d+ of 3000 %(column%-major%)") ~= nil, line_with("^nonzeros"))
check("sparse: entries as (i, j) -> value", line_with("^%s*1%s+%(") ~= nil)
press("G")
check("sparse: G to the last page", vim.wait(4000, function() return line_with("^nonzeros %d+%-3000 of 3000") ~= nil end, 20))
press("gg")
vim.wait(300)
press("m")
check("m switches to the grid at the first entry", vim.wait(4000, function() return line_with("^rows 9037%-") ~= nil and line_with("columns 13%-") ~= nil end, 20), line_with("^rows"))
check("grid shows zeros as dots", has(" . "))
press("m")
check("m switches back to the list", vim.wait(4000, function() return line_with("^nonzeros 1%-") ~= nil end, 20))
vim.ui.input = function(_, cb) cb("5000 100") end
press("g")
vim.wait(1200)
check("g in the list finds the entry at row 5000, column 100", vim.wait(4000, function() return line_with("^nonzeros 28%-") ~= nil end, 20), line_with("^nonzeros"))
press("m")
vim.wait(800)
vim.ui.input = function(_, cb) cb("120, 7") end
press("g")
check("g in the grid moves the window and the cursor", vim.wait(4000, function() return line_with("^rows 120%-") ~= nil and line_with("^cell %(120, 7%)") ~= nil end, 20), line_with("^rows"))

-- Complex.
viewer.open("Zs")
check("complex: re/im", wait_has("1 + 1i"))
press("a")
check("a switches to magnitude and angle", wait_has("∠"), line_with("∠"))
check("polar mentioned in the position line", has("magnitude and angle"))

-- Struct fields and cell elements, down and back up.
viewer.open("st")
check("struct fields", wait_has("fields 1-2 of 2") and has("'demo'"))
press("<CR>")
check("<CR> opens the field st.M", wait_has("rows 1-4 of 4, columns 1-4 of 4") and has("st.M  4x4 double"))
press("<BS>")
check("<BS> goes back to st", wait_has("fields 1-2 of 2"))
viewer.open("c")
check("cell window", wait_has("rows 1-2 of 2, columns 1-3 of 3"))
press("j")
press("<CR>")
check("<CR> opens the element c{2,1}", wait_has("c{2,1}  1x2 cell"))
press("l")
press("<CR>")
check("<CR> opens c{2,1}{1,2}, a struct", wait_has("c{2,1}{1,2}  1x1 struct"))
press("<CR>")
check("<CR> opens c{2,1}{1,2}.x", wait_has("c{2,1}{1,2}.x  1x2 double"))
press("<BS>")
press("<BS>")
press("<BS>")
check("<BS> three times goes back to c", vim.wait(5000, function() return has("c  2x3 cell") end, 20))
local warned
local orig_notify = vim.notify
vim.notify = function(m) warned = m end
viewer.open("c{end}")
vim.notify = orig_notify
check("c{end} is refused before anything is sent", warned and warned:find("not a variable name or path", 1, true) ~= nil, warned)
viewer.open("ch")
check("char lines", wait_has("rows 1-2 of 2") and has("def"))
viewer.open("nope_xyz")
check("unknown name", wait_has("nope_xyz: not a variable"))
viewer.open("st.nope")
check("missing field", wait_has("st has no field nope"))

-- Busy, then stale after a stop.
viewer.open("M")
wait_has("of 1000, columns 1-")
repl.send("pause(4)")
vim.wait(300)
press("<C-d>")
check("busy message while Octave runs", wait_has("Octave is busy", 5000))
vim.wait(4000)
press("r")
check("r refreshes after Octave is free", vim.wait(5000, function() return has("of 1000, columns") and not has("Octave is busy") end, 20))
vim.api.nvim_exec_autocmds("User", { pattern = "OctaveDbgStopped", data = { name = "x", line = 1, path = "/x.m" } })
check("stop marks the viewer as stale, without a refresh", has("(the debugger moved; press r to refresh)"))
press("r")
check("r clears the stale note", vim.wait(4000, function() return not has("the debugger moved") end, 20))

local echoed = 0
for _, cmd in ipairs(repl.info().sent) do
  if cmd.text:find("view") then
    echoed = echoed + 1
  end
end
check("no viewer command was echoed in the REPL", echoed == 0, echoed)
press("q")
check("q closes the viewer", vim.wait(1000, function() return vim.fn.bufnr("octave-dbg://view/") == -1 end, 20))
E.finish()
