-- Current-line marker and the variables panel.
local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
E.init("stage2", {})
local od, repl, check = E.od, E.repl, E.check
local marker = require("octave_dbg.marker")
local panel = require("octave_dbg.panel")
local function panel_lines()
  return panel.is_open() and vim.api.nvim_buf_get_lines(vim.fn.bufnr("octave-dbg://variables"), 0, -1, false) or {}
end
local function panel_has(s)
  for _, l in ipairs(panel_lines()) do
    if l:find(s, 1, true) then
      return true
    end
  end
  return false
end
local function wait(fn, ms) return vim.wait(ms or 8000, fn, 50) end

vim.cmd("edit " .. E.file("demo_add.m"))
vim.cmd("OctaveDbg break 3")
vim.cmd("bwipeout") -- demo_add.m is not loaded when the debugger steps into it
vim.cmd("edit " .. E.file("demo_script.m"))
local script_win = vim.api.nvim_get_current_win()
vim.cmd("OctaveDbg break 3")
vim.cmd("OctaveDbg panel")
check("panel opened", panel.is_open())
check("focus stays in source", vim.api.nvim_get_current_win() == script_win)
check("panel shows base workspace", wait(function() return panel_has("Variables: base workspace") end))

vim.cmd("OctaveDbg run")
check("marker at script line 3", wait(function() local c = marker.current(); return c and c.name == "demo_script" and c.line == 3 end))
local marks = vim.api.nvim_buf_get_extmarks(0, marker.ns, 0, -1, {})
check("extmark on row 3", #marks == 1 and marks[1][2] == 2)
check("cursor moved to line 3", vim.api.nvim_win_get_cursor(script_win)[1] == 3)
check("panel shows script scope", wait(function() return panel_has("Variables: demo_script, line 3") end), table.concat(panel_lines(), " | "))
check("panel lists a", panel_has("a "))

vim.cmd("OctaveDbg step")
check("marker at line 4", wait(function() local c = marker.current(); return c and c.line == 4 end))
vim.cmd("OctaveDbg in")
check("marker in demo_add line 3", wait(function() local c = marker.current(); return c and c.name == "demo_add" and c.line == 3 end))
local bufname = vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(script_win))
check("source window followed into demo_add.m", bufname:match("demo_add%.m$") ~= nil, bufname)
check("cursor at line 3 in demo_add", vim.api.nvim_win_get_cursor(script_win)[1] == 3)
check("breakpoint sign redrawn in demo_add", require("octave_dbg.signs").has(vim.api.nvim_win_get_buf(script_win), 3))
check("panel shows function scope with x, y", wait(function() return panel_has("demo_add, line 3") and panel_has("x ") and panel_has("y ") end), table.concat(panel_lines(), " | "))

vim.cmd("OctaveDbg step")
check("panel follows the step to line 4", wait(function() return panel_has("demo_add, line 4") end), table.concat(panel_lines(), " | "))

local mark = E.mark()
vim.cmd("OctaveDbg continue")
check("script finished", E.wait_out("c = 3", mark))
check("marker cleared at normal prompt", wait(function() return marker.current() == nil end))
check("panel back to base", wait(function() return panel_has("Variables: base workspace") and panel_has("d ") end), table.concat(panel_lines(), " | "))

local starts = 0
for _, c in ipairs(repl.info().sent) do
  if c.text:find("octave_dbg_hook('start'", 1, true) then
    starts = starts + 1
  end
end
check("the panel helper was started once", starts == 1, starts)

vim.cmd("OctaveDbg panel")
check("panel closed", not panel.is_open())
E.finish()
