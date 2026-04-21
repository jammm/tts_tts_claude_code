@echo off
REM Build the Lemonade C++ server (lemond + lemonade CLI) on Windows.
REM
REM Inputs:
REM   LEMONADE_SRC     default deps\lemonade
REM   LEMONADE_BUILD   default %LEMONADE_SRC%\build
REM   STAGE_DIR        default vendor\lemonade-cpp   (copied outputs)
REM
REM Prereqs:
REM   - Visual Studio 2022 (vcvars64.bat must exist)
REM   - CMake 3.28+
REM   - git (FetchContent pulls deps on first configure)

setlocal enabledelayedexpansion

if not defined LEMONADE_SRC   set "LEMONADE_SRC=%~dp0..\deps\lemonade"
if not defined LEMONADE_BUILD set "LEMONADE_BUILD=%LEMONADE_SRC%\build"
if not defined STAGE_DIR      set "STAGE_DIR=%~dp0..\vendor\lemonade-cpp"

REM --- 1. Load VS 2022 x64 environment -------------------------------------
set "VS_VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VS_VCVARS%" (
    echo [build] vcvars64.bat not found at %VS_VCVARS%
    exit /b 1
)
echo [build] loading vcvars64...
call "%VS_VCVARS%" >nul
if errorlevel 1 exit /b 1

REM --- 2. Clean ------------------------------------------------------------
if "%1"=="clean" (
    echo [build] cleaning %LEMONADE_BUILD%
    rmdir /s /q "%LEMONADE_BUILD%" 2>nul
    shift
)

REM --- 3. Configure -------------------------------------------------------
REM CMAKE_SYSTEM_VERSION=10.0.26100.0 works around a cpp-httplib check that
REM misreads recent Windows 11 builds as Windows 8.
echo [build] configuring %LEMONADE_SRC%
cmake -S "%LEMONADE_SRC%" -B "%LEMONADE_BUILD%" ^
  -G "Visual Studio 17 2022" -A x64 ^
  -DCMAKE_SYSTEM_VERSION="10.0.26100.0"
if errorlevel 1 (
    echo [build] configure failed
    exit /b 1
)

REM --- 4. Build ------------------------------------------------------------
echo [build] building lemond + lemonade CLI
cmake --build "%LEMONADE_BUILD%" --config Release --target lemond lemonade -j
if errorlevel 1 (
    echo [build] build failed
    exit /b 1
)

REM --- 5. Stage -----------------------------------------------------------
echo [build] staging to %STAGE_DIR%
if not exist "%STAGE_DIR%" mkdir "%STAGE_DIR%"
xcopy /E /Y /Q /I "%LEMONADE_BUILD%\Release\*" "%STAGE_DIR%" >nul

echo.
echo [build] done. Staged:
for %%F in ("%STAGE_DIR%\lemond.exe" "%STAGE_DIR%\lemonade.exe") do (
    if exist %%F echo    %%F
)
if exist "%STAGE_DIR%\resources" echo    %STAGE_DIR%\resources\

endlocal
