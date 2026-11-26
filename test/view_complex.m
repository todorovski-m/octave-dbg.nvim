% view_complex.m -- manual test for the value viewer: small complex values.
%
% Run this script and open the viewer on Zs (a sparse complex matrix) and on
% Z (a dense one). Press a to switch between real and imaginary parts and
% magnitude and angle in degrees; press m on Zs to switch list and grid. The
% statistics use abs() for complex values.
Zs = sparse ([1 3 4 2], [1 2 4 4], [1+1i, -2i, 3, 2], 4, 4);
Z = [1i, -1, 1-1i; 0.5+2i, 3, -0.25i];
