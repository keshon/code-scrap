@echo off
rem Builds the scrap server and opens the GDScript viewer on a repository.
rem
rem   build-n-run.bat                 map this repo (code-scrap itself)
rem   build-n-run.bat D:\path\to\repo map another repo
rem
rem Override the Godot executable with the GODOT environment variable.

setlocal
set "ROOT=%~dp0"
set "ROOT=%ROOT:~0,-1%"
if "%GODOT%"=="" set "GODOT=E:\Programs\godot\Godot_v4.7.1-stable_win64.exe"

set "REPO=%~1"
if "%REPO%"=="" set "REPO=%ROOT%"
if not exist "%REPO%\" (
    echo Repository folder not found: %REPO%
    exit /b 1
)
if not exist "%GODOT%" (
    echo Godot not found: %GODOT%
    echo Set the GODOT environment variable to your Godot 4.7 executable.
    exit /b 1
)

echo [1/3] Building scrap...
pushd "%ROOT%\scrap"
go build -o bin\scrap.exe .\cmd\scrap
if errorlevel 1 (
    popd
    echo Build failed.
    exit /b 1
)
popd

if not exist "%ROOT%\viewer-gd\.godot\" (
    echo [2/3] Importing Godot project ^(first run^)...
    "%GODOT%" --headless --path "%ROOT%\viewer-gd" --import >nul 2>&1
) else (
    echo [2/3] Godot project already imported.
)

echo [3/3] Starting viewer on %REPO%
rem The viewer launches "scrap serve" itself and stops it on exit.
start "" "%GODOT%" --path "%ROOT%\viewer-gd" -- "--repo=%REPO%" "--scrap=%ROOT%\scrap\bin\scrap.exe"
endlocal
