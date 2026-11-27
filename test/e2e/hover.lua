-- The hover popup: values, safety (nothing is run), busy, debug frame,
-- panel at the same time, restart.
local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
E.init("hover", {})
local od, repl, check = E.od, E.repl, E.check
local panel = require("octave_dbg.panel")

-- Fixtures: a classdef object, an object whose disp fails, and a function
-- that must never run during a hover.
E.write("Pt.m", { "classdef Pt", "  properties", "    x = 1;", "    y = 2;", "  end", "end" })
E.write("Bad.m", { "classdef Bad", "  methods", "    function disp (obj)", "      error ('boom from disp');", "    end", "  end", "end" })
E.write("side_effect.m", { "function side_effect ()", "  fid = fopen ('" .. E.file("side_effect_ran.txt") .. "', 'w'); fclose (fid);", "end" })
local demo = E.write("hover_demo.m", { "s.a.b", "c", "M", "str", "p", "bad", "rand", "side_effect", "nope_var", "s.nope", "t", "x", "sa" })

local src_win
local function hover_line(row, wait_ms)
  E.close_floats()
  vim.api.nvim_set_current_win(src_win)
  local l = vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1]
  vim.api.nvim_win_set_cursor(0, { row, #l - 1 })
  local t = vim.uv.hrtime()
  od.hover()
  vim.wait(wait_ms or 4000, function() return #E.floats() > 0 end, 20)
  local w = E.floats()[1]
  return w and E.buf_text(vim.api.nvim_win_get_buf(w)) or nil, (vim.uv.hrtime() - t) / 1e6
end
local function hook_starts()
  local n = 0
  for _, c in ipairs(repl.info().sent) do
    if c.text:find("octave_dbg_hook('start'", 1, true) then
      n = n + 1
    end
  end
  return n
end

vim.cmd("edit " .. demo)
src_win = vim.api.nvim_get_current_win()
check("no REPL: no popup", hover_line(1, 500) == nil)
repl.start()
vim.wait(2500)
repl.send("addpath('" .. E.dir .. "'); s.a.b = [1 2 3]; c = {1, 'two'}; M = rand(1000); str = 'hello'; p = Pt(); bad = Bad(); sa = struct('a', {1, 2});")
vim.wait(1000)
check("hook not started before first use", hook_starts() == 0)

local txt, ms = hover_line(1)
check("s.a.b value", txt and txt:find("s.a.b  1x3 double  (base workspace)", 1, true) and txt:find("1   2   3", 1, true), txt)
check("hook started once", hook_starts() == 1)
txt = hover_line(2)
check("cell", txt and txt:find("1x2 cell", 1, true) and txt:find("two", 1, true), txt)
txt, ms = hover_line(3)
check("big matrix summarized", txt and txt:find("1000x1000 double", 1, true) and txt:find("min ", 1, true) and txt:find("top-left 5x5", 1, true), txt)
check("big matrix fast", ms < 1000, ("%.0f ms"):format(ms))
txt = hover_line(4)
check("string", txt and txt:find("hello", 1, true), txt)
txt = hover_line(5)
check("classdef object", txt and txt:find("Pt object", 1, true), txt)
txt = hover_line(6)
check("disp error caught", txt and txt:find("boom from disp", 1, true), txt)
txt = hover_line(7)
check("rand: not a variable", txt and txt:find("rand: not a variable", 1, true), txt)
txt = hover_line(8)
check("function name: not a variable", txt and txt:find("not a variable", 1, true), txt)
check("the function was NOT run", vim.fn.filereadable(E.file("side_effect_ran.txt")) == 0)
txt = hover_line(10)
check("missing field", txt and txt:find("s has no field nope", 1, true), txt)
txt = hover_line(13)
check("struct array shown", txt and txt:find("1x2 struct", 1, true), txt)

-- The cursor moves during the wait: no popup.
E.close_floats()
vim.api.nvim_win_set_cursor(0, { 1, 4 })
od.hover()
vim.api.nvim_win_set_cursor(0, { 2, 0 })
vim.wait(600)
check("moved cursor: no popup", #E.floats() == 0)

repl.send("pause(3)")
vim.wait(200)
txt = hover_line(1, 2500)
check("busy message", txt and txt:find("Octave is busy", 1, true), txt)
vim.wait(3500)
txt = hover_line(1)
check("answers again after busy", txt and txt:find("1   2   3", 1, true), txt)

-- The frame where the debugger stopped, with the panel open.
vim.cmd("OctaveDbg panel")
vim.cmd("edit " .. E.file("demo_add.m"))
vim.cmd("OctaveDbg break 4")
vim.wait(800)
repl.send("r = demo_add(5, 6)")
vim.wait(2000)
vim.cmd("edit " .. demo)
src_win = vim.api.nvim_get_current_win()
txt = hover_line(11)
check("t in the demo_add frame", txt and txt:find("t  1x1 double  (demo_add, line 4)", 1, true) and txt:find("11", 1, true), txt)
txt = hover_line(1)
check("s.a.b is not in the function frame", txt and txt:find("not a variable (demo_add", 1, true), txt)
local plines = vim.api.nvim_buf_get_lines(vim.fn.bufnr("octave-dbg://variables"), 0, -1, false)
check("panel shows the demo_add frame", plines[1] and plines[1]:find("demo_add, line 4", 1, true), plines[1])
check("still one hook start", hook_starts() == 1)
repl.send("dbquit")
vim.wait(500)
vim.cmd("OctaveDbg clear")
vim.cmd("OctaveDbg panel")
vim.wait(300)
check("panel closed", not panel.is_open())
vim.cmd("OctaveDbg panel")
vim.wait(1000)
plines = vim.api.nvim_buf_get_lines(vim.fn.bufnr("octave-dbg://variables"), 0, -1, false)
check("panel reopens without a new echo", hook_starts() == 1 and plines[1] and plines[1]:find("base workspace", 1, true), plines[1])
vim.cmd("OctaveDbg panel")

-- After a REPL restart, the hook starts again in the new job.
vim.fn.jobstop(repl.info().chan)
vim.wait(1500, function() return not repl.alive() end)
repl.ensure()
vim.wait(2500)
repl.send("q = 42;")
vim.wait(500)
vim.api.nvim_buf_set_lines(vim.fn.bufnr(demo), 13, 13, false, { "q" })
txt = hover_line(14)
check("hover after REPL restart", txt and txt:find("42", 1, true), txt)
check("hook started again in the new job", hook_starts() == 2)
E.finish()
