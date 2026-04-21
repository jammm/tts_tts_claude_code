@echo off
REM Build whisper.cpp with HIP on Windows targeting gfx1201 (Navi 48 / RX 9070 XT).
REM Runs inside a VS 2022 x64 developer environment + TheRock ROCm toolchain.
REM
REM Inputs:
REM   WHISPER_SRC     default d:\jam\whisper.cpp
REM   WHISPER_BUILD   default %WHISPER_SRC%\build-rocm
REM   VENV_ROOT       default d:\jam\demos\.venv        (must contain rocm-sdk-devel)

setlocal enabledelayedexpansion

if not defined WHISPER_SRC   set "WHISPER_SRC=%~dp0..\deps\whisper.cpp"
if not defined LLAMA_SRC     set "LLAMA_SRC=%~dp0..\deps\llama.cpp"
if not defined WHISPER_BUILD set "WHISPER_BUILD=%WHISPER_SRC%\build-rocm"
if not defined VENV_ROOT     set "VENV_ROOT=%~dp0..\.venv"
if not defined STAGE_DIR     set "STAGE_DIR=%~dp0..\vendor\whisper-cpp-rocm"

REM --- 1. Load VS 2022 x64 environment -------------------------------------
set "VS_VCVARS=C:\Program Files\Microsoft Visual Studio\2022\Community\VC\Auxiliary\Build\vcvars64.bat"
if not exist "%VS_VCVARS%" (
    echo [build] vcvars64.bat not found at %VS_VCVARS%
    exit /b 1
)
echo [build] loading vcvars64...
call "%VS_VCVARS%" >nul
if errorlevel 1 exit /b 1

REM --- 2. Locate TheRock ROCm SDK ------------------------------------------
set "ROCM_ROOT=%VENV_ROOT%\Lib\site-packages\_rocm_sdk_devel"
if not exist "%ROCM_ROOT%\bin\hipcc.exe" (
    echo [build] rocm-sdk-devel not found. Run: rocm-sdk init
    exit /b 1
)
echo [build] ROCM_ROOT=%ROCM_ROOT%

set "HIP_PATH=%ROCM_ROOT%"
set "HIP_PLATFORM=amd"
set "HIP_CLANG_PATH=%ROCM_ROOT%\lib\llvm\bin"
set "CMAKE_PREFIX_PATH=%ROCM_ROOT%\lib\cmake;%ROCM_ROOT%"
set "PATH=%ROCM_ROOT%\bin;%ROCM_ROOT%\lib\llvm\bin;%PATH%"

echo [build] hipconfig:
call "%ROCM_ROOT%\bin\hipconfig.bat" --version 2>nul

REM --- 3. Clean any prior build --------------------------------------------
if "%1"=="clean" (
    echo [build] cleaning %WHISPER_BUILD%
    rmdir /s /q "%WHISPER_BUILD%" 2>nul
    shift
)

REM --- 3b. Overlay latest ggml from llama.cpp onto whisper.cpp -------------
REM whisper.cpp syncs ggml from a standalone repo at a slower cadence than
REM llama.cpp does. The ggml-cuda/ggml-hip backends inside whisper.cpp
REM therefore lag behind, which can manifest as missing gfx1201 / RDNA4
REM code paths. We overwrite the whisper copy with llama.cpp's at build time
REM so the HIP backend code is current. Nothing in the whisper.cpp repo
REM itself is committed back — the overlay is a pure build-time action.
if exist "%LLAMA_SRC%\ggml" (
    if exist "%WHISPER_SRC%\ggml" (
        echo [build] overlaying ggml from %LLAMA_SRC% onto %WHISPER_SRC%
        xcopy /E /Y /Q /I "%LLAMA_SRC%\ggml" "%WHISPER_SRC%\ggml" >nul
    )
)

REM --- 4. Configure ---------------------------------------------------------
echo [build] configuring at %WHISPER_BUILD%
cmake -S "%WHISPER_SRC%" -B "%WHISPER_BUILD%" -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER="%ROCM_ROOT%\lib\llvm\bin\amdclang-cl.exe" ^
  -DCMAKE_CXX_COMPILER="%ROCM_ROOT%\lib\llvm\bin\amdclang-cl.exe" ^
  -DCMAKE_PREFIX_PATH="%ROCM_ROOT%\lib\cmake;%ROCM_ROOT%" ^
  -DGGML_HIP=ON ^
  -DGGML_HIP_ROCWMMA_FATTN=OFF ^
  -DAMDGPU_TARGETS=gfx1201 ^
  -DGPU_TARGETS=gfx1201 ^
  -DCMAKE_HIP_ARCHITECTURES=gfx1201 ^
  -DWHISPER_BUILD_EXAMPLES=ON ^
  -DWHISPER_BUILD_SERVER=ON ^
  -DWHISPER_BUILD_TESTS=OFF
if errorlevel 1 (
    echo [build] configure failed
    exit /b 1
)

REM --- 5. Build -------------------------------------------------------------
echo [build] compiling (whisper-server + whisper-cli)
cmake --build "%WHISPER_BUILD%" --target whisper-server whisper-cli -j
if errorlevel 1 (
    echo [build] build failed
    exit /b 1
)

echo.
echo [build] staging binaries + runtime DLLs to %STAGE_DIR%
if not exist "%STAGE_DIR%" mkdir "%STAGE_DIR%"
xcopy /E /Y /Q /I "%WHISPER_BUILD%\bin\*" "%STAGE_DIR%" >nul

echo.
echo [build] done. Staged:
for %%F in ("%STAGE_DIR%\whisper-server.exe" "%STAGE_DIR%\whisper-cli.exe" "%STAGE_DIR%\ggml-hip.dll") do (
    if exist %%F (
        echo    %%F
    )
)

endlocal
