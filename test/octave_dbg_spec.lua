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

describe("viewer", function()
  local viewer = require("octave_dbg.viewer")
  local ask = require("octave_dbg.ask")

  it("parses sizes", function()
    assert.same({ 1000, 1000 }, viewer.parse_size("1000x1000"))
    assert.same({ 3, 4 }, viewer.parse_size("3x4x2"))
    assert.same({ 0, 0 }, viewer.parse_size(nil))
  end)

  it("moves and clamps a grid window", function()
    local v = { mode = "grid", row = 1, col = 1, rows = 1000, cols = 1000 }
    assert.same({ 2, 1 }, { viewer.move(v, "down", 50, 15) })
    assert.same({ 1, 1 }, { viewer.move(v, "up", 50, 15) })
    assert.same({ 1, 2 }, { viewer.move(v, "right", 50, 15) })
    assert.same({ 51, 1 }, { viewer.move(v, "page_down", 50, 15) })
    assert.same({ 951, 1 }, { viewer.move(v, "last", 50, 15) })
    assert.same({ 1, 986 }, { viewer.move(v, "last_col", 50, 15) })
    v.row, v.col = 940, 990
    assert.same({ 951, 986 }, { viewer.move(v, "page_down", 50, 15) })
    assert.same({ 890, 986 }, { viewer.move(v, "page_up", 50, 15) })
    assert.same({ 1, 986 }, { viewer.move(v, "first", 50, 15) })
  end)

  it("keeps a window that is larger than the value at 1, 1", function()
    local v = { mode = "grid", row = 1, col = 1, rows = 4, cols = 4 }
    assert.same({ 1, 1 }, { viewer.move(v, "down", 50, 15) })
    assert.same({ 1, 1 }, { viewer.move(v, "last", 50, 15) })
  end)

  it("pages a sparse list by entries, without columns", function()
    local v = { mode = "list", row = 1, col = 1, rows = 10000, cols = 10000, nnz = 3000 }
    assert.same({ 51, 1 }, { viewer.move(v, "page_down", 50, 15) })
    assert.same({ 2951, 1 }, { viewer.move(v, "last", 50, 15) })
    assert.same({ 1, 1 }, { viewer.move(v, "right", 50, 15) })
  end)

  it("parses go to input", function()
    assert.same({ 120, 5 }, { viewer.parse_goto("120 5") })
    assert.same({ 120, 5 }, { viewer.parse_goto(" 120, 5 ") })
    assert.same({ 120 }, { viewer.parse_goto("120") })
    assert.same({ nil, 5 }, { viewer.parse_goto(",5") })
    assert.same({}, { viewer.parse_goto("x") })
    assert.same({}, { viewer.parse_goto("") })
  end)

  it("builds request fields", function()
    local v = { name = "S", mode = "list", row = 51, col = 1, polar = false }
    assert.same({ "S", "list", "51", "1", "50", "15", "cart" }, viewer.request_fields(v, 50, 15))
    v.find, v.polar = { 5000, 100 }, true
    assert.same({ "S", "find", "5000", "100", "50", "15", "polar" }, viewer.request_fields(v, 50, 15))
    assert.same("grid", viewer.request_fields({ name = "st", mode = "fields", row = 1, col = 1 }, 50, 15)[2])
  end)

  it("switches a sparse view between list and grid", function()
    local v = { kind = "sparse", mode = "list", row = 7, col = 1 }
    local g = viewer.toggle_mode(v, { 9037, 13 })
    assert.same({ "grid", 9037, 13 }, { g.mode, g.row, g.col })
    local l = viewer.toggle_mode(g)
    assert.same({ "list", { 9037, 13 } }, { l.mode, l.find })
    local d = viewer.toggle_mode({ kind = "dense", mode = "grid", row = 1, col = 1 })
    assert.equals("grid", d.mode)
  end)

  local function answer(text)
    return ask.parse(text)
  end

  it("renders a grid with indices and aligned cells", function()
    local a = answer("#\t1\nname\tM\nscope\tbase\nstatus\tok\nclass\tdouble\nsize\t1000x1000\nnumel\t1000000\nkind\tdense\nstats\tmin 0   max 42   mean 0.5\nmode\tgrid\nrow\t9\ncol\t1\nnrows\t2\nncols\t3\n#body\n42\t0.5\t-1.5e-07\n7\t100\t0\n#end\n")
    local v = { name = "M", mode = "grid", rows = 1000, cols = 1000, kind = "dense" }
    local lines = viewer.render(a, v)
    assert.equals("M  1000x1000 double  (base workspace)", lines[1])
    assert.equals("rows 9-10 of 1000, columns 1-3 of 1000", lines[4])
    local n = #lines
    assert.equals("     1    2         3", lines[n - 2])
    assert.equals(" 9  42  0.5  -1.5e-07", lines[n - 1])
    assert.equals("10   7  100         0", lines[n])
  end)

  it("renders a sparse list with positions", function()
    local a = answer("#\t2\nname\tS\nscope\tbase\nstatus\tok\nclass\tdouble sparse\nsize\t10000x10000\nnumel\t100000000\nkind\tsparse\nnnz\t3000\nheader\tCompressed Column Sparse (rows = 10000, cols = 10000, nnz = 3000 [0.003%])\nstats\tmin 0   max 1   mean 1e-05\nmode\tlist\nfirst\t9\ncount\t2\n#body\n9037\t13\t0.81008\n12\t14\t0.134\n#end\n")
    local v = { name = "S", mode = "list", rows = 10000, cols = 10000, nnz = 3000, kind = "sparse" }
    local lines = viewer.render(a, v)
    assert.equals("Compressed Column Sparse (rows = 10000, cols = 10000, nnz = 3000 [0.003%])", lines[2])
    assert.equals("nonzeros 9-10 of 3000 (column-major)", lines[4])
    assert.equals(" 9  (9037, 13) -> 0.81008", lines[#lines - 1])
    assert.equals("10  (  12, 14) -> 0.134", lines[#lines])
    assert.truthy(lines[5]:find("m grid", 1, true))
  end)

  it("renders struct fields, errors and the stale note", function()
    local a = answer("#\t3\nname\tst\nscope\tdemo_add\t4\nstatus\tok\nclass\tstruct\nsize\t1x1\nnumel\t1\nkind\tstruct\nmode\tfields\nrow\t1\ncount\t2\ntotal\t2\n#body\nM\t4x4 double\t[4x4 double]\nname\t1x4 char\t'demo'\n#end\n")
    local v = { name = "st", mode = "fields", kind = "struct", total = 2, stale = true }
    local lines = viewer.render(a, v)
    assert.equals("st  1x1 struct  (demo_add, line 4)", lines[1])
    assert.equals("fields 1-2 of 2", lines[3])
    assert.equals("(the debugger moved; press r to refresh)", lines[4])
    assert.equals("M     4x4 double  [4x4 double]", lines[#lines - 1])
    assert.equals("name  1x4 char    'demo'", lines[#lines])
    local e = viewer.render(answer("#\t4\nname\tst.nope\nscope\tbase\nstatus\terror\nmessage\tst has no field nope\n#end\n"), {})
    assert.same({ "st.nope: st has no field nope" }, e)
  end)
end)

describe("viewer cursor", function()
  local viewer = require("octave_dbg.viewer")
  local ask = require("octave_dbg.ask")
  -- rand(50) in a float that shows 26 rows and 15 columns
  local function v50(row, col)
    return { mode = "grid", row = row, col = col, rows = 50, cols = 50 }
  end
  local shown = { rows = 26, cols = 15 }

  local function step(v, r, c, action)
    local row, col, cur = viewer.step(v, { r = r, c = c }, action, shown, 26, 15)
    return { row, col, cur.r, cur.c }
  end

  it("moves the cursor inside the window without a new window", function()
    assert.same({ 1, 1, 2, 1 }, step(v50(1, 1), 1, 1, "down"))
    assert.same({ 1, 1, 1, 2 }, step(v50(1, 1), 1, 1, "right"))
    assert.same({ 1, 1, 1, 1 }, step(v50(1, 1), 1, 1, "up"))
  end)

  it("moves the window at an edge", function()
    assert.same({ 2, 1, 26, 1 }, step(v50(1, 1), 26, 1, "down"))
    assert.same({ 1, 2, 1, 15 }, step(v50(1, 1), 1, 15, "right"))
    assert.same({ 24, 1, 1, 1 }, step(v50(25, 1), 1, 1, "up"))
  end)

  it("stops at the last row and column of the value", function()
    assert.same({ 25, 1, 26, 1 }, step(v50(25, 1), 26, 1, "down"))
    assert.same({ 1, 36, 1, 15 }, step(v50(1, 36), 1, 15, "right"))
  end)

  it("pages, and goes to the first and last rows and columns", function()
    assert.same({ 25, 1, 26, 1 }, step(v50(1, 1), 3, 1, "last"))
    assert.same({ 1, 1, 1, 1 }, step(v50(25, 1), 9, 1, "first"))
    assert.same({ 25, 1, 3, 1 }, step(v50(1, 1), 3, 1, "page_down"))
    assert.same({ 25, 1, 26, 1 }, step(v50(25, 1), 3, 1, "page_down"))
    assert.same({ 1, 1, 1, 1 }, step(v50(1, 1), 3, 1, "page_up"))
    assert.same({ 1, 36, 1, 15 }, step(v50(1, 1), 1, 4, "last_col"))
    assert.same({ 1, 1, 1, 1 }, step(v50(1, 36), 1, 9, "first_col"))
  end)

  it("moves only the cursor in a value that fits", function()
    local v = { mode = "grid", row = 1, col = 1, rows = 4, cols = 4 }
    local s4 = { rows = 4, cols = 4 }
    local row, col, cur = viewer.step(v, { r = 3, c = 1 }, "down", s4, 26, 15)
    assert.same({ 1, 1, 4, 1 }, { row, col, cur.r, cur.c })
    row, col, cur = viewer.step(v, { r = 4, c = 1 }, "down", s4, 26, 15)
    assert.same({ 1, 1, 4, 1 }, { row, col, cur.r, cur.c })
    row, col, cur = viewer.step(v, { r = 1, c = 1 }, "last", s4, 26, 15)
    assert.same({ 1, 1, 4, 1 }, { row, col, cur.r, cur.c })
  end)

  it("moves over list entries, not columns", function()
    local v = { mode = "list", row = 1, col = 1, nnz = 3000 }
    local row, col, cur = viewer.step(v, { r = 1, c = 1 }, "down", { rows = 26, cols = 1 }, 26, 15)
    assert.same({ 1, 1, 2, 1 }, { row, col, cur.r, cur.c })
    row, col, cur = viewer.step(v, { r = 1, c = 1 }, "right", { rows = 26, cols = 1 }, 26, 15)
    assert.same({ 1, 1, 1, 1 }, { row, col, cur.r, cur.c })
  end)

  it("shows the cell under the cursor and where each cell is", function()
    local a = ask.parse("#\t1\nname\tM\nscope\tbase\nstatus\tok\nclass\tdouble\nsize\t50x50\nnumel\t2500\nkind\tdense\nmode\tgrid\nrow\t9\ncol\t1\nnrows\t2\nncols\t3\n#body\n42\t0.5\t-1.5e-07\n7\t100\t0\n#end\n")
    local lines, _, layout = viewer.render(a, { name = "M", mode = "grid", rows = 50, cols = 50, kind = "dense" }, { r = 2, c = 3 })
    assert.truthy(vim.tbl_contains(lines, "cell (10, 3): 0"))
    assert.equals(2, layout.count)
    assert.equals(3, layout.cols)
    assert.equals("10   7  100         0", lines[layout.data_line + 1])
    -- the cursor goes on the last character of the cell
    assert.equals("0", lines[layout.data_line + 1]:sub(layout.pos[2][3] + 1, layout.pos[2][3] + 1))
    assert.equals("7", lines[layout.data_line + 1]:sub(layout.pos[2][1] + 1, layout.pos[2][1] + 1))
  end)
end)

describe("viewer column fit", function()
  local viewer = require("octave_dbg.viewer")
  it("counts the columns that fit across the window", function()
    local line = " 1  0.99766  0.61905  0.29818"
    local pos = { 10, 19, 28 }
    assert.same({ 3, 9 }, { viewer.fit_columns(line, pos, 40) })
    assert.same({ 2, 9 }, { viewer.fit_columns(line, pos, 25) })
    assert.same({ 0, 9 }, { viewer.fit_columns(line, pos, 5) })
  end)
  it("measures display width, not bytes", function()
    local line = " 1  1 ∠ 90°  1 ∠ 180°"
    local p1 = #" 1  1 ∠ 90°" - 1
    local p2 = #line - 1
    local fit = viewer.fit_columns(line, { p1, p2 }, 12)
    assert.equals(1, fit)
  end)
end)

describe("viewer fields", function()
  local viewer = require("octave_dbg.viewer")
  local ask = require("octave_dbg.ask")
  local a = ask.parse("#\t1\nname\tmpc\nscope\tbase\nstatus\tok\nclass\tstruct\nsize\t1x1\nnumel\t1\nkind\tstruct\nmode\tfields\nrow\t1\ncount\t3\ntotal\t6\n#body\nversion\t1x1 char\t'2'\nbaseMVA\t1x1 double\t100\nbus\t30x13 double\t[30x13 double]\n#end\n")

  it("finds the field under the cursor", function()
    assert.equals("version", viewer.field_at(a, 1))
    assert.equals("bus", viewer.field_at(a, 3))
    assert.is_nil(viewer.field_at(a, 4))
    assert.is_nil(viewer.field_at({ status = "ok", mode = "grid", body = { "1\t2" } }, 1))
  end)

  it("builds the path of a field", function()
    assert.equals("mpc.bus", viewer.child_name("mpc", "bus"))
    assert.equals("a.b.c", viewer.child_name("a.b", "c"))
  end)

  it("offers <CR> on fields and <BS> when there is a parent", function()
    local lines = viewer.render(a, { name = "mpc", mode = "fields", kind = "struct", total = 6, depth = 0 })
    local hint = table.concat(lines, "\n")
    assert.truthy(hint:find("<CR> open field", 1, true))
    assert.falsy(hint:find("<BS> back", 1, true))
    local g = ask.parse("#\t2\nname\tmpc.bus\nscope\tbase\nstatus\tok\nclass\tdouble\nsize\t30x13\nnumel\t390\nkind\tdense\nmode\tgrid\nrow\t1\ncol\t1\nnrows\t1\nncols\t2\n#body\n1\t3\n#end\n")
    local glines = table.concat(viewer.render(g, { name = "mpc.bus", mode = "grid", rows = 30, cols = 13, kind = "dense", depth = 1 }), "\n")
    assert.truthy(glines:find("<BS> back", 1, true))
    assert.falsy(glines:find("<CR> open field", 1, true))
    assert.truthy(glines:find("mpc.bus  30x13 double", 1, true))
  end)
end)

describe("viewer cell from the cursor", function()
  local viewer = require("octave_dbg.viewer")
  -- " 9  42  0.5  -1.5e-07" / "10   7  100         0": cells end at bytes 5, 10, 20
  local layout = { data_line = 7, count = 2, cols = 3, pos = { { 5, 10, 20 }, { 5, 10, 20 } } }

  it("finds the cell under the cursor", function()
    assert.same({ 1, 1 }, { viewer.cell_at(layout, 7, 4) })
    assert.same({ 1, 2 }, { viewer.cell_at(layout, 7, 9) })
    assert.same({ 2, 3 }, { viewer.cell_at(layout, 8, 20) })
  end)

  it("gives the gap and the gutter to the next cell, and the end to the last", function()
    assert.same({ 1, 1 }, { viewer.cell_at(layout, 7, 0) })
    assert.same({ 1, 2 }, { viewer.cell_at(layout, 7, 6) })
    assert.same({ 1, 3 }, { viewer.cell_at(layout, 7, 99) })
  end)

  it("ignores header lines and lines past the data", function()
    assert.is_nil(viewer.cell_at(layout, 3, 0))
    assert.is_nil(viewer.cell_at(layout, 9, 0))
  end)

  it("uses column 1 for fields and list lines", function()
    local fields = { data_line = 6, count = 3, cols = 0, pos = {} }
    assert.same({ 2, 1 }, { viewer.cell_at(fields, 7, 15) })
  end)
end)

describe("viewer paths", function()
  local viewer = require("octave_dbg.viewer")

  it("accepts names, fields and plain integer cell indices", function()
    for _, p in ipairs({ "c", "mpc.bus", "c{3}", "c{2,3}", "c{4}{2}.x", "data{1}.x", "a.b{10,2}.c" }) do
      assert.is_true(viewer.valid_path(p), p)
    end
  end)

  it("refuses anything that could be an expression", function()
    for _, p in ipairs({ "", "1c", "c{0}", "c{03}", "c{end}", "c{k}", "c{1+1}", "c(2)", "c{1};system(1)",
      "c{1,1,1}", "c{}", "c{ 1}", "c.", "c..x", "c{1}x" }) do
      assert.is_false(viewer.valid_path(p), p)
    end
  end)

  it("builds the path of a cell element", function()
    assert.equals("c{2,3}", viewer.element_name("c", 2, 3))
    assert.equals("s.data{1,4}", viewer.element_name("s.data", 1, 4))
  end)

  it("offers <CR> on the elements of a cell", function()
    local ask = require("octave_dbg.ask")
    local a = ask.parse("#\t1\nname\tc\nscope\tbase\nstatus\tok\nclass\tcell\nsize\t1x2\nnumel\t2\nkind\tcell\nmode\tgrid\nrow\t1\ncol\t1\nnrows\t1\nncols\t2\n#body\n1\t'two'\n#end\n")
    local text = table.concat(viewer.render(a, { name = "c", mode = "grid", kind = "cell", rows = 1, cols = 2 }), "\n")
    assert.truthy(text:find("<CR> open element", 1, true))
  end)
end)

describe("main script", function()
  local main = require("octave_dbg.main")

  it("finds the main script for a folder or a parent folder", function()
    local map = { ["/p"] = "/p/main.m", ["/q/sub"] = "/q/run_all.m" }
    assert.same({ "/p/main.m", "/p" }, { main.lookup(map, "/p") })
    assert.same({ "/p/main.m", "/p" }, { main.lookup(map, "/p/lib/deep") })
    assert.same({ "/q/run_all.m", "/q/sub" }, { main.lookup(map, "/q/sub/x") })
    assert.is_nil(main.lookup(map, "/q"))
    assert.is_nil(main.lookup(map, "/other"))
  end)

  it("tells function files from scripts", function()
    assert.is_true(main.is_function_file({ "function y = f (x)", "  y = x;", "end" }))
    assert.is_true(main.is_function_file({ "% f -- help text", "", "# more", "function f", "end" }))
    assert.is_true(main.is_function_file({ "%{", "block comment", "%}", "function [a, b] = g ()" }))
    assert.is_true(main.is_function_file({ "function[a]=h()" }))
    assert.is_false(main.is_function_file({ "% main script", "x = 1;", "function y = local_f (x)", "end" }))
    assert.is_false(main.is_function_file({ "1;", "function y = f (x)", "end" }))
    assert.is_false(main.is_function_file({ "functions_list = {};" }))
    assert.is_false(main.is_function_file({}))
  end)

  it("builds the run command", function()
    assert.equals("run('/p/main.m')", main.run_command("/p/main.m", { "x = 1;" }))
    assert.equals("addpath('/p/lib'); my_fun", main.run_command("/p/lib/my_fun.m", { "function y = my_fun (x)" }))
    assert.equals("run('/p/it''s.m')", main.run_command("/p/it's.m", { "x = 1;" }))
  end)

  it("completes the argument of :OctaveDbg main", function()
    assert.truthy(vim.tbl_contains(od.complete("cl", "OctaveDbg main cl"), "clear"))
    assert.same({}, od.complete("", "OctaveDbg main a.m "))
    assert.truthy(vim.tbl_contains(od.complete("ma", "OctaveDbg ma"), "main"))
  end)
end)
