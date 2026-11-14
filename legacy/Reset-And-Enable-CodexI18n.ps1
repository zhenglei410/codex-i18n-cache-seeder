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

if (-not $SkipProcessStop) {
    $targets = @(
        Get-CimInstance Win32_Process |
            Where-Object { $_.Name -match $processPattern }
    )

    foreach ($process in $targets) {
        $liveProcess = Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue
        if ($null -eq $liveProcess) {
            continue
        }

        try {
            Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            Write-Host "Stopped: $($process.Name) / PID $($process.ProcessId)"
        }
        catch {
            Write-Warning (
                "Could not stop $($process.Name) / PID $($process.ProcessId): " +
                $_.Exception.Message
            )
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
        throw (
            'Some ChatGPT/Codex processes are still running. ' +
            'Run PowerShell as administrator or exit the controlling launcher first.'
        )
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
        'CC Switch is still running. If it auto-restarts Codex, ' +
        'exit CC Switch from its tray before continuing.'
    )
}

if ($ValidateOnly) {
    Write-Host "Validation passed. Remaining Codex process count: $($remaining.Count)"
    return
}

$api = 'https://gitee.com/api/v5/repos/zhenglei410/codex-i18n-cache-seeder/contents/Enable-CodexI18nCache.ps1?ref=main'
$response = Invoke-RestMethod -Uri $api -TimeoutSec 30

if ([string]::IsNullOrWhiteSpace([string]$response.content)) {
    throw 'The Gitee API did not return the Codex i18n cache script.'
}

$encodedContent = [string]$response.content -replace '\s', ''
$scriptBytes = [Convert]::FromBase64String($encodedContent)
$scriptText = [Text.Encoding]::UTF8.GetString($scriptBytes).TrimStart([char]0xFEFF)

$coreScript = [scriptblock]::Create($scriptText)
& $coreScript `
    -BootstrapMissing `
    -Port $Port `
    -TimeoutSeconds $TimeoutSeconds
