-- REPL, run, breakpoints, step, continue, save, cell, restart, status,
-- health and the debug buffer.
local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
E.init("stage1", { setup_keymap = true })
local od, repl, check = E.od, E.repl, E.check

vim.cmd("edit " .. E.file("demo_script.m"))
check("completion", vim.deep_equal(od.complete("s", "OctaveDbg s"), { "send", "status", "step" }))
vim.cmd("OctaveDbg break 3")
check("sign placed", require("octave_dbg.signs").has(0, 3))
check("keymap set", vim.fn.maparg("<leader>ob", "n") ~= "")
vim.cmd("OctaveDbg run")
check("stopped at line 3", E.wait_out("stopped in demo_script at line 3"))
vim.cmd("OctaveDbg step")
check("step to line 4", E.wait_out("stopped in demo_script at line 4"))
vim.cmd("OctaveDbg continue")
check("script finished", E.wait_out("c = 3"))

-- Saving makes Octave drop the breakpoints; the plugin sends them again.
vim.cmd("write")
vim.wait(1600)
check("breakpoint re-sent after save", E.ask_octave(function(tag)
  return "s__ = dbstatus; printf('" .. tag .. "%d\\n', numel(s__)); clear s__"
end) == "1")

vim.api.nvim_win_set_cursor(0, { 8, 0 })
local mark = E.mark()
vim.cmd("OctaveDbg cell")
check("cell sent", E.wait_out("30", mark))

-- Kill Octave: the next command restarts it and sends the breakpoints again.
vim.fn.jobstop(repl.info().chan)
vim.wait(1500, function() return not repl.alive() end)
check("detected death", repl.info().died)
check("restarted, breakpoints restored", E.ask_octave(function(tag)
  return "s__ = dbstatus; printf('" .. tag .. "%d\\n', numel(s__)); clear s__"
end) == "1")
check("restart counted", repl.info().restarts == 1)
local status = table.concat(od.status_lines(), "\n")
check("status lists the breakpoint", status:find("demo_script.m: 3", 1, true) ~= nil, status)

vim.cmd("OctaveDbg clear")
check("signs cleared", not require("octave_dbg.signs").has(0, 3))

vim.cmd("checkhealth octave_dbg")
local health = E.buf_text(0)
check("health check: Octave found", health:find("OK", 1, true) and health:find("version", 1, true), health)
check("health check: REPL alive", health:find("REPL job is alive", 1, true) ~= nil)

od.debug()
local log = E.buf_text(0)
check("debug buffer lists the commands sent", log:find("Commands sent to Octave", 1, true) and log:find("dbstop('demo_script', '3')", 1, true), log:sub(1, 200))

E.finish()
