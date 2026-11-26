% view_dense.m -- manual test for the value viewer: a dense 1000x1000 matrix.
%
% Run this script, put the cursor on M below and press <leader>oV (or run
% :OctaveDbg view M). Try j/k/h/l, <C-d>/<C-u>, gg/G, 0/$ and g (go to, for
% example "500 990"). The hover (<leader>oh) shows a summary; press the hover
% key again to enter the popup, then <CR> to open the viewer.
M = reshape (1:1e6, 1000, 1000) / 7;
M(1, 1) = -42;
