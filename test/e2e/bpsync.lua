-- Breakpoint signs kept in sync with Octave's dbstatus.
local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
E.init("bpsync", {})
local repl, check = E.repl, E.check
local signs = require("octave_dbg.signs")
local dbg = require("octave_dbg.debug")
local msgs = {}
local orig_notify = vim.notify
vim.notify = function(m) table.insert(msgs, m) end
local function lines_of(path)
  for _, b in ipairs(dbg.list()) do
    if b.path == path then
      return b.lines
    end
  end
  return {}
end
local function octave_lines(name)
  return E.ask_octave(function(tag)
    return "s__ = dbstatus('" .. name .. "'); printf('" .. tag .. "%s\\n', num2str([s__.line])); clear s__"
  end)
end
local function wait(fn) return vim.wait(5000, fn, 50) end

local script = E.file("demo_script.m")
local tail = E.write("tail_demo.m", { "x = 1;", "y = 2;", "% trailing comment" })
vim.cmd("edit " .. script)
repl.start()
vim.wait(2500)

-- A comment on line 1: Octave puts the breakpoint on line 2.
vim.cmd("OctaveDbg break 1")
check("moved 1 -> 2 (state)", wait(function() return vim.deep_equal(lines_of(script), { 2 }) end), vim.inspect(lines_of(script)))
check("moved 1 -> 2 (signs)", vim.deep_equal(signs.lines(0), { 2 }), vim.inspect(signs.lines(0)))
check("message explains the move", msgs[#msgs] and msgs[#msgs]:find("at line 2, not at line 1", 1, true) ~= nil, msgs[#msgs])

-- The empty line 6 and the %% line 7 both land on line 8.
vim.cmd("OctaveDbg break 6")
vim.cmd("OctaveDbg break 7")
check("6 and 7 -> one breakpoint on 8", wait(function() return vim.deep_equal(lines_of(script), { 2, 8 }) end), vim.inspect(lines_of(script)))
check("signs 2, 8", vim.deep_equal(signs.lines(0), { 2, 8 }), vim.inspect(signs.lines(0)))

-- Two fast toggles on code lines.
vim.cmd("OctaveDbg break 3")
vim.cmd("OctaveDbg break 4")
check("fast toggles keep both", wait(function() return vim.deep_equal(lines_of(script), { 2, 3, 4, 8 }) end), vim.inspect(lines_of(script)))
vim.wait(300)
check("still both after all answers", vim.deep_equal(lines_of(script), { 2, 3, 4, 8 }), vim.inspect(lines_of(script)))
check("Octave agrees", octave_lines("demo_script") == "2  3  4  8", octave_lines("demo_script"))

vim.cmd("OctaveDbg break 8")
check("toggle off 8", wait(function() return vim.deep_equal(lines_of(script), { 2, 3, 4 }) end), vim.inspect(lines_of(script)))
vim.cmd("OctaveDbg clear")
vim.wait(300)

-- A comment after the last code line: Octave places the breakpoint after
-- the end of the file; the plugin removes it and reports it.
vim.cmd("edit " .. tail)
vim.cmd("OctaveDbg break 3")
check("rejected breakpoint removed", wait(function() return #lines_of(tail) == 0 and #signs.lines(0) == 0 end), vim.inspect(lines_of(tail)))
check("message says not accepted", msgs[#msgs] and msgs[#msgs]:find("did not accept a breakpoint at line 3", 1, true) ~= nil, msgs[#msgs])
check("Octave has none left in tail_demo", octave_lines("tail_demo") == "", vim.inspect(octave_lines("tail_demo")))

vim.cmd("OctaveDbg break 99")
check("out-of-range warning", msgs[#msgs] and msgs[#msgs]:find("outside the file", 1, true) ~= nil, msgs[#msgs])

-- The first breakpoint in a modified buffer survives the save.
vim.api.nvim_buf_set_lines(0, 0, 0, false, { "% new first line" })
check("buffer is modified", vim.bo.modified)
vim.cmd("OctaveDbg break 2") -- 'x = 1;' is now line 2
vim.wait(2500)
check("breakpoint survives the save", octave_lines("tail_demo") == "2", octave_lines("tail_demo"))
check("plugin state 2", vim.deep_equal(lines_of(tail), { 2 }), vim.inspect(lines_of(tail)))

-- A REPL restart keeps the synced lines.
vim.fn.jobstop(repl.info().chan)
vim.wait(1500, function() return not repl.alive() end)
repl.ensure()
vim.wait(2500)
check("after restart Octave has line 2", octave_lines("tail_demo") == "2", octave_lines("tail_demo"))

local alone = 0
for _, c in ipairs(repl.info().sent) do
  if c.text:find("octave_dbg_bps", 1, true) and not (c.text:find("dbstop", 1, true) or c.text:find("dbclear", 1, true)) then
    alone = alone + 1
  end
end
check("sync helper never sent on its own line", alone == 0, alone)
vim.notify = orig_notify
E.finish()
