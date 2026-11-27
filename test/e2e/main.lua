-- The main script: F5 from a function runs main.m, breakpoints in the
-- function stop, only changed files are saved, <leader>oF, run to cursor.
-- Uses a copy of test/main_demo. main_restart.lua checks, in a fresh
-- Neovim, that the main script is remembered.
local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
E.init("main", { setup_keymap = true, matlab_keys = true, log_size = 5000 })
local od, repl, check, press = E.od, E.repl, E.check, E.press
local marker = require("octave_dbg.marker")
local function mtime(f)
  local st = vim.uv.fs_stat(f)
  return st.mtime.sec .. "." .. st.mtime.nsec
end
local D = E.file("main_demo")
local function stop_in(name, line)
  return vim.wait(10000, function() local c = marker.current(); return c and c.name == name and c.line == line end, 20)
end

local t_main, t_helper = mtime(D .. "/main.m"), mtime(D .. "/lib/helper.m")
vim.cmd("edit " .. D .. "/my_fun.m")
local fun_buf = vim.api.nvim_get_current_buf()
repl.start()
vim.wait(2500)
check("no main script yet", od.get_main() == nil, od.get_main())
local mark = E.mark()
press("<F5>")
check("F5 in a function file calls it with its defaults", E.wait_out("my_fun: x = 5, y = 10", mark) and E.wait_out("ans = 10", mark))

vim.cmd("edit " .. D .. "/main.m")
vim.cmd("OctaveDbg main")
vim.cmd("edit " .. D .. "/my_fun.m")
check(":OctaveDbg main remembers main.m", od.get_main() == D .. "/main.m", od.get_main())
local status = table.concat(od.status_lines(), "\n")
check("status shows the main script", status:find("Main script: ", 1, true) and status:find("main.m", 1, true), status)

vim.api.nvim_win_set_cursor(0, { 6, 0 })
press("<F12>")
vim.wait(800)
vim.api.nvim_buf_set_lines(fun_buf, 1, 2, false, { "  % my_fun -- edited, not saved" })
check("my_fun.m has unsaved changes", vim.bo[fun_buf].modified)
mark = E.mark()
press("<F5>")
check("F5 runs main.m and stops at the breakpoint in my_fun", stop_in("my_fun", 6), vim.inspect(marker.current()))
check("my_fun.m was saved", not vim.bo[fun_buf].modified)
press("<F5>")
check("continue finishes main.m", E.wait_out("main: r = 6, q = 106", mark))
check("main.m was not written (no change)", mtime(D .. "/main.m") == t_main)
check("lib/helper.m was not written (no change)", mtime(D .. "/lib/helper.m") == t_helper)

od.clear_breakpoints()
vim.wait(500)
mark = E.mark()
press("<leader>oF")
check("<leader>oF runs this file (my_fun with defaults)", E.wait_out("my_fun: x = 5, y = 10", mark) and not E.out_has("main: r", mark))

vim.cmd("edit " .. D .. "/lib/helper.m")
vim.api.nvim_win_set_cursor(0, { 2, 0 })
press("<C-F10>")
check("run to cursor in helper.m runs main.m and stops there", stop_in("helper", 2), vim.inspect(marker.current()))
press("<F5>")
vim.wait(1500)
E.finish()
