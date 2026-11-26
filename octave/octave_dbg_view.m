function out = octave_dbg_view (action, val, varargin)
  % octave_dbg_view -- formatting helpers for octave-dbg.nvim.
  %
  %   octave_dbg_view ('header', VAL)
  %       Octave's own first line for a sparse matrix:
  %       "Compressed Column Sparse (rows = R, cols = C, nnz = N [P%])".
  %   octave_dbg_view ('stats', VAL)
  %       "min A   max B   mean C" for a numeric or logical value, computed
  %       from the nonzero entries for a sparse value (so that no huge
  %       temporary is made) and from abs() for a complex value. '' when
  %       statistics do not apply.
  %   octave_dbg_view ('entries', VAL, FIRST, COUNT)
  %       Entries FIRST .. FIRST+COUNT-1 of the nonzero list of a sparse
  %       VAL, in column-major order, formatted by Octave as
  %       "(i, j) -> value".
  %   octave_dbg_view ('is_large', VAL, MAX_ELEMENTS)
  %       True when disp of VAL would print more than MAX_ELEMENTS values:
  %       a large array (sparse: by nonzeros), or a struct or cell that holds
  %       one, looked for up to 3 levels deep (deeper counts as large).
  %   octave_dbg_view ('fields', VAL)
  %       The fields of a scalar struct, one per line: name, size and class,
  %       and a short value, in aligned columns.
  %   octave_dbg_view ('answer', VAL, REQ, SCOPE, ISVAR)
  %       The text of view.ans for the large-value viewer. REQ is the cell of
  %       request fields {ID, NAME, MODE, ROW, COL, NROWS, NCOLS, CPLX}:
  %         MODE  'grid' (a window of rows ROW.. and columns COL..),
  %               'list' (sparse: nonzero entries from position ROW on),
  %               'find' (sparse: the list page that starts at the first
  %               nonzero at or after row ROW, column COL)
  %         CPLX  'cart' (real and imaginary parts) or 'polar' (magnitude
  %               and angle in degrees)
  %       VAL is the value of the first part of NAME; further parts are
  %       struct fields. Cells of the window are sent tab-separated, one row
  %       per line, and Neovim aligns them.
  %
  % None of these call disp, full or mat2str on a whole large value.

  switch (action)
    case 'header'
      out = sparse_header (val);
    case 'stats'
      out = stats_line (val);
    case 'entries'
      out = sparse_entries (val, varargin{1}, varargin{2});
    case 'answer'
      out = view_answer (val, varargin{:});
    case 'is_large'
      out = is_large (val, varargin{1}, 0);
    case 'fields'
      out = fields_text (val);
    otherwise
      error ('octave_dbg_view: unknown action %s', action);
  end
end

function s = sparse_header (val)
  % Same rule as Octave's pr-output.cc: 2 significant digits, more near
  % 100%, so that a matrix that is not full never shows 100%.
  [r, c] = size (val);
  nz = nnz (val);
  pct = 0;
  if (r * c > 0)
    pct = nz / (r * c) * 100;
  end
  prec = 2;
  if (pct == 100)
    prec = 3;
  else
    if (pct > 99.9)
      prec = 4;
    elseif (pct > 99)
      prec = 3;
    end
    if (pct > 99.99)
      pct = 99.99;
    end
  end
  s = sprintf ('Compressed Column Sparse (rows = %d, cols = %d, nnz = %d [%.*g%%])', ...
               r, c, nz, prec, pct);
end

function s = stats_line (val)
  s = '';
  if (! ((isnumeric (val) || islogical (val)) && ! isempty (val)))
    return;
  end
  if (issparse (val))
    [~, ~, v] = find (val);
    n = numel (val);
    has_zero = numel (v) < n;
  else
    v = val(:);
    n = numel (v);
    has_zero = false;
  end
  label = '';
  if (! isreal (v))
    v = abs (v);
    label = 'abs: ';
  end
  v = double (full (v));
  if (isempty (v))
    mn = 0;
    mx = 0;
  else
    mn = min (v);
    mx = max (v);
  end
  if (has_zero)
    mn = min (mn, 0);
    mx = max (mx, 0);
  end
  me = sum (v) / n;
  s = sprintf ('%smin %g   max %g   mean %g', label, mn, mx, me);
end

function txt = sparse_entries (val, first, count)
  % Octave formats and aligns the entries: they are put into an empty
  % sparse matrix of the same size, and only its header line is dropped.
  [i, j, v] = find (val);
  last = min (numel (v), first + count - 1);
  if (first > last)
    txt = '';
    return;
  end
  k = first:last;
  part = sparse (i(k), j(k), v(k), rows (val), columns (val));
  old = split_long_rows ();
  unwind_protect
    split_long_rows (false);
    txt = evalc ('disp (part)');
  unwind_protect_cleanup
    split_long_rows (old);
  end_unwind_protect
  lines = strsplit (txt, "\n");
  % Drop the header and the empty line after it.
  keep = ! strncmp (lines, 'Compressed Column Sparse', 24);
  lines = lines(keep);
  while (! isempty (lines) && isempty (strtrim (lines{1})))
    lines(1) = [];
  end
  txt = strjoin (lines, "\n");
end

% Viewer ---------------------------------------------------------------------

function txt = view_answer (val, req, scope, isvar)
  id = req{1};
  name = req{2};
  head = sprintf ("#\t%s\nname\t%s\nscope\t%s\n", id, name, scope);
  try
    if (isempty (regexp (name, '^[A-Za-z]\w*(\.[A-Za-z]\w*)*$', 'once')))
      error ('not a variable name: %s', name);
    end
    if (! isvar)
      txt = [head "status\tnotvar\n#end\n"];
      return;
    end
    parts = strsplit (name, '.');
    val = descend (val, parts);
    mode = req{3};
    row = max (1, round (str2double (req{4})));
    col = max (1, round (str2double (req{5})));
    nrows = max (1, round (str2double (req{6})));
    ncols = max (1, round (str2double (req{7})));
    polar = strcmp (req{8}, 'polar');
    old = split_long_rows ();
    unwind_protect
      split_long_rows (false);
      [fields, body] = view_body (val, mode, row, col, nrows, ncols, polar);
    unwind_protect_cleanup
      split_long_rows (old);
    end_unwind_protect
    dims = strjoin (arrayfun (@num2str, size (val), 'UniformOutput', false), 'x');
    txt = sprintf ("%sstatus\tok\nclass\t%s\nsize\t%s\nnumel\t%d\n%s#body\n%s#end\n", ...
                   head, class_text (val), dims, numel (val), fields, body);
  catch e
    msg = strrep (e.message, "\n", ' ');
    txt = sprintf ("%sstatus\terror\nmessage\t%s\n#end\n", head, msg);
  end
end

function val = descend (val, parts)
  for k = 2:numel (parts)
    where = strjoin (parts(1:k-1), '.');
    if (! isstruct (val) && ! isobject (val))
      error ('%s is a %s, not a struct', where, class (val));
    end
    if (numel (val) != 1)
      error ('%s is a %s array; index it first', where, ...
             strjoin (arrayfun (@num2str, size (val), 'UniformOutput', false), 'x'));
    end
    if (! isfield (val, parts{k}) && ! (isobject (val) && isprop (val, parts{k})))
      error ('%s has no field %s', where, parts{k});
    end
    val = val.(parts{k});
  end
end

function s = class_text (val)
  s = class (val);
  if (issparse (val))
    s = [s ' sparse'];
  end
  if (isnumeric (val) && ! isreal (val))
    s = [s ' complex'];
  end
end

function [fields, body] = view_body (val, mode, row, col, nrows, ncols, polar)
  % fields: extra "key<TAB>value" header lines; body: the lines of the window.
  fields = '';
  if (issparse (val))
    nz = nnz (val);
    fields = sprintf ("kind\tsparse\nnnz\t%d\nheader\t%s\nstats\t%s\n", ...
                      nz, sparse_header (val), stats_line (val));
    if (strcmp (mode, 'list') || strcmp (mode, 'find'))
      [i, j, v] = find (val);
      if (strcmp (mode, 'find'))
        % First entry at or after (row, col) in column-major order.
        first = find ((j > col) | (j == col & i >= row), 1);
        if (isempty (first))
          first = nz + 1;
        end
      else
        first = row;
      end
      last = min (nz, first + nrows - 1);
      fields = [fields sprintf("mode\tlist\nfirst\t%d\ncount\t%d\n", first, max (0, last - first + 1))];
      body = '';
      cplx = ! isreal (v);
      for k = first:last
        body = [body sprintf("%d\t%d\t%s\n", i(k), j(k), fmt_num (v(k), polar, cplx))];
      end
      return;
    end
    [fields2, body] = grid_window (val, row, col, nrows, ncols, polar, true);
    fields = [fields "mode\tgrid\n" fields2];
    return;
  end
  if (isnumeric (val) || islogical (val))
    fields = sprintf ("kind\tdense\nstats\t%s\n", stats_line (val));
    if (ndims (val) > 2)
      sz = size (val);
      fields = [fields sprintf("note\tshowing the first page (:,:,1) of %s\n", ...
                                strjoin (arrayfun (@num2str, sz, 'UniformOutput', false), 'x'))];
      val = val(:, :, 1);
    end
    [fields2, body] = grid_window (val, row, col, nrows, ncols, polar, false);
    fields = [fields "mode\tgrid\n" fields2];
  elseif (iscell (val))
    if (ndims (val) > 2)
      error ('N-D cell arrays are not supported in the viewer');
    end
    [fields2, body] = cell_window (val, row, col, nrows, ncols);
    fields = ["kind\tcell\nmode\tgrid\n" fields2];
  elseif (isstruct (val))
    if (numel (val) != 1)
      error ('the viewer shows one struct; this is a %s struct array (fields: %s)', ...
             strjoin (arrayfun (@num2str, size (val), 'UniformOutput', false), 'x'), ...
             strjoin (fieldnames (val)', ', '));
    end
    [fields2, body] = struct_window (val, row, nrows);
    fields = ["kind\tstruct\nmode\tfields\n" fields2];
  elseif (ischar (val))
    if (ndims (val) > 2)
      error ('N-D char arrays are not supported in the viewer');
    end
    last = min (rows (val), row + nrows - 1);
    fields = sprintf ("kind\tchar\nmode\tlines\nrow\t%d\ncount\t%d\n", row, max (0, last - row + 1));
    body = '';
    for r = row:last
      body = [body strrep(val(r, :), "\t", ' ') "\n"];
    end
  else
    error ('the viewer shows numeric, logical, char, cell and struct values, not %s', class (val));
  end
end

function [fields, body] = grid_window (val, row, col, nrows, ncols, polar, dot_zeros)
  [R, C] = size (val);
  r2 = min (R, row + nrows - 1);
  c2 = min (C, col + ncols - 1);
  fields = sprintf ("row\t%d\ncol\t%d\nnrows\t%d\nncols\t%d\n", row, col, ...
                    max (0, r2 - row + 1), max (0, c2 - col + 1));
  body = '';
  if (row > r2 || col > c2)
    return;
  end
  w = val(row:r2, col:c2);
  if (issparse (w))
    w = full (w);   % only the window
  end
  % Decide from the whole window: one element of a complex array with a
  % zero imaginary part comes out as a real number.
  cplx = isnumeric (w) && ! isreal (w);
  for r = 1:rows (w)
    cells = cell (1, columns (w));
    for c = 1:columns (w)
      x = w(r, c);
      if (dot_zeros && x == 0)
        cells{c} = '.';
      else
        cells{c} = fmt_num (x, polar, cplx);
      end
    end
    body = [body strjoin(cells, "\t") "\n"];
  end
end

function [fields, body] = cell_window (val, row, col, nrows, ncols)
  [R, C] = size (val);
  r2 = min (R, row + nrows - 1);
  c2 = min (C, col + ncols - 1);
  fields = sprintf ("row\t%d\ncol\t%d\nnrows\t%d\nncols\t%d\n", row, col, ...
                    max (0, r2 - row + 1), max (0, c2 - col + 1));
  body = '';
  for r = row:r2
    cells = cell (1, max (0, c2 - col + 1));
    for c = col:c2
      cells{c - col + 1} = short_value (val{r, c});
    end
    body = [body strjoin(cells, "\t") "\n"];
  end
end

function [fields, body] = struct_window (val, row, nrows)
  names = fieldnames (val);
  last = min (numel (names), row + nrows - 1);
  fields = sprintf ("row\t%d\ncount\t%d\ntotal\t%d\n", row, max (0, last - row + 1), numel (names));
  body = '';
  for k = row:last
    v = val.(names{k});
    dims = strjoin (arrayfun (@num2str, size (v), 'UniformOutput', false), 'x');
    body = [body sprintf("%s\t%s %s\t%s\n", names{k}, dims, class_text (v), short_value (v))];
  end
end

function s = short_value (v)
  % A one-line summary; small values are shown, large ones only described.
  dims = strjoin (arrayfun (@num2str, size (v), 'UniformOutput', false), 'x');
  if (ischar (v) && rows (v) <= 1)
    s = ['''' v ''''];
    if (numel (s) > 40)
      s = [s(1:37) '...'];
    end
  elseif ((isnumeric (v) || islogical (v)) && ! issparse (v) && numel (v) == 1)
    s = fmt_num (v, false);
  elseif ((isnumeric (v) || islogical (v)) && ! issparse (v) && numel (v) <= 6 && ndims (v) == 2)
    parts = arrayfun (@(x) fmt_num (x, false), v, 'UniformOutput', false);
    rowtxt = cell (1, rows (v));
    for r = 1:rows (v)
      rowtxt{r} = strjoin (parts(r, :), ' ');
    end
    s = ['[' strjoin(rowtxt, '; ') ']'];
  else
    s = sprintf ('[%s %s]', dims, class_text (v));
  end
  s = strrep (strrep (s, "\t", ' '), "\n", ' ');
end

function s = fmt_num (x, polar, cplx)
  % One number as text: integers exactly, others with 5 significant digits.
  % Complex numbers as "re + imi", or "magnitude ∠ angle°" when POLAR.
  % CPLX forces the complex form (the element may have come out real).
  if (nargin < 3)
    cplx = false;
  end
  if (islogical (x))
    s = sprintf ('%d', x);
  elseif (cplx || ! isreal (x))
    x = complex (x);
    if (polar)
      s = sprintf ('%s ∠ %s°', fmt_real (abs (x)), fmt_real (angle (x) * 180 / pi));
    else
      im = imag (x);
      sign = '+';
      if (im < 0 || (im == 0 && 1 / im < 0))
        sign = '-';
      end
      s = sprintf ('%s %s %si', fmt_real (real (x)), sign, fmt_real (abs (im)));
    end
  else
    s = fmt_real (x);
  end
end

function s = fmt_real (x)
  if (isinteger (x))
    s = sprintf ('%d', x);
  elseif (isnan (x))
    s = 'NaN';
  elseif (isinf (x))
    if (x > 0)
      s = 'Inf';
    else
      s = '-Inf';
    end
  elseif (x == fix (x) && abs (x) < 1e10)
    s = sprintf ('%d', x);
  else
    s = sprintf ('%.5g', x);
  end
end

% Structs in the hover --------------------------------------------------------

function tf = is_large (v, max_elements, depth)
  if (issparse (v))
    tf = nnz (v) > max_elements;
  elseif (isstruct (v) || iscell (v))
    if (depth >= 3 || numel (v) > max_elements)
      tf = true;
      return;
    end
    tf = false;
    if (isstruct (v))
      names = fieldnames (v);
      for k = 1:numel (v)
        for f = 1:numel (names)
          if (is_large (v(k).(names{f}), max_elements, depth + 1))
            tf = true;
            return;
          end
        end
      end
    else
      for k = 1:numel (v)
        if (is_large (v{k}, max_elements, depth + 1))
          tf = true;
          return;
        end
      end
    end
  else
    tf = numel (v) > max_elements;
  end
end

function txt = fields_text (val)
  names = fieldnames (val);
  descr = cell (size (names));
  for k = 1:numel (names)
    v = val.(names{k});
    dims = strjoin (arrayfun (@num2str, size (v), 'UniformOutput', false), 'x');
    descr{k} = sprintf ('%s %s', dims, class_text (v));
  end
  w1 = max ([0; cellfun(@numel, names)]);
  w2 = max ([0; cellfun(@numel, descr)]);
  lines = cell (size (names));
  for k = 1:numel (names)
    lines{k} = sprintf ('%-*s  %-*s  %s', w1, names{k}, w2, descr{k}, short_value (val.(names{k})));
  end
  txt = strjoin (lines', "\n");
end
