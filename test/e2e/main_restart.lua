-- Second phase of main.lua, in a fresh Neovim with the same work folder
-- and data folder: the main script is still known, also from lib/, and
-- :OctaveDbg main clear forgets it.
local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
E.init("main", {}, true)
local od, check = E.od, E.check
E.name = "main_restart"
local D = E.file("main_demo")

vim.cmd("edit " .. D .. "/lib/helper.m")
check("after a restart, main.m is still the main script (found from lib/)", od.get_main() == D .. "/main.m", od.get_main())
local f = io.open(vim.fn.stdpath("data") .. "/octave-dbg/main.json")
local json = f and f:read("*a") or ""
if f then
  f:close()
end
check("stored in the data folder", json:find("main.m", 1, true) ~= nil, vim.fn.stdpath("data"))
vim.cmd("OctaveDbg main clear")
check(":OctaveDbg main clear forgets it", od.get_main() == nil, od.get_main())
E.finish()
