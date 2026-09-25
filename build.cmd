@echo off
rem ---------------------------------------------------------------------------
rem  code-scrap build helper.
rem
rem    build                      build the scrap server
rem    build run [repo]           build, then open the viewer on a repository
rem                               (no repo given = this one)
rem    build serve [repo] [addr]  build, then run the server in this console
rem    build test [pattern]       go vet and go test (pattern = -run filter)
rem    build shot out.png [viewer args ...]
rem                               scripted viewer run: opens on a port of its
rem                               own, saves a screenshot and quits
rem    build dist                 package a release into dist\
rem    build import               import the Godot project (first run)
rem    build clean                remove bin\, dist\ and the Godot import cache
rem    build stop                 stop any scrap server left running
rem
rem  Set GODOT to your Godot 4.7 executable to override the path below. The
rem  console build of the same editor, if it sits beside it, is used for the
rem  headless work so its output lands in this window.
rem
rem  Messages are English and this file is plain ASCII on purpose: cmd reads a
rem  UTF-8 BOM as three characters of the first line, "@echo off" then fails as
rem  an unknown command, and every line after it is echoed to the console.
rem ---------------------------------------------------------------------------
setlocal
cd /d "%~dp0"
set "ROOT=%CD%"
set "SCRAP=%ROOT%\scrap\bin\scrap.exe"

if "%GODOT%"=="" set "GODOT=E:\Programs\godot\Godot_v4.7.1-stable_win64.exe"
set "GODOT_C=%GODOT:.exe=_console.exe%"
if not exist "%GODOT_C%" set "GODOT_C=%GODOT%"

set "MODE=%~1"
if "%MODE%"=="" set "MODE=build"

where go >nul 2>nul
if errorlevel 1 (
    echo ERROR: go was not found. Install Go 1.26 or newer first.
    exit /b 1
)

if /i "%MODE%"=="build"  goto :build
if /i "%MODE%"=="run"    goto :run
if /i "%MODE%"=="serve"  goto :serve
if /i "%MODE%"=="test"   goto :test
if /i "%MODE%"=="shot"   goto :shot
if /i "%MODE%"=="dist"   goto :dist
if /i "%MODE%"=="import" goto :import
if /i "%MODE%"=="clean"  goto :clean
if /i "%MODE%"=="stop"   goto :stop_command

echo ERROR: unknown mode "%MODE%".
echo Use: build ^| run ^| serve ^| test ^| shot ^| dist ^| import ^| clean ^| stop
exit /b 1

rem ---------------------------------------------------------------------------
:build
call :build_scrap
if errorlevel 1 exit /b 1
echo Done: %SCRAP%
exit /b 0

:build_scrap
echo Building scrap...
pushd "%ROOT%\scrap"
go build -o bin\scrap.exe .\cmd\scrap
set "RC=%errorlevel%"
popd
if not "%RC%"=="0" echo Build failed.
exit /b %RC%

rem ---------------------------------------------------------------------------
rem  Open the viewer on a repository. It starts "scrap serve" itself and stops
rem  it again on exit, so this only has to hand it the two paths.
rem ---------------------------------------------------------------------------
:run
call :build_scrap
if errorlevel 1 exit /b 1
call :repo_arg "%~2"
if errorlevel 1 exit /b 1
call :import_once
echo Starting the viewer on %REPO%
start "" "%GODOT%" --path "%ROOT%\viewer-gd" -- "--repo=%REPO%" "--scrap=%SCRAP%"
exit /b 0

rem ---------------------------------------------------------------------------
rem  The server on its own, in this console: for reading its log, or for
rem  keeping one index alive while viewers come and go.
rem ---------------------------------------------------------------------------
:serve
call :build_scrap
if errorlevel 1 exit /b 1
call :repo_arg "%~2"
if errorlevel 1 exit /b 1
set "ADDR=%~3"
if "%ADDR%"=="" set "ADDR=127.0.0.1:7878"
echo Serving %REPO% on ws://%ADDR%/ws  (Ctrl+C to stop)
"%SCRAP%" serve -addr %ADDR% "%REPO%"
exit /b %errorlevel%

rem ---------------------------------------------------------------------------
:test
echo Vetting...
pushd "%ROOT%\scrap"
go vet ./...
if errorlevel 1 (
    popd
    exit /b 1
)
if "%~2"=="" (
    echo Running tests...
    go test ./... -count=1
) else (
    echo Running tests matching %~2 ...
    go test ./... -count=1 -run "%~2"
)
set "RC=%errorlevel%"
popd
exit /b %RC%

rem ---------------------------------------------------------------------------
rem  A scripted viewer run: it selects, flies, screenshots and quits, which is
rem  how a visual change gets checked without clicking through the app. See
rem  viewer-gd/scripts/test_driver.gd for the flags it takes.
rem
rem  Port 7899, never 7878: the run sends its --set options to whatever server
rem  it connects to, so it must not land on the one a viewer of yours is on.
rem ---------------------------------------------------------------------------
:shot
if "%~2"=="" (
    echo ERROR: build shot needs an output file, e.g. build shot out.png --wait=12
    exit /b 1
)
call :build_scrap
if errorlevel 1 exit /b 1
set "OUT=%~2"
rem  The rest of the line comes from %* and not from shifting %1, because cmd
rem  splits an argument on "=" as readily as on a space: --wait=12 arrives as
rem  two arguments and would be handed on as "--wait 12", which the viewer
rem  reads as a flag with no value. %* keeps the line as it was typed, so we
rem  only cut the mode and the file name off the front of it.
set "ARGS=%*"
call set "REST=%%ARGS:*%2=%%"
rem  A cold index needs longer than the driver's own default of four seconds,
rem  and a screenshot taken too early shows an empty map and reads as a bug.
echo %REST% | find "--wait" >nul
if errorlevel 1 set "REST=%REST% --wait=14"
echo Shooting %OUT% ...
"%GODOT_C%" --path "%ROOT%\viewer-gd" -- "--url=ws://127.0.0.1:7899/ws" "--repo=%ROOT%" "--scrap=%SCRAP%" "--shot=%OUT%"%REST%
exit /b %errorlevel%

rem ---------------------------------------------------------------------------
rem  A folder anyone can copy and run: the viewer, the server it starts, and
rem  the config it reads (themes, keymaps, presets, the settings schema).
rem ---------------------------------------------------------------------------
:dist
rem  Templates first, before anything is deleted: they are a one-time ~1 GB
rem  download and their absence is the usual reason an export fails, so name
rem  the folder that is missing instead of letting Godot fail four steps on.
for /f "tokens=1-4 delims=." %%a in ('""%GODOT_C%" --version"') do set "GV=%%a.%%b.%%c.%%d"
if not exist "%APPDATA%\Godot\export_templates\%GV%\" (
    echo ERROR: no export templates for Godot %GV%, so the viewer cannot be
    echo exported. They are expected in:
    echo    %APPDATA%\Godot\export_templates\%GV%\
    echo In the editor: Editor - Manage Export Templates - Download and Install.
    exit /b 1
)
call :build_scrap
if errorlevel 1 exit /b 1
if exist "%ROOT%\dist" (
    echo Cleaning dist\ ...
    rmdir /s /q "%ROOT%\dist"
)
mkdir "%ROOT%\dist"
if not exist "%ROOT%\viewer-gd\export_presets.cfg" call :write_preset
call :import_once
echo Exporting the viewer for Godot %GV% ...
"%GODOT_C%" --headless --path "%ROOT%\viewer-gd" --export-release "Windows Desktop" "%ROOT%\dist\code-scrap.exe"
if errorlevel 1 (
    echo ERROR: the viewer did not export. Read the lines above: if the
    echo preset is at fault, open viewer-gd in the editor and fix it
    echo under Project - Export.
    exit /b 1
)
copy /y "%SCRAP%" "%ROOT%\dist\scrap.exe" >nul
xcopy /e /i /q /y "%ROOT%\config" "%ROOT%\dist\config" >nul
copy /y "%ROOT%\README.md" "%ROOT%\dist\" >nul
echo.
echo Done: dist\code-scrap.exe
echo It opens a folder picker; the server beside it is started on demand.
exit /b 0

rem ---------------------------------------------------------------------------
rem  A preset the editor would write itself. Godot normalises it the next time
rem  the project is opened, so this is a starting point, not a fixed file.
rem ---------------------------------------------------------------------------
:write_preset
set "CFG=%ROOT%\viewer-gd\export_presets.cfg"
echo Writing viewer-gd\export_presets.cfg ...
>  "%CFG%" echo [preset.0]
>> "%CFG%" echo.
>> "%CFG%" echo name="Windows Desktop"
>> "%CFG%" echo platform="Windows Desktop"
>> "%CFG%" echo runnable=true
>> "%CFG%" echo advanced_options=false
>> "%CFG%" echo dedicated_server=false
>> "%CFG%" echo custom_features=""
>> "%CFG%" echo export_filter="all_resources"
>> "%CFG%" echo include_filter=""
>> "%CFG%" echo exclude_filter=""
>> "%CFG%" echo export_path="../dist/code-scrap.exe"
>> "%CFG%" echo encryption_include_filters=""
>> "%CFG%" echo encryption_exclude_filters=""
>> "%CFG%" echo seed=0
>> "%CFG%" echo encrypt_pck=false
>> "%CFG%" echo encrypt_directory=false
>> "%CFG%" echo script_export_mode=2
>> "%CFG%" echo.
>> "%CFG%" echo [preset.0.options]
>> "%CFG%" echo.
>> "%CFG%" echo binary_format/embed_pck=true
exit /b 0

rem ---------------------------------------------------------------------------
:import
if exist "%ROOT%\viewer-gd\.godot" rmdir /s /q "%ROOT%\viewer-gd\.godot"
echo Importing the Godot project...
"%GODOT_C%" --headless --path "%ROOT%\viewer-gd" --import
exit /b %errorlevel%

:import_once
if exist "%ROOT%\viewer-gd\.godot" exit /b 0
echo Importing the Godot project (first run)...
"%GODOT_C%" --headless --path "%ROOT%\viewer-gd" --import >nul 2>&1
exit /b 0

rem ---------------------------------------------------------------------------
:clean
call :stop
if exist "%ROOT%\scrap\bin" rmdir /s /q "%ROOT%\scrap\bin"
if exist "%ROOT%\dist" rmdir /s /q "%ROOT%\dist"
if exist "%ROOT%\viewer-gd\.godot" rmdir /s /q "%ROOT%\viewer-gd\.godot"
echo Cleaned. The analysis cache in %%LOCALAPPDATA%%\code-scrap is left alone.
exit /b 0

rem ---------------------------------------------------------------------------
rem  Stop a server that outlived its viewer. Only scrap.exe: the viewer runs
rem  under the Godot executable, and so may an editor you are working in.
rem ---------------------------------------------------------------------------
:stop_command
call :stop
exit /b 0

:stop
tasklist /fi "imagename eq scrap.exe" 2>nul | find /i "scrap.exe" >nul
if errorlevel 1 (
    echo No server was running.
    exit /b 0
)
echo Stopping scrap serve...
taskkill /im scrap.exe /f >nul 2>nul
exit /b 0

rem ---------------------------------------------------------------------------
rem  The repository to map: the argument, or this one.
rem ---------------------------------------------------------------------------
:repo_arg
set "REPO=%~1"
if "%REPO%"=="" set "REPO=%ROOT%"
if not exist "%REPO%\" (
    echo ERROR: repository folder not found: %REPO%
    exit /b 1
)
exit /b 0
