[CmdletBinding()]
param(
    [switch]$BootstrapMissing,

    [ValidateRange(1, 65535)]
    [int]$Port = 9240,

    [ValidateRange(10, 300)]
    [int]$TimeoutSeconds = 120,

    [switch]$NoLaunch,

    [switch]$Reload,

    [switch]$NoAutoRestart
)

# Compatibility entrypoint for historical command URLs.
# Legacy switches remain accepted, but execution now uses the current-key tool.
$u = 'https://gitee.com/zhenglei410/codex-i18n-cache-seeder/raw/main/current-key/Reset-And-Enable-CodexI18nCurrentCache.ps1'
$text = (Invoke-RestMethod $u).TrimStart([char]0xFEFF)

$arguments = @{
    Port = $Port
    TimeoutSeconds = $TimeoutSeconds
}

if ($NoAutoRestart) {
    $arguments.NoAutoRestart = $true
}

& ([scriptblock]::Create($text)) @arguments
