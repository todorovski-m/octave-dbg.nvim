function y = my_fun (x)
  % my_fun -- doubles x; uses x = 5 when called without arguments
  if (nargin < 1)
    x = 5;
  end
  y = 2 * x;
  printf ('my_fun: x = %g, y = %g\n', x, y);
end
