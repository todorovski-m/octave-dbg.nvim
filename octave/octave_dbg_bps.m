function octave_dbg_bps (file, id)
  % octave_dbg_bps -- write all breakpoints to FILE for octave-dbg.nvim.
  %
  % The first line is "#<TAB>ID", so that Neovim can match the answer to its
  % request. Then one line per breakpoint: <absolute file><TAB><line>.
  % The last line is "#end", so that a half-written file is never used.

  s = dbstatus ();
  fid = fopen (file, 'w');
  if (fid < 0)
    return;
  end
  fprintf (fid, '#\t%d\n', id);
  for k = 1:numel (s)
    for l = s(k).line(:)'
      fprintf (fid, '%s\t%d\n', s(k).file, l);
    end
  end
  fprintf (fid, '#end\n');
  fclose (fid);
end
