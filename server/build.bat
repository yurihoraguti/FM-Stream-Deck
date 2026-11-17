@echo off
rem Builds FMStreamDeck.exe with the C# compiler that ships with Windows (.NET Framework 4).
rem obs-deck.html and server\panel.html are embedded; files on disk next to the .exe take priority.
rem Release builds are signed by the GitHub Actions workflow (SignPath) - see docs\SIGNPATH_SETUP.md.
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
