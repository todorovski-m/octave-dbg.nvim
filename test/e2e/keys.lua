-- MATLAB keys, run to cursor, interrupt, help popup.
local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
E.init("keys", { setup_keymap = true, matlab_keys = true })
local od, repl, check, press = E.od, E.repl, E.check, E.press
local marker = require("octave_dbg.marker")
local dbg = require("octave_dbg.debug")
local function wait_stop(line, ms)
  return vim.wait(ms or 8000, function() local c = marker.current(); return c ~= nil and c.line == line end, 20)
end
local function octave_bp_count()
  return tonumber(E.ask_octave(function(tag)
    return "s__ = dbstatus(); printf('" .. tag .. "%d\\n', numel(s__)); clear s__"
  end))
end

vim.cmd("edit " .. E.file("demo_script.m"))
local win = vim.api.nvim_get_current_win()

local missing = {}
for _, k in ipairs({ "<F5>", "<S-F5>", "<F9>", "<F10>", "<F11>", "<S-F11>", "<F12>", "<C-F10>", "<C-CR>", "<C-c>", "<F1>" }) do
  if next(vim.fn.maparg(k, "n", false, true)) == nil then
    table.insert(missing, k)
  end
end
check("all MATLAB keys mapped in normal mode", #missing == 0, table.concat(missing, " "))
check("F9 also in visual mode", next(vim.fn.maparg("<F9>", "x", false, true)) ~= nil)
check("F5 also in insert mode", next(vim.fn.maparg("<F5>", "i", false, true)) ~= nil)
check("Ctrl+C not mapped in insert mode", next(vim.fn.maparg("<C-c>", "i", false, true)) == nil)
for _, k in ipairs({ "t", "k", "d", "F" }) do
  check("<leader>o" .. k .. " mapped", next(vim.fn.maparg("<leader>o" .. k, "n", false, true)) ~= nil)
end
check("K mapped to Octave help", vim.fn.maparg("K", "n", false, true).desc == "Octave: help for name under cursor")

repl.start()
vim.wait(2500)

vim.api.nvim_win_set_cursor(win, { 3, 0 })
press("<F12>")
vim.wait(800)
check("F12 sets a breakpoint", vim.deep_equal(dbg.list()[1] and dbg.list()[1].lines, { 3 }))
press("<F5>")
check("F5 runs and stops at 3", wait_stop(3))
press("<F10>")
check("F10 steps to 4", wait_stop(4))
local mark = E.mark()
press("<F5>")
check("F5 continues while stopped", E.wait_out("c = 3", mark))
check("marker cleared after continue", vim.wait(3000, function() return marker.current() == nil end, 20))

-- Run right after an edit: the breakpoint that Octave dropped on the save
-- is sent again before the run.
vim.api.nvim_buf_set_lines(0, -1, -1, false, { "% trailing comment added by the test" })
press("<F5>")
check("F5 right after an edit still stops at the breakpoint", wait_stop(3, 10000))
press("<S-F5>")
check("Shift+F5 quits debugging", vim.wait(3000, function() return marker.current() == nil end, 20))
od.clear_breakpoints()
vim.wait(500)

vim.api.nvim_win_set_cursor(win, { 5, 0 })
press("<C-F10>")
check("run to cursor stops at 5", wait_stop(5))
vim.wait(800)
check("temporary breakpoint removed in Octave", octave_bp_count() == 0)
check("no stored breakpoints, no signs", #dbg.list() == 0 and #require("octave_dbg.signs").lines(0) == 0)
press("<F5>")
vim.wait(1500)

vim.api.nvim_win_set_cursor(win, { 7, 0 })
press("<C-F10>")
check("run to cursor on a comment stops at the next code line", wait_stop(8))
vim.wait(800)
check("moved temporary breakpoint removed", octave_bp_count() == 0)
press("<F5>")
vim.wait(1500)

vim.api.nvim_win_set_cursor(win, { 3, 0 })
press("<F12>")
vim.wait(800)
press("<F5>")
check("stopped at breakpoint 3", wait_stop(3))
vim.api.nvim_win_set_cursor(win, { 8, 0 })
press("<C-F10>")
check("run to cursor continues to 8", wait_stop(8))
vim.wait(800)
check("real breakpoint kept, temporary removed", octave_bp_count() == 1 and vim.deep_equal(dbg.list()[1].lines, { 3 }))
press("<S-F5>")
vim.wait(800)
od.clear_breakpoints()
vim.wait(500)

repl.send("pause(30)")
vim.wait(800)
mark = E.mark()
vim.api.nvim_set_current_win(win)
press("<C-c>")
repl.send("printf('ALIVE_AFTER_INTERRUPT\\n')")
check("Ctrl+C stops pause(30)", E.wait_out("ALIVE_AFTER_INTERRUPT", mark, 5000))

vim.api.nvim_buf_set_lines(0, -1, -1, false, { "disp", "nope_xyz_fn" })
local n = vim.api.nvim_buf_line_count(0)
vim.api.nvim_win_set_cursor(win, { n - 1, 0 })
press("<F1>")
vim.wait(4000, function() return #E.floats() > 0 end, 20)
local fl = E.floats()[1]
local text = fl and E.buf_text(vim.api.nvim_win_get_buf(fl)) or ""
check("F1 shows help for disp", text:find("help disp", 1, true) and text:find("Display the value", 1, true), text:sub(1, 60))
press("<F1>")
check("second F1 enters the popup", fl and vim.api.nvim_get_current_win() == fl)
vim.api.nvim_set_current_win(win)
E.close_floats()
vim.api.nvim_win_set_cursor(win, { n, 0 })
press("K")
vim.wait(4000, function() return #E.floats() > 0 end, 20)
fl = E.floats()[1]
text = fl and E.buf_text(vim.api.nvim_win_get_buf(fl)) or ""
check("K on an unknown name explains", text:find("not found", 1, true), text)
local starts = 0
for _, c in ipairs(repl.info().sent) do
  if c.text:find("octave_dbg_hook('start'", 1, true) then
    starts = starts + 1
  end
end
check("help echoed nothing but the one hook start", starts == 1, starts)
vim.cmd("silent! edit!")
E.finish()
