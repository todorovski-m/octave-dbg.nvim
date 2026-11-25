-- The Octave input event hook shared by the variables panel and the hover.
--
-- octave/octave_dbg_hook.m runs while Octave waits at a prompt. It is
-- started with one command per REPL job, on first use. After that, Neovim
-- controls it only through files in one temp folder, so nothing more is
-- echoed in the REPL. See the comment at the top of octave_dbg_hook.m.

local repl = require("octave_dbg.repl")

local M = {}

local helper_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h") .. "/octave"

local state = {
  dir = nil, -- temp folder for this Neovim session
  chan = nil, -- REPL job that runs the hook
}

--- Folder that the hook reads and writes.
function M.dir()
  if not state.dir then
    state.dir = vim.fn.tempname() .. "-hook"
    vim.fn.mkdir(state.dir, "p")
  end
  return state.dir
end

--- Path of a file in the hook folder.
function M.path(name)
  return M.dir() .. "/" .. name
end

--- True when the hook runs in the current REPL job.
function M.running()
  return repl.alive() and state.chan == repl.info().chan
end

--- Start the hook in the current REPL job if it does not run there yet.
--- Does not start the REPL. Returns true when the hook runs.
function M.ensure()
  if not repl.alive() then
    return false
  end
  if M.running() then
    return true
  end
  local sent = repl.send(
    ("addpath(%s); octave_dbg_hook('start', %s);"):format(repl.quote(helper_dir), repl.quote(M.dir())),
    { raw = true }
  )
  if sent then
    state.chan = repl.info().chan
  end
  return sent
end

--- Write a file in the hook folder in one step (write, then rename), so
--- that the hook never reads it half-written.
function M.write(name, lines)
  local target = M.path(name)
  local tmp = target .. ".tmp"
  vim.fn.writefile(lines, tmp)
  vim.uv.fs_rename(tmp, target)
end

--- Read a file written by the hook. Returns its text only when it is
--- complete (its last line is "#end").
function M.read(name)
  local f = io.open(M.path(name), "r")
  if not f then
    return nil
  end
  local text = f:read("*a")
  f:close()
  if not text:match("#end%s*$") then
    return nil
  end
  return text
end

function M.remove(name)
  os.remove(M.path(name))
end

return M
