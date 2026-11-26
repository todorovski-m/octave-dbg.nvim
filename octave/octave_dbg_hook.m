function octave_dbg_hook (action, dir)
  % octave_dbg_hook -- input event hook for octave-dbg.nvim.
  %
  %   octave_dbg_hook ('start', DIR)  register the hook (once; safe to repeat)
  %   octave_dbg_hook ('stop')        remove it
  %
  % Octave calls the hook several times a second while it waits for input.
  % It then sees the workspace of the prompt: the base workspace, or the
  % frame that the debugger stopped in. Neovim controls it with files in DIR:
  %
  %   panel.on   exists while the variables panel is open; the hook then
  %              writes the variables to whos.txt when they change
  %   hover.req  "ID<TAB>NAME<TAB>MAX_ELEMENTS"; the hook answers in
  %              hover.ans and deletes the request
  %   help.req   "ID<TAB>NAME"; the hook answers with the output of
  %              help NAME in help.ans and deletes the request
  %   view.req   "ID<TAB>PATH<TAB>MODE<TAB>ROW<TAB>COL<TAB>NROWS<TAB>NCOLS<TAB>CPLX"
  %              (PATH: a name with ".field", "{i}" or "{i,j}" parts);
  %              the hook answers with one window of the value in view.ans
  %              (see octave_dbg_view.m) and deletes the request
  %
  % Names are checked to be plain dotted names before they reach evalin.
  %
  % Every file the hook writes ends with "#end", so that Neovim never uses a
  % half-written file.

  persistent id

  switch (action)
    case 'start'
      if (isempty (id))
        id = add_input_event_hook (@tick, dir);
        mlock ();
      end
    case 'stop'
      if (! isempty (id))
        remove_input_event_hook (id, false);
        id = [];
        munlock ();
      end
  end
end

function tick (dir)
  % Called by Octave. All evalin ('caller', ...) calls must be made here:
  % only in this function is 'caller' the frame of the prompt.
  persistent last_panel

  try
    st = dbstack ();
    if (numel (st) >= 2)
      scope = sprintf ('%s\t%d', st(2).name, st(2).line);
    else
      scope = 'base';
    end

    % Variables panel.
    panel_file = [dir '/whos.txt'];
    if (exist ([dir '/panel.on'], 'file'))
      vars = evalin ('caller', 'whos');
      values = cell (1, numel (vars));
      for k = 1:numel (vars)
        if (wants_preview (vars(k)))
          values{k} = evalin ('caller', vars(k).name);
        end
      end
      txt = panel_text (scope, vars, values);
      if (! strcmp (txt, last_panel) || ! exist (panel_file, 'file'))
        write_file (panel_file, txt);
        last_panel = txt;
      end
    end

    % Hover request.
    req_file = [dir '/hover.req'];
    if (exist (req_file, 'file'))
      req = strsplit (strtrim (fileread (req_file)), "\t");
      delete (req_file);
      if (numel (req) >= 3 && valid_name (req{2}))
        name = req{2};
        parts = strsplit (name, '.');
        isvar = evalin ('caller', sprintf ('exist (''%s'', ''var'')', parts{1}));
        if (isvar == 1)
          val = evalin ('caller', parts{1});
        else
          val = [];
        end
        txt = hover_text (req{1}, name, parts, isvar == 1, val, scope, str2double (req{3}));
        write_file ([dir '/hover.ans'], txt);
      end
    end

    % Viewer request.
    view_file = [dir '/view.req'];
    if (exist (view_file, 'file'))
      req = strsplit (strtrim (fileread (view_file)), "\t");
      delete (view_file);
      if (numel (req) >= 8)
        isvar = false;
        val = [];
        % A path such as mpc.bus or c{2,3}{1}: only its leading name goes
        % to evalin; octave_dbg_view checks and walks the rest.
        base = regexp (req{2}, '^[A-Za-z]\w*', 'match', 'once');
        if (! isempty (base))
          isvar = evalin ('caller', sprintf ('exist (''%s'', ''var'')', base)) == 1;
          if (isvar)
            val = evalin ('caller', base);
          end
        end
        write_file ([dir '/view.ans'], octave_dbg_view ('answer', val, req, scope, isvar));
      end
    end

    % Help request.
    help_file = [dir '/help.req'];
    if (exist (help_file, 'file'))
      req = strsplit (strtrim (fileread (help_file)), "\t");
      delete (help_file);
      if (numel (req) >= 2)
        write_file ([dir '/help.ans'], help_answer (req{1}, req{2}));
      end
    end
  catch
    % Never let an error escape into the prompt.
  end
end

function tf = valid_name (name)
  % Plain names and dotted struct field paths only, so that nothing else can
  % reach evalin.
  tf = ! isempty (regexp (name, '^[A-Za-z]\w*(\.[A-Za-z]\w*)*$', 'once'));
end

function write_file (file, txt)
  fid = fopen (file, 'w');
  if (fid >= 0)
    fputs (fid, txt);
    fclose (fid);
  end
end

% Panel ----------------------------------------------------------------------

function txt = panel_text (scope, vars, values)
  parts = {['#' "\t" scope "\n"]};
  for k = 1:numel (vars)
    v = vars(k);
    dims = strjoin (arrayfun (@num2str, v.size, 'UniformOutput', false), 'x');
    value = '';
    if (wants_preview (v))
      value = preview (values{k});
    end
    parts{end+1} = sprintf ('%s\t%s\t%s\t%d\t%s\n', v.name, dims, v.class, ...
                            v.bytes, value);
  end
  parts{end+1} = "#end\n";
  txt = [parts{:}];
end

function tf = wants_preview (v)
  % True for small numeric and logical values and for one-line strings.
  numeric = {'double', 'single', 'logical', 'int8', 'int16', 'int32', ...
             'int64', 'uint8', 'uint16', 'uint32', 'uint64'};
  if (strcmp (v.class, 'char'))
    tf = numel (v.size) == 2 && v.size(1) <= 1;
  else
    tf = any (strcmp (v.class, numeric)) && prod (v.size) <= 10 && numel (v.size) == 2;
  end
end

function s = preview (val)
  % Short text for a value; wants_preview decides which values get one.
  if (ischar (val))
    s = ['''' val ''''];
  else
    s = mat2str (val, 5);
  end
  s = strrep (strrep (s, "\t", ' '), "\n", ' ');
  if (numel (s) > 60)
    s = [s(1:57) '...'];
  end
end

% Hover ----------------------------------------------------------------------

function txt = hover_text (id, name, parts, isvar, val, scope, max_elements)
  head = sprintf ("#\t%s\nname\t%s\nscope\t%s\n", id, name, scope);
  if (! isvar)
    txt = [head "status\tnotvar\n#end\n"];
    return;
  end
  try
    for k = 2:numel (parts)
      if (! isstruct (val) && ! isobject (val))
        error ('%s is a %s, not a struct', strjoin (parts(1:k-1), '.'), class (val));
      end
      if (numel (val) != 1)
        error ('%s is a %s array; index it first', strjoin (parts(1:k-1), '.'), ...
               strjoin (arrayfun (@num2str, size (val), 'UniformOutput', false), 'x'));
      end
      if (! isfield (val, parts{k}) && ! (isobject (val) && isprop (val, parts{k})))
        error ('%s has no field %s', strjoin (parts(1:k-1), '.'), parts{k});
      end
      val = val.(parts{k});
    end
    dims = strjoin (arrayfun (@num2str, size (val), 'UniformOutput', false), 'x');
    [body, note] = hover_body (val, max_elements);
    txt = sprintf ("%sstatus\tok\nclass\t%s\nsize\t%s\nnote\t%s\n#body\n%s\n#end\n", ...
                   head, class_text (val), dims, note, body);
  catch e
    msg = strrep (e.message, "\n", ' ');
    txt = sprintf ("%sstatus\terror\nmessage\t%s\n#end\n", head, msg);
  end
end

function s = class_text (val)
  % The class, with "sparse" and "complex" added for numeric values.
  % (isreal is false for cells and structs, so only numeric values count.)
  s = class (val);
  if (issparse (val))
    s = [s ' sparse'];
  end
  if (isnumeric (val) && ! isreal (val))
    s = [s ' complex'];
  end
end

function txt = help_answer (id, name)
  % Output of "help NAME". Only plain (dotted) names are accepted, so that
  % nothing else can be evaluated.
  head = sprintf ("#\t%s\nname\t%s\nscope\tbase\n", id, name);
  try
    if (isempty (regexp (name, '^[A-Za-z]\w*(\.[A-Za-z]\w*)*$', 'once')))
      error ('not a function name: %s', name);
    end
    body = evalc (sprintf ('help %s', name));
    txt = sprintf ("%sstatus\tok\nclass\t\nsize\t\nnote\t\n#body\n%s\n#end\n", head, body);
  catch e
    msg = strrep (e.message, "\n", ' ');
    txt = sprintf ("%sstatus\terror\nmessage\t%s\n#end\n", head, msg);
  end
end

function [body, note] = hover_body (val, max_elements)
  % disp output, or a summary for large values (disp of a 1000x1000 matrix
  % takes about 0.4 s and produces 13 MB of text). Sparse values are judged
  % by their number of nonzeros, not by rows times columns, and their
  % statistics come from the nonzeros only: mean() over a 1e8-element
  % sparse column takes minutes and would freeze Octave.
  note = '';
  n = numel (val);
  if (issparse (val))
    nz = nnz (val);
    if (nz <= max_elements)
      body = disp_text (val);
      return;
    end
    show = 20;
    note = sprintf ('%d nonzeros; showing statistics and the first %d', nz, show);
    body = strjoin ({octave_dbg_view('header', val), octave_dbg_view('stats', val), ...
                     octave_dbg_view('entries', val, 1, show)}, "\n");
    return;
  end
  if (isstruct (val) && n == 1)
    % disp of a struct prints every field in full, so a struct with a large
    % field gets the list of its fields instead.
    if (octave_dbg_view ('is_large', val, max_elements))
      note = 'large fields; showing the list of fields';
      body = octave_dbg_view ('fields', val);
    else
      body = disp_text (val);
    end
    return;
  end
  if (n <= max_elements || isobject (val))
    body = disp_text (val);
    return;
  end
  if (ischar (val))
    note = sprintf ('%d characters; showing the first 200', n);
    body = val(1:200);
    return;
  end
  lines = {};
  stats = octave_dbg_view ('stats', val);
  if (! isempty (stats))
    lines{end+1} = stats;
  end
  idx = {1:min(5, rows(val)), 1:min(5, columns(val))};
  idx(end+1:ndims (val)) = {1};
  corner = val(idx{:});
  if (iscell (val) || isstruct (val))
    note = sprintf ('%d elements; showing the first %dx%d', n, size (corner, 1), size (corner, 2));
  else
    note = sprintf ('%d elements; showing statistics and the top-left %dx%d', ...
                    n, size (corner, 1), size (corner, 2));
  end
  lines{end+1} = disp_text (corner);
  body = strjoin (lines, "\n");
end

function txt = disp_text (v)
  % disp output without "Columns 1 through 3:" splits, which come from the
  % terminal width and do not fit a popup. The user's setting is restored.
  old = split_long_rows ();
  unwind_protect
    split_long_rows (false);
    txt = evalc ('disp (v)');
  unwind_protect_cleanup
    split_long_rows (old);
  end_unwind_protect
end
