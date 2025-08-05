function compile(solvers, mexdir, fortd, gateways, options)
%COMPILE mexifies the Fortran solvers.
% solvers: list of the solvers to mexify
% mexdir: the directory that will contain the mexified solvers
% fortd: the directory containing the source files of the Fortran solvers
% gateways: the directory containing the MEX gateways of the Fortran solvers
% options: some options

% Remarks on the working directory:
% During the compilation, it is important to work in the correct directory. Otherwise, the files can
% be linked mistakenly, leading to runtime errors such as SEGFAULT.
% 1. Each [precision, debug_flag] specifies a version of the common files; they are compiled in
% work_dir = fullfile(directory_of_common_files, pdstr(precision, debug_flag));
% 2. Each [variant, precision, debug_flag] specifies a version of the solver; it is compiled in
% work_dir = fullfile(directory_of_solver_variant, pdstr(precision, debug_flag));
% 3. When compiling the solver corresponding to [variant, precision, debug_flag], we need the
% module and object files in
% common_dir = fullfile(directory_of_common_files, pdstr(precision, debug_flag)).
% 4. All the working directories (i.e., `work_dir`) should be sanitized (i.e., removing the existing
% module and object files) before the compilation.
%
% Remarks on the compilation options -O and -g:
% -O and -g may lead to (slightly) different behaviors of the mexified code. This was observed
% on 2021-09-09 in a test of NEWUOA on the AKIVA problem of CUTEst. It was because the mexified code
% produced different results when it was supposed to evaluate COS(0.59843577329095299_DP) amid OTHER
% CALCULATIONS: with -O, the result was 0.82621783366991353; with -g, it became 0.82621783366991364.
% Bizarrely, if we write a short Fortran program to evaluate only COS(0.59843577329095299_DP),
% then the result is always 0.82621783366991364, regardless of -O or -g. No idea why.


% COMPILE starts

% Directories
cpwd = pwd();  % The current directory, which may not be the directory containing this m file.
% `modern_fortd`: the directory containing the modernized source files of the Fortran solvers
modern_fortd = fortd;
% `classical_fortd`: the directory containing the classical source files of the Fortran solvers
classical_fortd = fullfile(fortd, 'classical');
% `common`: the directory that contains some common source files shared by all the Fortran solvers
common = fullfile(fortd, 'common');

% `options.debug_only` and `options.debug` indicate whether to compile the debugging version of the
% solvers. `debug_only` prevails if both of them are present (e.g., debug_only = true, debug = false).
% `debug_only` is needed only during the development to save compilation time.
if isfield(options, 'debug_only') && islogicalscalar(options.debug_only) && options.debug_only
    debug_flags = {true};
elseif isfield(options, 'debug') && islogicalscalar(options.debug) && options.debug
    debug_flags = {true, false};
else
    debug_flags = {false};  % This is the default: only compile the non-debugging optimized version.
end
precisions = all_precisions();
variants = all_variants();

% `options.verbose` indicates whether to do the compilation in the verbose mode.
verbose = (isfield(options, 'verbose') && islogicalscalar(options.verbose) && options.verbose);
if verbose
    verbose_option = '-v';
else
    verbose_option = '-silent';
end


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% Zaikun 20250720:
% The following code is to circumvent a bug in MATLAB R2025a, which segfaults on Linux when the
% Fortran files contain internal procedures that are passed as actual arguments to other procedures.
% To avoid this bug, we replace gateways/*_mex.F90 with gateways/R2025a/*_mex.F90,
% fortd/cobyla/cobylb.f90 with gateways/R2025a/cobylb.f90, and
% fortd/classical/cobyla/cobyla.f90 with gateways/R2025a/classical_cobyla.f90,
% the latter of which use module variables instead of
% internal procedures. The price is that PRIMA becomes thread-unsafe and recursion-unsafe.
% See MathWorks Technical Support Case 07931486 and
% https://www.mathworks.com/matlabcentral/answers/2178414-bug-matlab-2025a-segfaults-on-ubuntu-when-handling-fortran-mex-files-with-internal-subroutines
% https://stackoverflow.com/questions/79699706/matlab-2025a-vs-fortran-mex-files-with-internal-subroutines
% https://fortran-lang.discourse.group/t/implementation-of-a-parametrized-objective-function-without-using-module-variables-or-internal-subroutines
% https://stackoverflow.com/questions/79705107/fortran-implementating-a-parametrized-objective-function-without-using-module-v

if isunix && ~ismac && verLessThan('matlab', '25.2')  && ~verLessThan('matlab', '25.1')  % The version number of R2025a is 25.1.
    if verbose
        warning('prima_norma:ThreadRecursionUnsafe', ...
            ['MATLAB R2025a has a bug that causes segmentation faults when handling Fortran MEX files with internal procedures.\n', ...
            '         PRIMA is adapted to circumvent this bug but it becomes thread-unsafe and recursion-unsafe.']);
    end
    % Replace the files. N.B.: The .*90 files have become .* after the code refactoring in setup.m.
    replacement_dir = fullfile(gateways, 'R2025a');
    for isol = 1 : length(solvers)
        solver = regexprep(solvers{isol}, '_norma', '');
        copyfile(fullfile(replacement_dir, [solver, '_mex.F']), fullfile(gateways, [solver, '_mex.F']));
        if strcmp(solver, 'cobyla')
            % For COBYLA, we also need to replace the Fortran source file cobylb.f and the classical cobyla.f.
            copyfile(fullfile(replacement_dir, 'cobylb.f'), fullfile(fortd, 'cobyla', 'cobylb.f'));
            copyfile(fullfile(replacement_dir, 'classical_cobyla.f'), fullfile(fortd, 'classical', 'cobyla', 'cobyla.f'));
        end
    end
end
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


% Modify the compiler options by revising FFLAGS or COMPFLAGS.
% See https://www.mathworks.com/help/matlab/ref/mex.html
% 1. We force the Fortran compiler to allocate arrays on the heap instead of the stack. Otherwise,
% the solvers will encounter stack overflow when the problem size is large. As of gfortran 12.0,
% `-fno-stack-arrays` is indeed the default, and we specify it for safety; as of Intel oneAPI
% 2023.1.0, `-no-heap-arrays` is the default, so we must specify `-heap-arrays`.
% N.B.: We assume that the function evaluation is much more expensive than the memory allocation,
% so the performance loss due to the heap allocation is negligible. This is true for derivative-free
% optimization, but may not be true for optimization with derivatives.
% 2. We require the Fortran compiler to compile the solvers so that they can be called recursively.
% Otherwise, the solvers will not work properly in recursive invocations. See
% https://fortran-lang.discourse.group/t/frecursive-assume-recursion-and-recursion-thread-safety
compiler_configurations = mex.getCompilerConfigurations('fortran', 'selected');
extra_compiler_options = '';
compiler_manufacturer = lower(compiler_configurations.Manufacturer);
if contains(compiler_manufacturer, 'gnu')  % gfortran
    % -Wno-missing-include-dirs is needed to suppress the warning about missing include directories
    % when Simulink is not installed.
    extra_compiler_options = '-g -Wno-missing-include-dirs -fno-stack-arrays -frecursive';
elseif contains(compiler_manufacturer, 'intel')  % Intel compiler
    if ispc
        extra_compiler_options = '/Z7 /heap-arrays /assume:recursion';
    else
        extra_compiler_options = '-g -heap-arrays -assume recursion';
    end
elseif contains(compiler_manufacturer, 'nag')  % NAG compiler
    extra_compiler_options = '-g';
else
    warning('prima_norma:UnrecognizedCompiler', 'Unrecognized compiler %s. The package may not work.', ...
        compiler_configurations.Name);
end
if ispc  % Windows
    compiler_options = ['COMPFLAGS="$COMPFLAGS ', extra_compiler_options, '"'];
else
    compiler_options = ['FFLAGS="$FFLAGS ', extra_compiler_options, '"'];
end

% Zaikun 20240216: The following is a workaround for https://github.com/libprima_norma/prima_norma/issues/161,
% where MEX fails due to incompatibility between the new linker of Xcode 15 on macOS and Intel oneAPI 2023.
% The fix is to replace the linker option "-undefined error" with "-undefined dynamic_lookup".
% See also https://github.com/libprima_norma/prima_norma/issues/158.
% Note that we have to modify `LDFLAGSVER`. Setting `LDFLAGS` or `LINKFLAGS` does not work, although
% the latter is suggested at https://www.mathworks.com/help/matlab/ref/mex.html.
linker_options = '';
if ismac && contains(compiler_manufacturer, 'intel')  % macOS with Intel compiler
    linker_options = 'LDFLAGSVER="$LDFLAGSVER -undefined dynamic_lookup"';
end

% MEX options shared by all compiling processes below.
common_mex_options = {verbose_option, compiler_options, linker_options};


% Name of the file that contains the list of Fortran files. There should be such a file in each
% Fortran source code directory, and the list should indicate the dependence among the files.
filelist = 'ffiles.txt';


% Compile the common files. They are shared by all solvers. We compile them only once.
% Common Fortran source files.
common_files = [list_files(common, filelist), fullfile(gateways, 'fmxapi.F'), fullfile(gateways, 'cbfun.F')];

% gateways/debug.F contains debugging subroutines tailored for MEX. It replaces common/debug.F.
copyfile(fullfile(gateways, 'debug.F'), common);

% gateways/fprint.F contains printing subroutines tailored for MEX. It replaces common/fprint.f.
% N.B.: In the following, `delete` should not be called after `copyfile`, or it will not work on
% Windows and macOS. On Windows, it is likely because of the case insensitivity of the file system.
delete(fullfile(common, 'fprint.f'));
copyfile(fullfile(gateways, 'fprint.F'), common);
% Replace "fprint.f" with "fprint.F" in `common_files`.
common_files = replace(common_files, 'fprint.f', 'fprint.F');  % `replace` is available since R2016b.

% common/ppf.h contains preprocessing directives. It is needed only when compiling the common files.
header_file = fullfile(common, 'ppf.h');
header_file_bak = fullfile(common, 'ppf.bak');
copyfile(header_file, header_file_bak);

fprintf('Compiling the common files ... ');
for idbg = 1 : length(debug_flags)
    mex_options = [common_mex_options, {['-', dbgstr(debug_flags{idbg})]}];
    for iprc = 1 : length(precisions)
        prepare_header(header_file, precisions{iprc}, debug_flags{idbg});
        work_dir = fullfile(common, pdstr(precisions{iprc}, debug_flags{idbg}));
        prepare_work_dir(work_dir);
        % Keep a copy of the modified header file in the working directory for debugging purposes.
        % It is NOT used during the compilation. Removing it does not affect the compilation.
        copyfile(header_file, fullfile(work_dir, 'ppf.h'));
        cd(work_dir);
        % We can NOT write the loop below as `mex(mex_options{:}, '-c', common_files{:});`
        % Because such a command may not respect the order of common_files{:}, which is critical here.
        for icf = 1 : length(common_files)
            if verbose
                mex(mex_options{:}, '-c', common_files{icf});
            else
                evalc('mex(mex_options{:}, ''-c'', common_files{icf})');  % Suppress the output.
            end
            % The module/object files are dumped to the current directory, namely `work_dir`.
        end
    end
end
fprintf('Done.\n');


% Compile the solvers.
for isol = 1 : length(solvers)
    solver = regexprep(solvers{isol}, '_norma', '');
    fprintf('Compiling %s ... ', solver);
    gateway = fullfile(gateways, [solver, '_mex.F']);
    for ivar = 1 : length(variants)
        if strcmp(variants{ivar}, 'classical')
            soldir = fullfile(classical_fortd, solver);
        else
            soldir = fullfile(modern_fortd, solver);
        end
        for idbg = 1 : length(debug_flags)
            if strcmp(variants{ivar}, 'classical') && debug_flags{idbg}
                % The support for the classical variant is limited. No debugging version.
                continue
            end
            mex_options = [common_mex_options, {['-', dbgstr(debug_flags{idbg})]}];
            for iprc = 1 : length(precisions)
                work_dir = fullfile(soldir, pdstr(precisions{iprc}, debug_flags{idbg}));
                prepare_work_dir(work_dir);
                common_dir = fullfile(common, pdstr(precisions{iprc}, debug_flags{idbg}));
                copyfiles(list_mod_files(common_dir), work_dir);
                cd(work_dir);
                src_files = list_files(soldir, filelist);
                % We can NOT write the loop below as `mex(mex_options{:}, '-c', common_files{:});`
                % Because such a command may not respect the order of common_files{:}, which is critical here.
                for isf = 1 : length(src_files)
                    if verbose
                        mex(mex_options{:}, '-c', src_files{isf});
                    else
                        evalc('mex(mex_options{:}, ''-c'', src_files{isf})');  % Suppress the output.
                    end
                    % The module/object files are dumped to the current directory, namely `work_dir`.
                end
                obj_files = [list_obj_files(common_dir), list_obj_files(work_dir)];
                mexname = get_mexname(solvers{isol}, precisions{iprc}, debug_flags{idbg}, variants{ivar});
                if verbose
                    mex(mex_options{:}, obj_files{:}, gateway, '-output', mexname, '-outdir', mexdir);
                else
                    evalc('mex(mex_options{:}, obj_files{:}, gateway, ''-output'', mexname, ''-outdir'', mexdir)');  % Suppress the output.
                end
                % On macOS, .o files are produced in `mexdir`. Remove them.
                cellfun(@(filename) delete(filename), list_modo_files(mexdir));
            end
        end
    end
    fprintf('Done.\n');
end


% Restore header_file.
if exist(header_file_bak, 'file')
    movefile(header_file_bak, header_file);
end

cd(cpwd);  % Go back to `cpwd`.


% COMPILE ends
return


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


function files = list_files(directory, filelist)
%LIST_FILES lists the files in `directory` according to `filelist`, which should be a plain text
% file under `directory`.

files = regexp(fileread(fullfile(directory, filelist)), '\n', 'split');
files = strtrim(files(~cellfun(@isempty, files)));
files = fullfile(directory, files);

% LIST_FILES ends
return


function prepare_header(header_file, precision, debug_flag)
%PREPARE_HEADER prepares `header_file` for the compilation according to `precision` and `debug_flag`.

switch precision
case {'h', 'half'}
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 32', '#define PRIMA_REAL_PRECISION 16');
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 64', '#define PRIMA_REAL_PRECISION 16');
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 128', '#define PRIMA_REAL_PRECISION 16');
    rep_str(header_file, '#define PRIMA_HP_AVAILABLE 0', '#define PRIMA_HP_AVAILABLE 1');
    rep_str(header_file, '#define PRIMA_QP_AVAILABLE 1', '#define PRIMA_QP_AVAILABLE 0');
case {'s', 'single'}
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 16', '#define PRIMA_REAL_PRECISION 32');
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 64', '#define PRIMA_REAL_PRECISION 32');
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 128', '#define PRIMA_REAL_PRECISION 32');
    rep_str(header_file, '#define PRIMA_HP_AVAILABLE 1', '#define PRIMA_HP_AVAILABLE 0');
    rep_str(header_file, '#define PRIMA_QP_AVAILABLE 1', '#define PRIMA_QP_AVAILABLE 0');
case {'q', 'quadruple'}
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 16', '#define PRIMA_REAL_PRECISION 128');
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 32', '#define PRIMA_REAL_PRECISION 128');
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 64', '#define PRIMA_REAL_PRECISION 128');
    rep_str(header_file, '#define PRIMA_HP_AVAILABLE 1', '#define PRIMA_HP_AVAILABLE 0');
    rep_str(header_file, '#define PRIMA_QP_AVAILABLE 0', '#define PRIMA_QP_AVAILABLE 1');
otherwise
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 16', '#define PRIMA_REAL_PRECISION 64');
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 32', '#define PRIMA_REAL_PRECISION 64');
    rep_str(header_file, '#define PRIMA_REAL_PRECISION 128', '#define PRIMA_REAL_PRECISION 64');
    rep_str(header_file, '#define PRIMA_HP_AVAILABLE 1', '#define PRIMA_HP_AVAILABLE 0');
    rep_str(header_file, '#define PRIMA_QP_AVAILABLE 1', '#define PRIMA_QP_AVAILABLE 0');
end

if debug_flag
    rep_str(header_file, '#define PRIMA_DEBUGGING 0', '#define PRIMA_DEBUGGING 1');
else
    rep_str(header_file, '#define PRIMA_DEBUGGING 1', '#define PRIMA_DEBUGGING 0');
end

% PREPARE_HEADER ends
return


function s = pdstr(precision, debug_flag)
%PDSTR returns a string according to `precision` and `debug_flag`.
s = [precision(1), dbgstr(debug_flag)];
% PDSTR ends
return


function prepare_work_dir(directory)
%PREPARE_WORKDIR prepares `directory` for the compilation: if it does not exist, create it;
% otherwise, clean it up.
if exist(directory, 'dir')
    % Clean up `directory` so that it is proper for the compilation. Without doing this, files may
    % be linked mistakenly, leading to runtime errors such as SEGFAULT.
    cellfun(@(filename) delete(filename), list_modo_files(directory));
else
    mkdir(directory);
end
% PREPARE_WORKDIR ends
return


function mod_files = list_mod_files(dir_name)
%LIST_MOD_FILES lists all module files (*.mod) in a directory

mod_files = files_with_wildcard(dir_name, '*.mod');

return


function obj_files = list_obj_files(dir_name)
%LIST_OBJ_FILES lists all object files (*.o, *.obj) in a directory

obj_files = [files_with_wildcard(dir_name, '*.o'), files_with_wildcard(dir_name, '*.obj')];

return


function modo_files = list_modo_files(dir_name)
%LIST_MODO_FILES lists all module or object files in a directory

modo_files = [list_mod_files(dir_name), list_obj_files(dir_name)];

return
