-- Plenary tests for the pure Lua logic. Run with:
--   nvim --headless -u test/minimal_init.lua -c "PlenaryBustedDirectory test { minimal_init = 'test/minimal_init.lua' }"

local od = require("octave_dbg")
local repl = require("octave_dbg.repl")
local dbg = require("octave_dbg.debug")
local signs = require("octave_dbg.signs")
local config = require("octave_dbg.config")

describe("command parsing", function()
  it("splits name and arguments", function()
    local name, rest = od.parse({ "break", "12" })
    assert.equals("break", name)
    assert.same({ "12" }, rest)
  end)

  it("returns nil for no arguments", function()
    assert.is_nil((od.parse({})))
  end)

  it("completes subcommand names by prefix", function()
    assert.same({ "send", "status", "step" }, od.complete("s", "OctaveDbg s"))
    assert.same({ "clc", "clear", "close" }, od.complete("cl", "OctaveDbg cl"))
  end)

  it("does not complete after the first argument", function()
    assert.same({}, od.complete("", "OctaveDbg break "))
  end)
end)

describe("cell bounds", function()
  local lines = { "a = 1;", "%% one", "b = 2;", "c = 3;", "%% two", "d = 4;" }

  it("finds the cell around the cursor", function()
    assert.same({ 3, 4 }, { repl.cell_bounds(lines, 3, "^%%") })
  end)

  it("treats the text before the first delimiter as a cell", function()
    assert.same({ 1, 1 }, { repl.cell_bounds(lines, 1, "^%%") })
  end)

  it("starts after the delimiter when the cursor is on it", function()
    assert.same({ 6, 6 }, { repl.cell_bounds(lines, 5, "^%%") })
  end)
end)

describe("Octave commands", function()
  it("quotes single quotes", function()
    assert.equals("'it''s'", repl.quote("it's"))
  end)

  it("builds dbstop with addpath and the file name", function()
    assert.equals(
      "addpath('/tmp/x'); [~] = dbstop('foo', '3'); [~] = dbstop('foo', '7');",
      dbg.dbstop_cmd("/tmp/x/foo.m", { 3, 7 })
    )
  end)

  it("rejects files Octave cannot address by name", function()
    assert.is_true(dbg.valid_name("/tmp/ok_name1.m"))
    assert.is_false(dbg.valid_name("/tmp/bad-name.m"))
    assert.is_false(dbg.valid_name("/tmp/1abc.m"))
    assert.is_false(dbg.valid_name("/tmp/foo.txt"))
  end)

  it("strips terminal escape codes", function()
    assert.equals("octave:1> x", repl.strip_ansi("\27[?2004hoctave:1> \27[1mx\27[0m\r"))
  end)
end)

describe("signs", function()
  it("tracks lines and follows edits", function()
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "a", "b", "c", "d" })
    signs.place(buf, 2)
    signs.place(buf, 4)
    signs.place(buf, 4)
    assert.same({ 2, 4 }, signs.lines(buf))
    vim.api.nvim_buf_set_lines(buf, 0, 0, false, { "new" })
    assert.same({ 3, 5 }, signs.lines(buf))
    signs.remove(buf, 3)
    assert.same({ 5 }, signs.lines(buf))
    signs.render(buf, { 1, 99 })
    assert.same({ 1 }, signs.lines(buf))
  end)
end)

describe("options", function()
  after_each(function()
    config.set({})
  end)

  it("prefers buffer-local values and calls functions", function()
    config.set({ cell_delimiter = function()
      return "^##"
    end })
    local buf = vim.api.nvim_create_buf(false, true)
    assert.equals("^##", config.get("cell_delimiter", buf))
    vim.b[buf].octave_dbg_cell_delimiter = "^%%%%"
    assert.equals("^%%%%", config.get("cell_delimiter", buf))
  end)
end)

describe("marker parsing", function()
  local marker = require("octave_dbg.marker")
  local normal = { "^octave:%d+>%s*$", "^>>%s*$" }
  local debug_pat = "^debug>%s*$"

  it("parses a stop line", function()
    assert.same(
      { name = "demo_script", line = 3, path = "/a b/demo_script.m" },
      marker.parse_stop("stopped in demo_script at line 3 [/a b/demo_script.m] ")
    )
    assert.is_nil(marker.parse_stop("  --> demo_script at line 3 [/x.m]"))
  end)

  it("tells prompts apart", function()
    assert.equals("debug", marker.prompt_kind("debug> ", normal, debug_pat))
    assert.equals("normal", marker.prompt_kind("octave:12> ", normal, debug_pat))
    assert.equals("normal", marker.prompt_kind(">> ", normal, debug_pat))
    assert.is_nil(marker.prompt_kind("debug> dbst", normal, debug_pat))
  end)

  it("keeps the last stop and clears at the normal prompt", function()
    local s = marker.reduce(nil, {
      "stopped in f at line 2 [/f.m]",
      "2: x = 1;",
      "stopped in f at line 3 [/f.m]",
    }, "debug> ", normal, debug_pat)
    assert.equals("stop", s.kind)
    assert.equals(3, s.stop.line)
    s = marker.reduce(s, { "ans = 3" }, "debug> dbc", normal, debug_pat)
    assert.equals(3, s.stop.line)
    s = marker.reduce(s, { "c = 3" }, "octave:4> ", normal, debug_pat)
    assert.same({ kind = "clear" }, s)
  end)
end)

describe("variables panel", function()
  local panel = require("octave_dbg.panel")

  it("parses the helper file", function()
    local data = panel.parse("#\tdemo_add\t4\nt\t1x1\tdouble\t8\t3\nx\t2x2\tdouble\t32\t[1 2;3 4]\n")
    assert.equals("demo_add", data.scope)
    assert.equals(4, data.line)
    assert.equals(2, #data.vars)
    assert.same({ name = "x", size = "2x2", class = "double", bytes = 32, value = "[1 2;3 4]" }, data.vars[2])
  end)

  it("formats an aligned table", function()
    local lines = panel.format(panel.parse("#\tbase\nab\t1x1\tdouble\t8\t1\nc\t1x5\tchar\t5\t'hello'\n"))
    assert.same({
      "Variables: base workspace",
      "  Name  Size  Class   Bytes  Value",
      "  ab    1x1   double  8      1",
      "  c     1x5   char    5      'hello'",
    }, lines)
  end)

  it("says when there are no variables", function()
    assert.same({ "Variables: base workspace", "  (no variables)" }, panel.format(panel.parse("#\tbase\n")))
  end)
end)

describe("breakpoint sync", function()
  local bpstatus = require("octave_dbg.bpstatus")

  it("parses the dbstatus file", function()
    local id, lines = bpstatus.parse("#\t7\n/tmp/a.m\t8\n/tmp/a.m\t2\n/tmp/a.m\t8\n/tmp/b.m\t3\n#end\n")
    assert.equals(7, id)
    assert.same({ 2, 8 }, lines[vim.fn.resolve("/tmp/a.m")])
    assert.same({ 3 }, lines[vim.fn.resolve("/tmp/b.m")])
  end)

  it("parses an answer without breakpoints", function()
    local id, lines = bpstatus.parse("#\t3\n#end\n")
    assert.equals(3, id)
    assert.same({}, lines)
  end)

  it("ignores a half-written file", function()
    assert.is_nil((bpstatus.parse("#\t4\n/tmp/a.m\t8\n")))
  end)

  it("explains moved and rejected breakpoints", function()
    assert.equals(
      "octave-dbg: s.m: Octave has breakpoints at line 2, 8, not at line 1, 6",
      dbg.sync_message("s.m", { 1, 6 }, { 2, 8 })
    )
    assert.equals("octave-dbg: s.m: Octave did not accept a breakpoint at line 99", dbg.sync_message("s.m", { 99 }, {}))
    assert.is_nil(dbg.sync_message("s.m", { 3 }, { 3 }))
  end)
end)

describe("hover", function()
  local hover = require("octave_dbg.hover")
  local line = "y = s.a.b + x(2) - 1.5e3;"

  it("finds the name under the cursor", function()
    assert.equals("y", hover.name_at(line, 0))
    assert.equals("s", hover.name_at(line, 4))
    assert.equals("s.a", hover.name_at(line, 6))
    assert.equals("s.a.b", hover.name_at(line, 8))
    assert.equals("x", hover.name_at(line, 12))
  end)

  it("finds no name on spaces, operators or numbers", function()
    assert.is_nil(hover.name_at(line, 1))
    assert.is_nil(hover.name_at(line, 13))
    assert.is_nil(hover.name_at(line, 19))
    assert.is_nil(hover.name_at(line, 21))
    assert.is_nil(hover.name_at("", 0))
  end)

  it("parses an answer with a body", function()
    local a = hover.parse("#\t4\nname\ts.a.b\nscope\tdemo_add\t3\nstatus\tok\nclass\tdouble\nsize\t1x3\nnote\t\n#body\n   1   2   3\n\n#end\n")
    assert.equals(4, a.id)
    assert.equals("ok", a.status)
    assert.equals("demo_add", a.scope)
    assert.equals(3, a.line)
    assert.same({ "   1   2   3", "" }, a.body)
    assert.same({ "s.a.b  1x3 double  (demo_add, line 3)", "   1   2   3" }, hover.format(a, 20))
  end)

  it("formats not-a-variable, errors and long output", function()
    assert.same(
      { "rand: not a variable (base workspace)" },
      hover.format(hover.parse("#\t1\nname\trand\nscope\tbase\nstatus\tnotvar\n#end\n"), 20)
    )
    assert.same(
      { "s.nope: s has no field nope" },
      hover.format(hover.parse("#\t2\nname\ts.nope\nscope\tbase\nstatus\terror\nmessage\ts has no field nope\n#end\n"), 20)
    )
    local a = { status = "ok", name = "M", size = "5x1", class = "double", note = "big", body = { "1", "2", "3", "4", "5" } }
    assert.same({ "M  5x1 double  (base workspace)", "(big)", "1", "2", "... 3 more lines" }, hover.format(a, 2))
  end)
end)

describe("MATLAB keys", function()
  it("gives none for false and the defaults for true", function()
    assert.same({}, od.resolve_matlab_keys(false))
    assert.same(od.matlab_key_defaults, od.resolve_matlab_keys(true))
  end)

  it("changes and removes single keys", function()
    local keys = od.resolve_matlab_keys({ step = "<F8>", interrupt = false })
    assert.equals("<F8>", keys.step)
    assert.is_nil(keys.interrupt)
    assert.equals("<F5>", keys.run)
  end)
end)

describe("run to cursor", function()
  it("finds where Octave put the temporary breakpoint", function()
    assert.equals(8, dbg.temp_line({ 3, 8 }, { [3] = true }, 6))
    assert.equals(5, dbg.temp_line({ 5 }, {}, 5))
    -- the line is already a stored breakpoint: nothing new to remove later
    assert.is_false(dbg.temp_line({ 8 }, { [8] = true }, 7))
    assert.is_false(dbg.temp_line({}, {}, 4))
  end)
end)

describe("help popup", function()
  local hover = require("octave_dbg.hover")

  it("formats help text and errors", function()
    local a = hover.parse("#\t9\nname\tdisp\nscope\tbase\nstatus\tok\nclass\t\nsize\t\nnote\t\n#body\n\n -- disp (X)\n   Display X.\n\n#end\n")
    assert.same({ "help disp", " -- disp (X)", "   Display X." }, hover.format_help(a))
    local e = hover.parse("#\t9\nname\tnope\nscope\tbase\nstatus\terror\nmessage\thelp: 'nope' not found\n#end\n")
    assert.same({ "help nope: help: 'nope' not found" }, hover.format_help(e))
  end)
end)
