[CmdletBinding()]
param(
    [ValidateSet("base.en-q5_1", "base-q5_1", "small.en-q5_1")]
    [string]$Model = "base.en-q5_1",
    [string]$Destination = "",
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Destination)) {
    $Destination = Join-Path $RepositoryRoot "dist\windows\models"
}

$Models = @{
    "base.en-q5_1" = @{
        Sha256 = "4baf70dd0d7c4247ba2b81fafd9c01005ac77c2f9ef064e00dcf195d0e2fdd2f"
        Bytes = 59721011
    }
    "base-q5_1" = @{
        Sha256 = "422f1ae452ade6f30a004d7e5c6a43195e4433bc370bf23fac9cc591f01a8898"
        Bytes = 59707625
    }
    "small.en-q5_1" = @{
        Sha256 = "bfdff4894dcb76bbf647d56263ea2a96645423f1669176f4844a1bf8e478ad30"
        Bytes = 190098681
    }
}

$Metadata = $Models[$Model]
$FileName = "ggml-$Model.bin"
$Target = Join-Path $Destination $FileName
$Temporary = "$Target.download"
$Revision = "5359861c739e955e79d9a303bcbc70fb988958b1"
$Source = "https://huggingface.co/ggerganov/whisper.cpp/resolve/$Revision/$FileName"

New-Item -ItemType Directory -Force -Path $Destination | Out-Null

function Test-Model([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $false }
    $Item = Get-Item -LiteralPath $Path
    if ($Item.Length -ne $Metadata.Bytes) { return $false }
    $Digest = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
    return $Digest -eq $Metadata.Sha256
}

if ((-not $Force) -and (Test-Model $Target)) {
    Write-Host "Verified model already present: $Target"
    exit 0
}

if (Test-Path -LiteralPath $Temporary) {
    Remove-Item -LiteralPath $Temporary -Force
}

Write-Host "Downloading checksum-pinned $Model model..."
Invoke-WebRequest -Uri $Source -OutFile $Temporary -UseBasicParsing

if (-not (Test-Model $Temporary)) {
    Remove-Item -LiteralPath $Temporary -Force
    throw "Model checksum or size validation failed. Nothing was installed."
}

Move-Item -LiteralPath $Temporary -Destination $Target -Force
Write-Host "Installed verified model: $Target"
