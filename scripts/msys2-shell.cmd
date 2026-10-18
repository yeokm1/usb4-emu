@echo off
rem Open a UCRT64 shell from the repo-local MSYS2 toolchain, or run a command in it.
rem Usage: scripts\msys2-shell.cmd            (interactive shell, cwd preserved)
rem        scripts\msys2-shell.cmd <command>  (run command, return its exit code)
setlocal
set "REPO=%~dp0.."
set "MSYSTEM=UCRT64"
set "CHERE_INVOKING=1"
set "MSYS2_PATH_TYPE=minimal"
if not exist "%REPO%\toolchain\msys64\usr\bin\bash.exe" (
  echo toolchain\msys64 is missing. See docs\TOOLCHAIN.md to rebuild it. 1>&2
  exit /b 1
)
if "%~1"=="" (
  "%REPO%\toolchain\msys64\usr\bin\bash.exe" --login -i
) else (
  "%REPO%\toolchain\msys64\usr\bin\bash.exe" --login -c "%*"
)
exit /b %ERRORLEVEL%
