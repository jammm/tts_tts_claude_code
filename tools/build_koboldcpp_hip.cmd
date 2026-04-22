@echo off
REM Build koboldcpp with HIP/HIPBLAS on Windows. Default target is
REM gfx1201 (Navi 48 / RX 9070 XT), override with GFX_TARGET — e.g.
REM `set GFX_TARGET=gfx1150 && tools\build_koboldcpp_hip.cmd clean` for
REM a Strix Halo deployment build (RDNA 3.5 iGPU). Multiple targets
REM are allowed as a semicolon-separated list (CMake convention), e.g.
REM `set GFX_TARGET=gfx1150;gfx1201` for a fat binary covering both
REM Strix Halo and discrete RDNA 4.
REM
REM koboldcpp is a llama.cpp fork with TTS/STT support including Kokoro,
REM Qwen3TTS, OuteTTS, Parler, Dia, Whisper. Output: koboldcpp_hipblas
REM .dll plus the koboldcpp.py launcher staged into
REM vendor/koboldcpp-rocm/.
REM
REM Inputs:
REM   KOBOLD_SRC      default %~dp0..\deps\koboldcpp
REM   KOBOLD_BUILD    default %KOBOLD_SRC%\build-rocm
REM   VENV_ROOT       default %~dp0..\.venv  (must contain rocm-sdk-devel)
REM   STAGE_DIR       default %~dp0..\vendor\koboldcpp-rocm
REM   GFX_TARGET      default gfx1201        (any HIP arch)

setlocal enabledelayedexpansion

if not defined KOBOLD_SRC   set "KOBOLD_SRC=%~dp0..\deps\koboldcpp"
if not defined KOBOLD_BUILD set "KOBOLD_BUILD=%KOBOLD_SRC%\build-rocm"
if not defined VENV_ROOT    set "VENV_ROOT=%~dp0..\.venv"
if not defined STAGE_DIR    set "STAGE_DIR=%~dp0..\vendor\koboldcpp-rocm"
if not defined GFX_TARGET   set "GFX_TARGET=gfx1201"

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

REM --- 3. Clean any prior build --------------------------------------------
if "%1"=="clean" (
    echo [build] cleaning %KOBOLD_BUILD%
    rmdir /s /q "%KOBOLD_BUILD%" 2>nul
    shift
)

REM --- 4. Configure ---------------------------------------------------------
REM Use clang++.exe (GNU driver) instead of amdclang-cl.exe (MSVC driver).
REM koboldcpp's HIP build uses `-xhip` + CMake LANGUAGE CXX on .cu files
REM which confuses clang-cl into naming intermediate offload-bundler
REM inputs '*.exe' (MSVC-style exe naming) instead of '*.o'. The GNU
REM driver produces the expected '*.o' and the HIP toolchain is happy.
echo [build] configuring at %KOBOLD_BUILD% for GFX_TARGET=%GFX_TARGET%
REM BUILD_SHARED_LIBS omitted on purpose: koboldcpp's CMake links targets
REM like common2 -> ggml but NOT common2 -> llama-impl, relying on the
REM final koboldcpp_hipblas.dll link step to pull all unresolved symbols
REM together. With shared libs, each intermediate .dll must resolve all
REM its symbols, and common2 fails with undefined: llama_model_load_from_
REM file etc. (gpttype_adapter does `#include "src/llama.cpp"` directly,
REM so llama_* symbols live only there). Static libs defer symbol
REM resolution until the final DLL link, which is exactly what we want.
cmake -S "%KOBOLD_SRC%" -B "%KOBOLD_BUILD%" -G Ninja ^
  -DCMAKE_BUILD_TYPE=Release ^
  -DCMAKE_C_COMPILER="%ROCM_ROOT%\lib\llvm\bin\clang.exe" ^
  -DCMAKE_CXX_COMPILER="%ROCM_ROOT%\lib\llvm\bin\clang++.exe" ^
  -DCMAKE_PREFIX_PATH="%ROCM_ROOT%\lib\cmake;%ROCM_ROOT%" ^
  -DLLAMA_HIPBLAS=ON ^
  -DAMDGPU_TARGETS=%GFX_TARGET% ^
  -DGPU_TARGETS=%GFX_TARGET% ^
  -DCMAKE_HIP_ARCHITECTURES=%GFX_TARGET%
if errorlevel 1 (
    echo [build] configure failed
    exit /b 1
)

REM --- 5. Build koboldcpp_hipblas.dll --------------------------------------
echo [build] compiling koboldcpp_hipblas (long build — thousands of HIP kernel TUs)
cmake --build "%KOBOLD_BUILD%" --target koboldcpp_hipblas --config Release -j
if errorlevel 1 (
    echo [build] build failed
    exit /b 1
)

REM --- 6. Stage outputs ----------------------------------------------------
REM koboldcpp.py expects its runtime DLL + any embd_res assets to live
REM alongside itself, so stage everything into %STAGE_DIR%.
echo.
echo [build] staging to %STAGE_DIR%
if not exist "%STAGE_DIR%" mkdir "%STAGE_DIR%"

copy /Y "%KOBOLD_BUILD%\bin\koboldcpp_hipblas.dll" "%STAGE_DIR%\" >nul
copy /Y "%KOBOLD_SRC%\koboldcpp.py" "%STAGE_DIR%\" >nul
REM Our ROCm-aware python wrapper (registers rocm-sdk-devel/bin as a
REM DLL search path before importing koboldcpp). Tracked in tools/ so
REM it doesn't get nuked if someone wipes vendor/.
copy /Y "%~dp0launch_kobold_rocm.py" "%STAGE_DIR%\" >nul
for %%F in (json_to_gbnf.py klite.embd kcpp_docs.embd kcpp_sdui.embd) do (
    if exist "%KOBOLD_SRC%\%%F" copy /Y "%KOBOLD_SRC%\%%F" "%STAGE_DIR%\" >nul
)
for %%D in (kcpp_adapters lib embd_res) do (
    if exist "%KOBOLD_SRC%\%%D" xcopy /E /Y /Q /I "%KOBOLD_SRC%\%%D" "%STAGE_DIR%\%%D" >nul
)

echo.
echo [build] done. Staged:
if exist "%STAGE_DIR%\koboldcpp_hipblas.dll" echo    "%STAGE_DIR%\koboldcpp_hipblas.dll"
if exist "%STAGE_DIR%\koboldcpp.py"          echo    "%STAGE_DIR%\koboldcpp.py"

endlocal
