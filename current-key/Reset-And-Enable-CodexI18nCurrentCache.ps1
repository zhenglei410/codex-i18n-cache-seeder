[CmdletBinding()]
param(
    [ValidateRange(1, 65535)]
    [int]$Port = 9240,

    [ValidateRange(10, 300)]
    [int]$TimeoutSeconds = 120,

    [switch]$SkipProcessStop,

    [switch]$ValidateOnly
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$processPattern = '^(ChatGPT|Codex|codex-command-runner|codex-windows-sandbox-service|codex-code-mode-host)(\.exe)?$'

Write-Warning (
    'This command will force-close ChatGPT/Codex processes. ' +
    'Save all work and run it from an external PowerShell window.'
)

$remaining = @()
$processStopSkipped = $SkipProcessStop.IsPresent

if (-not $processStopSkipped) {
    $targets = @(
        Get-CimInstance Win32_Process |
            Where-Object { $_.Name -match $processPattern }
    )

    foreach ($process in $targets) {
        if ($null -eq (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) {
            continue
        }

        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-Host "Stopped: $($process.Name) / PID $($process.ProcessId)"
        }
        catch {
            Write-Warning "Could not stop $($process.Name): $($_.Exception.Message)"
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(
            Get-CimInstance Win32_Process |
                Where-Object { $_.Name -match $processPattern }
        )
    }
    while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        $remaining |
            Select-Object ProcessId, Name, CommandLine |
            Format-List
        throw 'Some ChatGPT/Codex processes are still running.'
    }
}

$ccSwitchProcesses = @(
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -match 'cc.?switch' -or
            $_.CommandLine -match 'cc.?switch'
        }
)

if ($ccSwitchProcesses.Count -gt 0) {
    Write-Warning (
        'CC Switch is still running. Exit it from the tray if it auto-restarts Codex.'
    )
}

if ($ValidateOnly) {
    $remaining = @(
        Get-CimInstance Win32_Process |
            Where-Object { $_.Name -match $processPattern }
    )
    Write-Host "Validation passed. Codex process count: $($remaining.Count). Process stop skipped: $processStopSkipped"
    return
}

$api = 'https://gitee.com/api/v5/repos/zhenglei410/codex-i18n-cache-seeder/contents/current-key/Enable-CodexI18nCurrentCache.ps1?ref=main'
$response = Invoke-RestMethod -Uri $api -TimeoutSec 30
$scriptBytes = [Convert]::FromBase64String(([string]$response.content -replace '\s', ''))
$scriptText = [Text.Encoding]::UTF8.GetString($scriptBytes).TrimStart([char]0xFEFF)

& ([scriptblock]::Create($scriptText)) `
    -Port $Port `
    -TimeoutSeconds $TimeoutSeconds
