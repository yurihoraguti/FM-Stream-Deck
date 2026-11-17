@echo off
rem Builds FMStreamDeck.exe with the C# compiler that ships with Windows (.NET Framework 4).
rem obs-deck.html and server\panel.html are embedded; files on disk next to the .exe take priority.
rem Optional signing: set SIGN_PFX (path to .pfx) and SIGN_PFX_PASSWORD before running.
setlocal
set "ROOT=%~dp0.."
set "CSC=%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe"
if not exist "%CSC%" set "CSC=%WINDIR%\Microsoft.NET\Framework\v4.0.30319\csc.exe"
if not exist "%CSC%" (
  echo C# compiler from .NET Framework 4 not found.
  exit /b 1
)
"%CSC%" /nologo /target:exe /optimize+ /platform:anycpu ^
  /out:"%ROOT%\FMStreamDeck.exe" ^
  /resource:"%ROOT%\obs-deck.html",obs-deck.html ^
  /resource:"%ROOT%\server\panel.html",panel.html ^
  "%~dp0FMStreamDeck.cs"
if errorlevel 1 exit /b 1
echo Built: %ROOT%\FMStreamDeck.exe

if not defined SIGN_PFX goto :eof
set "SIGNTOOL="
for /f "delims=" %%s in ('dir /b /s "%ProgramFiles(x86)%\Windows Kits\10\bin\*signtool.exe" 2^>nul ^| findstr /i "\\x64\\"') do set "SIGNTOOL=%%s"
if not defined SIGNTOOL (
  echo signtool.exe not found - install the Windows SDK to sign.
  exit /b 1
)
"%SIGNTOOL%" sign /fd sha256 /f "%SIGN_PFX%" /p "%SIGN_PFX_PASSWORD%" /tr http://timestamp.digicert.com /td sha256 "%ROOT%\FMStreamDeck.exe"
if errorlevel 1 exit /b 1
echo Signed: %ROOT%\FMStreamDeck.exe
