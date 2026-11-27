% main.m -- manual test for the main script (:OctaveDbg main).
%
% This script calls my_fun (in this folder) and helper (in lib/).
%
% 1. Open this file and run :OctaveDbg main.
% 2. Open my_fun.m, put a breakpoint on line 6 (F12 or <leader>ob) and press
%    F5 there: this script runs and stops in my_fun at line 6. F5 again
%    continues and prints "main: r = 6, q = 106".
% 3. Change a comment in my_fun.m without saving and press F5 again: only
%    my_fun.m is saved (this file keeps its modification time), and the
%    breakpoint still stops.
% 4. In my_fun.m, press <leader>oF: my_fun runs alone with its default
%    x = 5 and shows "ans = 10".
% 5. Open lib/helper.m and press Ctrl+F10 on line 2: this script runs and
%    stops there.
% 6. :OctaveDbg status shows the main script; :OctaveDbg main clear forgets
%    it. Without a main script, F5 in my_fun.m runs my_fun with x = 5.
addpath (fullfile (fileparts (mfilename ('fullpath')), 'lib'));
r = my_fun (3);
q = helper (r);
printf ('main: r = %g, q = %g\n', r, q);
