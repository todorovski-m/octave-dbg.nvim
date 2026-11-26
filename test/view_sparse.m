% view_sparse.m -- manual test for the value viewer: a sparse 10000x10000
% matrix with about 3000 nonzeros.
%
% Run this script and open the viewer on S (<leader>oV or :OctaveDbg view S).
% It opens in the nonzero list: "(i, j) -> value" in column-major order. Press
% m for the grid (zeros as dots) and m again for the list; g goes to a row and
% column in both modes. The header must read
% "Compressed Column Sparse (rows = 10000, cols = 10000, nnz = 3000 [0.003%])".
rand ('seed', 1);
S = sprand (10000, 10000, 3e-5);
