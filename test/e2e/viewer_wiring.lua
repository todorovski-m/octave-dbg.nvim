-- Opening the viewer: from the hover popup, :OctaveDbg view, <leader>oV,
-- the API; the hint line; small values.
local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
E.init("viewer_wiring", { setup_keymap = true })
local od, repl, check, press = E.od, E.repl, E.check, E.press
local function viewer_buf()
  for _, b in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_get_name(b):find("octave-dbg://view/", 1, true) then
      return b
    end
  end
end
local function viewer_has(s)
  local b = viewer_buf()
  return b ~= nil and E.buf_text(b):find(s, 1, true) ~= nil
end
local function wait_viewer(s) return vim.wait(5000, function() return viewer_has(s) end, 20) end

repl.start()
vim.wait(2500)
repl.send("rand('seed', 1); M = reshape(1:1e6, 1000, 1000); S = sprand(10000, 10000, 3e-5); st.M = magic(4); small = [1 2 3];")
vim.wait(1500)
local demo = E.write("wiring_demo.m", { "M", "S", "small", "st" })
vim.cmd("edit " .. demo)
local src = vim.api.nvim_get_current_win()

-- A large value: the hint, enter the popup, <CR>.
vim.api.nvim_win_set_cursor(src, { 1, 0 })
od.hover()
vim.wait(5000, function() return #E.floats() > 0 end, 20)
local pop = E.floats()[1]
check("hover popup of a large value has the viewer hint", pop and E.buf_text(vim.api.nvim_win_get_buf(pop)):find("Enter in this popup: open the viewer", 1, true) ~= nil)
od.hover()
check("second hover enters the popup", vim.api.nvim_get_current_win() == pop)
press("<CR>")
check("<CR> in the popup opens the viewer for M", wait_viewer("of 1000, columns 1-"))
local only_viewer = true
for _, w in ipairs(E.floats()) do
  if vim.api.nvim_win_get_buf(w) ~= viewer_buf() then
    only_viewer = false
  end
end
check("the hover popup is closed", only_viewer)
press("q")
vim.wait(300)

-- A small value: no hint, and <CR> does not open the viewer.
vim.api.nvim_set_current_win(src)
E.close_floats()
vim.api.nvim_win_set_cursor(src, { 3, 0 })
od.hover()
vim.wait(5000, function() return #E.floats() > 0 end, 20)
pop = E.floats()[1]
check("small value: no viewer hint", pop and not E.buf_text(vim.api.nvim_win_get_buf(pop)):find("open the viewer", 1, true))
od.hover()
press("<CR>")
vim.wait(500)
check("small value: <CR> does not open the viewer", viewer_buf() == nil)
vim.api.nvim_set_current_win(src)
E.close_floats()

-- A struct: the hint, even though it is small.
vim.api.nvim_win_set_cursor(src, { 4, 0 })
od.hover()
vim.wait(5000, function() return #E.floats() > 0 end, 20)
pop = E.floats()[1]
check("struct: viewer hint", pop and E.buf_text(vim.api.nvim_win_get_buf(pop)):find("open the viewer", 1, true) ~= nil)
vim.api.nvim_set_current_win(src)
E.close_floats()

vim.cmd("OctaveDbg view S")
check(":OctaveDbg view S", wait_viewer("of 3000 (column-major)"))
press("q")
vim.wait(300)
vim.api.nvim_set_current_win(src)
vim.cmd("OctaveDbg view st.M")
check(":OctaveDbg view st.M (a path)", wait_viewer("st.M  4x4 double"))
press("q")
vim.wait(300)
vim.api.nvim_set_current_win(src)
vim.api.nvim_win_set_cursor(src, { 1, 0 })
press("<leader>oV")
check("<leader>oV on the word M", wait_viewer("of 1000, columns 1-"))
press("q")
vim.wait(300)
vim.api.nvim_set_current_win(src)
od.view("st")
check('require("octave_dbg").view("st")', wait_viewer("fields 1-1 of 1"))
press("q")
vim.wait(300)
check("completion offers view", vim.tbl_contains(od.complete("vi", "OctaveDbg vi"), "view"))
E.finish()
