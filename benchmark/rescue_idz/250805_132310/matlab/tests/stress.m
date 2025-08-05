function stress(solver, options)
%STRESS test of a solver on excessively large problems that the solver is NOT designed for.
% N.B.: When the dimension is beyond some limit, the MEX function will crash due to memory violations.
% However, the limit for each solver is much higher than the size of problems that it is designed to
% solve. To achieve this, we have to force the MEX function to use the heap instead of the stack for
% automatic arrays. This is done by the following compilation options:
% gfortran on Linux: -fno-stack-arrays
% Intel compiler on macOS: -heap-arrays
% Intel compiler on Windows: /heap-arrays
% As of gfortran 12.0, `-fno-stack-arrays` is indeed the default, and we specify it for safety; as
% of Intel oneAPI 2023.1.0, `-no-heap-arrays` is the default, so we must specify `-heap-arrays`.
% N.B.: We assume that the function evaluation is much more expensive than the memory allocation,
% so the performance loss due to the heap allocation is negligible. This is true for derivative-free
% optimization, but may not be true for optimization with derivatives.
% See matlab/setup_tools/compile.m for details.

% Turn off unwanted warnings
orig_warning_state = warnoff({solver});

if nargin < 2
    options = struct();
end

% Set the random seed. We ALTER THE SEED WEEKLY to test the solvers as much as possible.
if isfield(options, 'yw')
    yw = options.yw;
elseif isfield(options, 'seed')
    yw = options.seed;
else
    yw = year_week('Asia/Shanghai');
end
fprintf('\nThe seed is\t\t%d\n\n', yw);
% Define the random seed by yw
random_seed = yw;
orig_rng_state = rng();  % Save the current random number generator settings
rng(random_seed);

% Whether to conduct a TOUGH test
tough_test = isfield(options, 'tough') && options.tough;

% Which precision to test
precision = 'double';
if isfield(options, 'precision') && ischarstr(options.precision)
    precision = options.precision;
end
if strcmpi(precision, 'date')  % Use the date to determine the precision
    daynum = day(datetime('now', 'TimeZone', 'Asia/Shanghai'));
    if half_precision_available()
        if mod(daynum, 4) == 0
            options.precision = 'half';
        elseif mod(daynum, 4) == 1
            options.precision = 'single';
        elseif mod(daynum, 4) == 2
            options.precision = 'double';
        else
            options.precision = 'quadruple';
        end
    else
        if mod(daynum, 3) == 0
            options.precision = 'single';
        elseif mod(daynum, 3) == 1
            options.precision = 'double';
        else
            options.precision = 'quadruple';
        end
    end
end

% Set up the solver
if ~isfield(options, 'compile') || options.compile
    old_directory = pwd();
    cd(fileparts(fileparts(fileparts(mfilename('fullpath')))));
    compile_options = struct();
    compile_options.verbose = false;
    compile_options.debug = (rand() < 0.5);
    compile_options.half = strcmpi(precision, 'half');
    compile_options.single = strcmpi(precision, 'single');
    compile_options.quadruple = strcmpi(precision, 'quadruple');
    compile_options.classical = false;
    setup(solver, compile_options);
    cd(old_directory);
end
solver_name = solver;
solver = str2func(solver);

% Set the dimension of the problem
if isfield(options, 'n')
    n = options.n;
else
    if tough_test
        switch solver_name
        case 'uobyqa'
            n = 150; % UOBYQA crashes if n > 200
        case 'newuoa'
            n = 1600;
        case 'bobyqa'
            n = 1600;
        case 'lincoa'
            n = 1000;
        case 'cobyla'
            n = 800;
        end
    else
        switch solver_name
        case 'uobyqa'
            n = 100; % UOBYQA crashes if n > 200
        case 'newuoa'
            n = 800;
        case 'bobyqa'
            n = 800;
        case 'lincoa'
            n = 500;
        case 'cobyla'
            n = 400;
        end
    end
end

% Set the type of the problem
switch solver_name
case {'uobyqa', 'newuoa'}
    problem_type = 'u';
case 'bobyqa'
    problem_type = 'b';
case 'lincoa'
    problem_type = 'l';
case 'cobyla'
    problem_type = 'n';
end

% Set the options for the solver
solver_options = struct();
solver_options.precision = precision;
solver_options.maxfun = 500 * n;
solver_options.rhobeg = 1;
solver_options.rhoend = 1.0e-7;
solver_options.iprint = 2;
solver_options.debug = (rand() < 0.5);
fprintf('\n>>>>>> solver_options =');
solver_options

% Generate the problem
problem = stress_problem(n, problem_type, random_seed);
problem.options = solver_options;
original_problem = problem;
if tough_test
    problem = tough(original_problem, random_seed);
end

% Conduct the test
if tough_test
    fprintf('\n>>>>>> TOUGH test for %s starts <<<<<<\n', solver_name);
else
    fprintf('\n>>>>>> Test for %s starts <<<<<<\n', solver_name);
end

tic;
% For TOUGH tests, cobyla raises an error if the constraint evaluation fails at the starting point.
% In that case, we modify the random seed and redo the test.
redo = true;
while redo
    exception = [];
    try
        [x, fx, exitflag, output] = solver(problem)
    catch exception
    end
    if isempty(exception) || ~tough_test || ~strcmp(solver_name, 'cobyla')
        redo = false;
    else
        redo = strcmp(exception.identifier, 'cobyla:ConstraintFailureAtX0');
        if redo
            random_seed = random_seed + 1;
            problem = tough(original_problem, random_seed);
        end
    end
end
toc;

% Restore the random number generator state
rng(orig_rng_state);
% Restore the behavior of displaying warnings
warning(orig_warning_state);

if ~isempty(exception)
    rethrow(exception);
end

if tough_test
    fprintf('\n>>>>>> TOUGH test for %s ends <<<<<<\n', solver_name);
else
    fprintf('\n>>>>>> Test for %s ends <<<<<<\n', solver_name);
end


return
