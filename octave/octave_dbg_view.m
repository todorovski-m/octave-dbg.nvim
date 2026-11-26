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
  %
  % None of these call disp, full or mat2str on a whole large value.

  switch (action)
    case 'header'
      out = sparse_header (val);
    case 'stats'
      out = stats_line (val);
    case 'entries'
      out = sparse_entries (val, varargin{1}, varargin{2});
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
