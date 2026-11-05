param(
    [string]$Python = (Join-Path $PSScriptRoot '.venv\Scripts\python.exe'),
    [string]$BuildRoot = (Join-Path $PSScriptRoot 'build'),
    [string]$Output = (Join-Path $PSScriptRoot 'dist')
)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    & $Python -m PyInstaller --noconfirm --onefile --windowed --name Yeying-Codex-Setup --collect-all customtkinter --distpath $Output --workpath $BuildRoot --specpath $BuildRoot app.py
    if ($LASTEXITCODE -ne 0) { throw 'Build failed' }
} finally { Pop-Location }
