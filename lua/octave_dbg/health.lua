-- :checkhealth octave_dbg

local config = require("octave_dbg.config")
local repl = require("octave_dbg.repl")

local M = {}

function M.check()
  vim.health.start("octave-dbg")

  if vim.fn.has("nvim-0.10") == 1 then
    vim.health.ok("Neovim " .. tostring(vim.version()))
  else
    vim.health.error("Neovim 0.10 or newer is required")
  end

  local cmd = config.get("cmd")
  local exe = type(cmd) == "table" and cmd[1] or vim.split(cmd, "%s+", { trimempty = true })[1]
  if not exe or vim.fn.executable(exe) == 0 then
    vim.health.error(("'%s' is not executable (option `cmd`)"):format(tostring(exe)))
  else
    vim.health.ok(("'%s' found at %s"):format(exe, vim.fn.exepath(exe)))
    local ok, result = pcall(function()
      return vim.system({ exe, "--version" }, { text = true }):wait(10000)
    end)
    local first = ok and result.code == 0 and (result.stdout or ""):match("[^\n]+")
    if first then
      vim.health.ok(first)
    else
      vim.health.warn("Could not read the Octave version with `" .. exe .. " --version`")
    end
  end

  local info = repl.info()
  if info.alive then
    vim.health.ok("REPL job is alive (job " .. info.chan .. ")")
  elseif info.died then
    vim.health.warn(("REPL job died (%d/%d automatic restarts used)"):format(info.restarts, info.max_restarts))
  else
    vim.health.info("REPL job is not running (start it with :OctaveDbg repl)")
  end
end

return M
