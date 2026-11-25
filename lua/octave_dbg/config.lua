-- Options storage and lookup.
--
-- Every option can be a plain value or a function that receives the buffer
-- number and returns the value. A buffer-local variable
-- `vim.b.octave_dbg_<name>` overrides the global option for that buffer.

local M = {}

M.defaults = {
  -- Command that starts Octave. String or list of strings.
  cmd = { "octave", "--no-gui", "--quiet" },
  -- Ex command used to open the REPL window.
  split = "vsplit",
  -- Vim regex that marks the start of a cell.
  cell_delimiter = "^%%",
  -- Wrap multi-line text in bracketed-paste escape codes.
  bracketed_paste = true,
  -- How many times the REPL may be restarted automatically after it dies.
  max_restarts = 3,
  -- Create the default buffer-local keymaps for Octave files.
  setup_keymap = false,
  -- Prefix for the default keymaps.
  keymap_prefix = "<leader>o",
  -- Filetypes that count as Octave buffers.
  filetypes = { "octave", "matlab" },
  -- Text and highlight group of the breakpoint sign.
  sign_text = "●",
  sign_hl = "DiagnosticError",
  -- Number of sent commands and output lines kept for `:OctaveDbg debug`.
  log_size = 200,

  -- Current-line marker --
  -- Mark the line where the debugger stopped.
  marker = true,
  -- Show the stop location in a source window and move its cursor there.
  follow = true,
  -- Milliseconds of quiet REPL output before the marker is updated.
  marker_debounce = 80,
  marker_sign_text = "▶",
  marker_sign_hl = "DiagnosticWarn",
  -- Highlight group for the whole line (defaults to a link to Visual).
  marker_line_hl = "OctaveDbgCurrentLine",
  -- Lua patterns for Octave's normal prompt. Seeing one ends the marker.
  prompt_patterns = { "^octave:%d+>%s*$", "^>>%s*$" },
  -- Lua pattern for the debug prompt.
  debug_prompt_pattern = "^debug>%s*$",

  -- Variables panel --
  -- Ex command that opens the panel window.
  panel_split = "botright 10split",

  -- Hover --
  -- Most lines of `disp` output shown in the hover window.
  hover_max_lines = 20,
  -- Milliseconds to wait for Octave before showing "Octave is busy".
  hover_timeout = 1000,
  -- Values with more elements get a summary instead of their `disp` output.
  hover_max_elements = 1000,
  -- Border of the hover window (see :help nvim_open_win()).
  hover_border = "rounded",
  -- Most lines of the help popup shown at once (it can be scrolled).
  help_max_height = 20,

  -- MATLAB-style keys in Octave buffers: true, false, or a table that
  -- changes or (with false) removes single keys, for example
  -- { step = "<F8>", interrupt = false }. See :help octave-dbg-matlab-keys.
  matlab_keys = false,
}

local options = vim.deepcopy(M.defaults)

function M.set(opts)
  options = vim.tbl_deep_extend("force", vim.deepcopy(M.defaults), opts or {})
end

--- Resolve one option for a buffer.
---@param name string
---@param bufnr? integer
function M.get(name, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local value
  if vim.api.nvim_buf_is_valid(bufnr) then
    value = vim.b[bufnr]["octave_dbg_" .. name]
  end
  if value == nil then
    value = options[name]
  end
  if type(value) == "function" then
    value = value(bufnr)
  end
  return value
end

return M
