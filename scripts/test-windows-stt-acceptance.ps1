[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Manifest,
    [Parameter(Mandatory = $true)]
    [ValidateRange(0.0, 1.0)]
    [double]$MacBaselineWER,
    [string]$Benchmark = "",
    [string]$Probe = "",
    [string]$Model = "",
    [string]$Language = "en",
    [ValidateRange(1, 3)]
    [int]$Threads = 2,
    [ValidateRange(1, 1000)]
    [int]$LifecycleCycles = 100,
    [ValidateRange(10, 3600)]
    [int]$SilenceSeconds = 60,
    [ValidateRange(1.0, 10000.0)]
    [double]$MinimumAudioMinutes = 60.0,
    [ValidateRange(0.0, 1.0)]
    [double]$MaximumWER = 0.15,
    [ValidateRange(0.0, 1.0)]
    [double]$MaximumWERDelta = 0.015,
    [ValidateRange(0.01, 10.0)]
    [double]$MaximumDecodeRTF = 0.80,
    [ValidateRange(1.0, 60000.0)]
    [double]$MaximumP95LatencyMs = 1500.0,
    [ValidateRange(1.0, 100.0)]
    [double]$MaximumCPUPercent = 70.0,
    [ValidateRange(1.0, 8192.0)]
    [double]$MaximumWorkingSetMB = 650.0,
    [ValidateRange(0.0, 1024.0)]
    [double]$MaximumLifecycleGrowthMB = 16.0,
    [string]$Output = ""
)

$ErrorActionPreference = "Stop"
$RepositoryRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Benchmark)) {
    $Benchmark = Join-Path $RepositoryRoot "dist\windows\hermes-stt-bench.exe"
}
if ([string]::IsNullOrWhiteSpace($Model)) {
    $Model = Join-Path $RepositoryRoot "dist\windows\models\ggml-base.en-q5_1.bin"
}
if ([string]::IsNullOrWhiteSpace($Probe)) {
    $Probe = Join-Path $RepositoryRoot "dist\windows\hermes-stt-probe.exe"
}
if ([string]::IsNullOrWhiteSpace($Output)) {
    $Output = Join-Path $RepositoryRoot "dist\windows\stt-acceptance.json"
}

$ManifestPath = (Resolve-Path -LiteralPath $Manifest).Path
$ManifestDirectory = Split-Path -Parent $ManifestPath
$Benchmark = (Resolve-Path -LiteralPath $Benchmark).Path
$Probe = (Resolve-Path -LiteralPath $Probe).Path
$Model = (Resolve-Path -LiteralPath $Model).Path
$Rows = @(Import-Csv -LiteralPath $ManifestPath)
if ($Rows.Count -eq 0) {
    throw "The acceptance manifest is empty."
}

function Resolve-CorpusPath([string]$Value, [string]$Column) {
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "Every manifest row requires a $Column value."
    }
    $Candidate = if ([IO.Path]::IsPathRooted($Value)) {
        $Value
    } else {
        Join-Path $ManifestDirectory $Value
    }
    return (Resolve-Path -LiteralPath $Candidate).Path
}

$Cases = foreach ($Row in $Rows) {
    [PSCustomObject]@{
        Wav = Resolve-CorpusPath ([string]$Row.wav) "wav"
        Reference = Resolve-CorpusPath ([string]$Row.reference) "reference"
        Category = ([string]$Row.category).Trim()
    }
}

function Invoke-JSONExecutable([string]$Executable, [string[]]$Arguments) {
    $ErrorFile = [IO.Path]::GetTempFileName()
    try {
        $Text = (& $Executable @Arguments 2> $ErrorFile | Out-String)
        $ExitCode = $LASTEXITCODE
        $Diagnostics = (Get-Content -LiteralPath $ErrorFile -Raw -ErrorAction SilentlyContinue)
        if ([string]::IsNullOrWhiteSpace($Text)) {
            throw "Benchmark returned no JSON (exit $ExitCode). $Diagnostics"
        }
        try {
            $Data = $Text | ConvertFrom-Json
        } catch {
            throw "Benchmark returned invalid JSON (exit $ExitCode): $Text`n$Diagnostics"
        }
        if ($ExitCode -ne 0 -and $ExitCode -ne 4 -and $ExitCode -ne 5) {
            throw "Benchmark failed with exit $ExitCode. $Diagnostics"
        }
        return [PSCustomObject]@{
            ExitCode = $ExitCode
            Data = $Data
            Diagnostics = $Diagnostics
        }
    } finally {
        Remove-Item -LiteralPath $ErrorFile -Force -ErrorAction SilentlyContinue
    }
}

function New-Arguments([string]$CaseManifest, [switch]$Fast, [int]$Repeat = 1) {
    $Arguments = [Collections.Generic.List[string]]::new()
    $Arguments.Add("--model")
    $Arguments.Add($Model)
    $Arguments.Add("--language")
    $Arguments.Add($Language)
    $Arguments.Add("--threads")
    $Arguments.Add($Threads.ToString([Globalization.CultureInfo]::InvariantCulture))
    if ($Fast) { $Arguments.Add("--fast") }
    if ($Repeat -ne 1) {
        $Arguments.Add("--repeat")
        $Arguments.Add($Repeat.ToString([Globalization.CultureInfo]::InvariantCulture))
    }
    $Arguments.Add("--manifest")
    $Arguments.Add($CaseManifest)
    return $Arguments.ToArray()
}

function Invoke-CaseSet([object[]]$SelectedCases, [switch]$Fast, [int]$Repeat = 1) {
    $CaseManifest = [IO.Path]::GetTempFileName()
    try {
        $Lines = [Collections.Generic.List[string]]::new()
        foreach ($Case in $SelectedCases) {
            if ($Case.Wav -match "[`t`r`n]" -or $Case.Reference -match "[`t`r`n]") {
                throw "Corpus paths cannot contain tabs or newlines."
            }
            $Lines.Add("$($Case.Wav)`t$($Case.Reference)")
        }
        [IO.File]::WriteAllLines($CaseManifest, $Lines, [Text.UTF8Encoding]::new($false))
        return Invoke-JSONExecutable $Benchmark (New-Arguments $CaseManifest -Fast:$Fast -Repeat $Repeat)
    } finally {
        Remove-Item -LiteralPath $CaseManifest -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Running real-time resident-model corpus ($($Cases.Count) clips)..."
$CorpusRun = Invoke-CaseSet $Cases

Write-Host "Running $LifecycleCycles fast listener lifecycle cycles..."
$LifecycleRun = Invoke-CaseSet @($Cases[0]) -Fast -Repeat $LifecycleCycles

function Write-SilenceWav([string]$Path, [int]$Seconds) {
    $SampleRate = 16000
    $DataBytes = $SampleRate * 2 * $Seconds
    $Stream = [IO.File]::Create($Path)
    $Writer = [IO.BinaryWriter]::new($Stream)
    try {
        $Writer.Write([Text.Encoding]::ASCII.GetBytes("RIFF"))
        $Writer.Write([int](36 + $DataBytes))
        $Writer.Write([Text.Encoding]::ASCII.GetBytes("WAVEfmt "))
        $Writer.Write([int]16)
        $Writer.Write([int16]1)
        $Writer.Write([int16]1)
        $Writer.Write([int]$SampleRate)
        $Writer.Write([int]($SampleRate * 2))
        $Writer.Write([int16]2)
        $Writer.Write([int16]16)
        $Writer.Write([Text.Encoding]::ASCII.GetBytes("data"))
        $Writer.Write([int]$DataBytes)
        $Zeros = [byte[]]::new(65536)
        $Remaining = $DataBytes
        while ($Remaining -gt 0) {
            $Count = [Math]::Min($Remaining, $Zeros.Length)
            $Writer.Write($Zeros, 0, $Count)
            $Remaining -= $Count
        }
    } finally {
        $Writer.Dispose()
        $Stream.Dispose()
    }
}

Write-Host "Running $SilenceSeconds-second live WASAPI silence probe..."
$SilenceFile = Join-Path ([IO.Path]::GetTempPath()) (([IO.Path]::GetRandomFileName()) + ".wav")
$Player = $null
try {
    Write-SilenceWav $SilenceFile $SilenceSeconds
    $Player = [System.Media.SoundPlayer]::new($SilenceFile)
    $Player.Load()
    $Player.PlayLooping()
    Start-Sleep -Milliseconds 500
    $ProbeArguments = @(
        "--model", $Model,
        "--language", $Language,
        "--threads", $Threads.ToString([Globalization.CultureInfo]::InvariantCulture),
        "--seconds", $SilenceSeconds.ToString([Globalization.CultureInfo]::InvariantCulture)
    )
    $SilenceRun = Invoke-JSONExecutable $Probe $ProbeArguments
} finally {
    if ($Player) {
        $Player.Stop()
        $Player.Dispose()
    }
    Remove-Item -LiteralPath $SilenceFile -Force -ErrorAction SilentlyContinue
}

$CategoryResults = [ordered]@{}
foreach ($Group in ($Cases | Where-Object { $_.Category } | Group-Object Category)) {
    Write-Host "Measuring '$($Group.Name)' accuracy subset..."
    $CategoryRun = Invoke-CaseSet @($Group.Group) -Fast
    $CategoryResults[$Group.Name] = $CategoryRun.Data
}

try {
    $Processor = Get-CimInstance Win32_Processor | Select-Object -First 1
    $OperatingSystem = Get-CimInstance Win32_OperatingSystem
    $Computer = Get-CimInstance Win32_ComputerSystem
    $Hardware = [ordered]@{
        cpu = [string]$Processor.Name
        logical_processors = [int]$Processor.NumberOfLogicalProcessors
        physical_cores = [int]$Processor.NumberOfCores
        memory_gb = [Math]::Round([double]$Computer.TotalPhysicalMemory / 1GB, 2)
        os = [string]$OperatingSystem.Caption
        os_version = [string]$OperatingSystem.Version
        os_build = [string]$OperatingSystem.BuildNumber
    }
} catch {
    $Hardware = [ordered]@{ error = $_.Exception.Message }
}

$Gates = [Collections.Generic.List[object]]::new()
function Add-Gate([string]$Name, $Actual, [string]$Requirement, [bool]$Passed) {
    $Gates.Add([PSCustomObject]@{
        name = $Name
        actual = $Actual
        requirement = $Requirement
        passed = $Passed
    })
}

$Corpus = $CorpusRun.Data
$Lifecycle = $LifecycleRun.Data
$Silence = $SilenceRun.Data
$AudioMinutes = [double]$Corpus.audio_seconds / 60.0
Add-Gate "target CPU" ([string]$Hardware.cpu) "contains i5-6300U" ([string]$Hardware.cpu -match "i5-6300U")
Add-Gate "target physical cores" ([int]$Hardware.physical_cores) "= 2" ([int]$Hardware.physical_cores -eq 2)
Add-Gate "target memory" ([double]$Hardware.memory_gb) "7.0..8.5 GB" ([double]$Hardware.memory_gb -ge 7.0 -and [double]$Hardware.memory_gb -le 8.5)
Add-Gate "target Windows build" ([string]$Hardware.os_build) "= 22000 (Windows 11 21H2)" ([string]$Hardware.os_build -eq "22000")
Add-Gate "representative audio" $AudioMinutes ">= $MinimumAudioMinutes minutes" ($AudioMinutes -ge $MinimumAudioMinutes)
Add-Gate "ground-truth words" ([int]$Corpus.reference_words) "> 0" ([int]$Corpus.reference_words -gt 0)
Add-Gate "absolute WER" ([double]$Corpus.wer) "<= $MaximumWER" ([double]$Corpus.wer -le $MaximumWER)
$ParityLimit = $MacBaselineWER + $MaximumWERDelta
Add-Gate "macOS WER delta" ([double]$Corpus.wer - $MacBaselineWER) "<= $MaximumWERDelta" ([double]$Corpus.wer -le $ParityLimit)
Add-Gate "decode RTF" ([double]$Corpus.decode_rtf) "< $MaximumDecodeRTF" ([double]$Corpus.decode_rtf -lt $MaximumDecodeRTF)
Add-Gate "p95 final latency" ([double]$Corpus.p95_final_latency_ms) "<= $MaximumP95LatencyMs ms" ([double]$Corpus.p95_final_latency_ms -le $MaximumP95LatencyMs)
Add-Gate "average process CPU" ([double]$Corpus.normalized_cpu_percent) "< $MaximumCPUPercent%" ([double]$Corpus.normalized_cpu_percent -lt $MaximumCPUPercent)
Add-Gate "peak working set" ([double]$Corpus.peak_working_set_mb) "< $MaximumWorkingSetMB MB" ([double]$Corpus.peak_working_set_mb -lt $MaximumWorkingSetMB)
Add-Gate "corpus final results" ([bool]$Corpus.final_result) "all true" ([bool]$Corpus.final_result)
Add-Gate "corpus dropped jobs" ([int]$Corpus.dropped_jobs) "= 0" ([int]$Corpus.dropped_jobs -eq 0)
Add-Gate "lifecycle cycles" ([int]$Lifecycle.repeat_count) "= $LifecycleCycles" ([int]$Lifecycle.repeat_count -eq $LifecycleCycles)
Add-Gate "lifecycle working-set growth" ([double]$Lifecycle.working_set_growth_mb) "<= $MaximumLifecycleGrowthMB MB" ([double]$Lifecycle.working_set_growth_mb -le $MaximumLifecycleGrowthMB)
Add-Gate "lifecycle maximum growth" ([double]$Lifecycle.max_cycle_growth_mb) "<= $MaximumLifecycleGrowthMB MB" ([double]$Lifecycle.max_cycle_growth_mb -le $MaximumLifecycleGrowthMB)
Add-Gate "lifecycle final results" ([bool]$Lifecycle.final_result) "all true" ([bool]$Lifecycle.final_result)
Add-Gate "lifecycle dropped jobs" ([int]$Lifecycle.dropped_jobs) "= 0" ([int]$Lifecycle.dropped_jobs -eq 0)
Add-Gate "silence capture coverage" ([double]$Silence.captured_seconds) ">= 90% of probe" ([double]$Silence.captured_seconds -ge $SilenceSeconds * 0.90)
Add-Gate "silence CPU" ([double]$Silence.normalized_cpu_percent) "< 1%" ([double]$Silence.normalized_cpu_percent -lt 1.0)
Add-Gate "silence false speech" ([double]$Silence.speech_seconds) "= 0 seconds" ([double]$Silence.speech_seconds -eq 0.0)
Add-Gate "silence decode count" ([int]$Silence.decode_count) "= 0" ([int]$Silence.decode_count -eq 0)
Add-Gate "live audio discontinuities" ([int]$Silence.audio_discontinuities) "= 0" ([int]$Silence.audio_discontinuities -eq 0)
Add-Gate "live dropped jobs" ([int]$Silence.dropped_jobs) "= 0" ([int]$Silence.dropped_jobs -eq 0)

$Passed = ($Gates | Where-Object { -not $_.passed }).Count -eq 0
$Report = [ordered]@{
    schema_version = 1
    generated_utc = [DateTime]::UtcNow.ToString("o")
    passed = $Passed
    hardware = $Hardware
    settings = [ordered]@{
        model = $Model
        language = $Language
        threads = $Threads
        mac_baseline_wer = $MacBaselineWER
        manifest = $ManifestPath
    }
    gates = $Gates
    corpus = $Corpus
    lifecycle = $Lifecycle
    live_silence = $Silence
    category_accuracy = $CategoryResults
}

$OutputDirectory = Split-Path -Parent $Output
if ($OutputDirectory) {
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
}
$Report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Output -Encoding UTF8

$Gates | Format-Table name, actual, requirement, passed -AutoSize
Write-Host "Acceptance report: $Output"
if (-not $Passed) { exit 1 }
Write-Host "Hermes Windows STT acceptance gates passed."
