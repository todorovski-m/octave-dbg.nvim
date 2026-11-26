% view_struct.m -- manual test for the value viewer: a struct with a matrix.
%
% Run this script and open the viewer on st: it lists the fields with their
% size, class and a short value. Open it on st.M (put the cursor on M in
% "st.M" below) to see the matrix field as a grid, and on st.nope to see the
% message for a missing field.
st.M = magic (6);
st.name = 'demo';
st.sub.v = 1:3;
x = st.M;
