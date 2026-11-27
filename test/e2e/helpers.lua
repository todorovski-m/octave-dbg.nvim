-- Shared code for the end-to-end tests: they drive Neovim and a real Octave.
-- Start them with test/e2e/run.sh, which gives each run a temporary folder
-- (OCTAVE_DBG_E2E_TMP) and its own XDG_DATA_HOME, so that neither the
-- repository nor the user's Neovim data is changed.
--
--   local E = dofile(vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":h") .. "/helpers.lua")
--   E.init("suite_name", { setup_keymap = true })
--   E.check("what is checked", condition, "detail shown on failure")
--   E.finish()

local E = {}

E.root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h:h")
E.passed, E.failed = 0, 0

local function out(line)
  io.stdout:write(line .. "\n")
end

local function copy(from, to)
  vim.fn.mkdir(vim.fn.fnamemodify(to, ":h"), "p")
  vim.fn.writefile(vim.fn.readfile(from, "b"), to, "b")
end

--- Load the plugin, call setup(opts) and prepare the work folder of a suite:
--- copies of test/demo_script.m, test/demo_add.m and test/main_demo/. With
--- `keep = true`, an existing work folder is used as it is (for a second
--- phase of a suite).
function E.init(name, opts, keep)
  vim.opt.rtp:prepend(E.root)
  vim.cmd("runtime plugin/octave_dbg.lua")
  E.od = require("octave_dbg")
  E.od.setup(opts or {})
  E.repl = require("octave_dbg.repl")
  E.name = name
  local tmp = vim.env.OCTAVE_DBG_E2E_TMP or vim.fn.tempname()
  E.dir = vim.fn.resolve(tmp) .. "/" .. name
  if not (keep and vim.fn.isdirectory(E.dir) == 1) then
    vim.fn.delete(E.dir, "rf")
    vim.fn.mkdir(E.dir, "p")
    for _, f in ipairs({ "demo_script.m", "demo_add.m" }) do
      copy(E.root .. "/test/" .. f, E.dir .. "/" .. f)
    end
    for _, f in ipairs({ "main.m", "my_fun.m", "lib/helper.m" }) do
      copy(E.root .. "/test/main_demo/" .. f, E.dir .. "/main_demo/" .. f)
    end
  end
  vim.cmd("cd " .. vim.fn.fnameescape(E.dir))
  return E
end

--- Path of a file in the work folder.
function E.file(rel)
  return E.dir .. "/" .. rel
end

--- Write a file in the work folder.
function E.write(rel, lines)
  vim.fn.mkdir(vim.fn.fnamemodify(E.file(rel), ":h"), "p")
  vim.fn.writefile(lines, E.file(rel))
  return E.file(rel)
end

function E.check(name, ok, extra)
  if ok then
    E.passed = E.passed + 1
    out("PASS " .. name)
  else
    E.failed = E.failed + 1
    out("FAIL " .. name .. (extra ~= nil and ("  -- " .. tostring(extra)) or ""))
  end
end

--- Press keys through Neovim's key handling, so that mappings are used.
function E.press(keys)
  vim.api.nvim_feedkeys(vim.keycode(keys), "mx", false)
end

function E.floats()
  local t = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_config(w).relative ~= "" then
      table.insert(t, w)
    end
  end
  return t
end

function E.close_floats()
  for _, w in ipairs(E.floats()) do
    pcall(vim.api.nvim_win_close, w, true)
  end
end

--- Text of a buffer.
function E.buf_text(b)
  return table.concat(vim.api.nvim_buf_get_lines(b, 0, -1, false), "\n")
end

--- True when a REPL output line from position `from` on contains `s` (the
--- echo of a printf command does not count).
function E.out_has(s, from)
  local o = E.repl.info().output
  for i = math.max(1, from or 1), #o do
    if o[i] and o[i]:find(s, 1, true) and not o[i]:find("printf", 1, true) then
      return true
    end
  end
  return false
end

function E.wait_out(s, from, ms)
  return vim.wait(ms or 8000, function()
    return E.out_has(s, from)
  end, 20)
end

--- The current end of the REPL output, for E.out_has(s, mark).
function E.mark()
  return #E.repl.info().output
end

--- Ask Octave something and wait for one line "TAG<value>" of the answer.
local qn = 0
function E.ask_octave(code_that_prints_tag_value)
  qn = qn + 1
  local tag = "E2EQ" .. qn .. "="
  E.repl.send(code_that_prints_tag_value(tag))
  local got
  vim.wait(5000, function()
    for _, l in ipairs(E.repl.info().output) do
      local v = l:match("^" .. tag .. "(.*)$")
      if v then
        got = v
      end
    end
    return got ~= nil
  end, 20)
  return got
end

--- Stop Octave (asking it to exit) and check that it is gone; then print
--- the summary and quit with a non-zero exit code when a check failed.
function E.finish()
  local chan = E.repl.info().chan
  if chan then
    E.repl.stop()
    E.check("Octave exited after stop", vim.fn.jobwait({ chan }, 5000)[1] ~= -1)
  end
  out(("RESULT %s: %d passed, %d failed"):format(E.name, E.passed, E.failed))
  if E.failed > 0 then
    vim.cmd("cquit 1")
  else
    vim.cmd("qall!")
  end
end

return E
