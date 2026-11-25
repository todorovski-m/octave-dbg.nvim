-- Defines :OctaveDbg. Works without setup(); setup(opts) only changes options.

if vim.g.loaded_octave_dbg then
  return
end
vim.g.loaded_octave_dbg = true

vim.api.nvim_create_user_command("OctaveDbg", function(opts)
  require("octave_dbg").command(opts)
end, {
  nargs = "*",
  range = true,
  desc = "Octave REPL and debugger",
  complete = function(arglead, cmdline)
    return require("octave_dbg").complete(arglead, cmdline)
  end,
})

-- Keep breakpoints, the current-line marker and the variables panel working
-- even when setup() is never called.
require("octave_dbg")._setup_modules()
