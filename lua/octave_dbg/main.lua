-- The main script: the file that "run" starts, wherever the cursor is.
--
-- Working on a function that a script calls, F5 should run the script, while
-- breakpoints are set in the function. `:OctaveDbg main` sets the main
-- script; it is remembered per folder in stdpath("data")/octave-dbg/main.json
-- (outside the project, so that no project file changes). From the current
-- file, the folders are searched upwards for a remembered main script, then
-- from the working directory; the option `main` (a path, a function, or
-- vim.b.octave_dbg_main) is the fallback. Without a main script, the current
-- file runs. A function file is called by its name without arguments (so its
-- defaults for nargin == 0 take effect, and "ans" is shown); a script runs
-- with run().

local config = require("octave_dbg.config")

local M = {}

local cache = nil -- { [folder] = main path }

local function store_file()
  return vim.fn.stdpath("data") .. "/octave-dbg/main.json"
end

local function load()
  if cache then
    return cache
  end
  cache = {}
  local f = io.open(store_file(), "r")
  if f then
    local ok, data = pcall(vim.json.decode, f:read("*a"))
    f:close()
    if ok and type(data) == "table" then
      cache = data
    end
  end
  return cache
end

local function save()
  vim.fn.mkdir(vim.fn.fnamemodify(store_file(), ":h"), "p")
  local f = io.open(store_file(), "w")
  if f then
    f:write(vim.json.encode(load()))
    f:close()
  end
end

local function abs(path)
  return vim.fn.fnamemodify(vim.fn.expand(path), ":p")
end

local function folder_of_buf(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name ~= "" and vim.fn.fnamemodify(name, ":p:h") or nil
end

--- The main script for `dir` in `map` ({ [folder] = path }), searching the
--- folder and its parents. Pure; exposed for tests.
---@return string|nil main, string|nil folder
function M.lookup(map, dir)
  local d = dir
  while d and d ~= "" do
    if map[d] then
      return map[d], d
    end
    local parent = vim.fn.fnamemodify(d, ":h")
    if parent == d then
      break
    end
    d = parent
  end
  return nil
end

--- True when the first line of code (after comments and empty lines) starts
--- with "function". Pure; exposed for tests.
---@param lines string[]
function M.is_function_file(lines)
  local in_block = false
  for _, line in ipairs(lines) do
    local t = vim.trim(line)
    if in_block then
      if t == "%}" or t == "#}" then
        in_block = false
      end
    elseif t == "%{" or t == "#{" then
      in_block = true
    elseif t ~= "" and not t:match("^[%%#]") then
      return t:match("^function[%s%[%(]") ~= nil or t == "function"
    end
  end
  return false
end

local function quote(s)
  return "'" .. s:gsub("'", "''") .. "'"
end

--- The Octave command that runs `path`: run('<path>') for a script; for a
--- function file, addpath of its folder and a call by name. Pure; for tests.
---@param path string absolute path
---@param lines string[] the first lines of the file
function M.run_command(path, lines)
  if M.is_function_file(lines) then
    return ("addpath(%s); %s"):format(quote(vim.fn.fnamemodify(path, ":h")), vim.fn.fnamemodify(path, ":t:r"))
  end
  return "run(" .. quote(path) .. ")"
end

--- The first lines of a file: from its buffer when it is loaded (it may have
--- unsaved changes), else from disk.
function M.head(path, n)
  n = n or 200
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) and abs(vim.api.nvim_buf_get_name(buf)) == path then
      return vim.api.nvim_buf_get_lines(buf, 0, n, false)
    end
  end
  local ok, lines = pcall(vim.fn.readfile, path, "", n)
  return ok and lines or {}
end

--- The main script for a buffer, or nil.
---@param bufnr integer
---@return string|nil
function M.get(bufnr)
  local map = load()
  for _, dir in ipairs({ folder_of_buf(bufnr), vim.fn.getcwd() }) do
    local m = dir and M.lookup(map, dir)
    if m and vim.fn.filereadable(m) == 1 then
      return m
    end
  end
  local opt = config.get("main", bufnr)
  if type(opt) == "string" and opt ~= "" and vim.fn.filereadable(abs(opt)) == 1 then
    return abs(opt)
  end
  return nil
end

--- Set the main script (default: the file of `bufnr`). It is remembered for
--- its own folder and for the folder of `bufnr`.
---@return string|nil path
function M.set(bufnr, path)
  path = path and path ~= "" and abs(path) or abs(vim.api.nvim_buf_get_name(bufnr))
  if vim.fn.filereadable(path) ~= 1 or not path:match("%.m$") then
    vim.notify("octave-dbg: not an existing .m file: " .. path, vim.log.levels.WARN)
    return nil
  end
  local map = load()
  map[vim.fn.fnamemodify(path, ":h")] = path
  local here = folder_of_buf(bufnr)
  if here then
    map[here] = path
  end
  save()
  return path
end

--- Forget the main script that applies to `bufnr` (all its entries).
---@return string|nil the main script that was forgotten
function M.clear(bufnr)
  local m = M.get(bufnr)
  if not m then
    return nil
  end
  local map = load()
  for dir, p in pairs(map) do
    if p == m then
      map[dir] = nil
    end
  end
  save()
  return m
end

return M
