[CmdletBinding()]
param(
    [string]$BuildDirectory = "",
    [string]$OutputDirectory = "",
    [ValidateSet("base.en-q5_1", "base-q5_1", "small.en-q5_1")]
    [string]$Model = "base.en-q5_1",
    [switch]$UseMKL,
    [switch]$SkipModel
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($BuildDirectory)) {
    $BuildDirectory = Join-Path $RepositoryRoot "build\windows-stt"
}
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) {
    $OutputDirectory = Join-Path $RepositoryRoot "dist\windows"
}

if (-not [Environment]::Is64BitOperatingSystem) {
    throw "Hermes STT requires 64-bit Windows."
}
if (-not (Get-Command cmake -ErrorAction SilentlyContinue)) {
    throw "CMake is required. Install Visual Studio 2022 Build Tools with Desktop development with C++."
}
if ($UseMKL -and [string]::IsNullOrWhiteSpace($env:MKLROOT)) {
    throw "-UseMKL requires Intel oneAPI MKL and an initialized MKLROOT environment."
}

$MKL = if ($UseMKL) { "ON" } else { "OFF" }
$SourceDirectory = Join-Path $RepositoryRoot "native\windows\stt"

cmake -S $SourceDirectory -B $BuildDirectory -G "Visual Studio 17 2022" -A x64 `
    -DHERMES_STT_USE_MKL=$MKL `
    -DCMAKE_BUILD_TYPE=Release
if ($LASTEXITCODE -ne 0) { throw "CMake configuration failed." }

cmake --build $BuildDirectory --config Release --parallel 2
if ($LASTEXITCODE -ne 0) { throw "Native STT build failed." }

cmake --install $BuildDirectory --config Release --prefix $OutputDirectory --component HermesSTT
if ($LASTEXITCODE -ne 0) { throw "Native STT installation failed." }

if (-not $SkipModel) {
    & (Join-Path $PSScriptRoot "setup-windows-stt.ps1") `
        -Model $Model `
        -Destination (Join-Path $OutputDirectory "models")
}

Write-Host "Hermes Windows STT is ready in $OutputDirectory"
Write-Host "Benchmark: $OutputDirectory\hermes-stt-bench.exe"
Write-Host "Live probe: $OutputDirectory\hermes-stt-probe.exe"
Write-Host "Default inference threads: 2 (override with HERMES_STT_THREADS=1..3)."
