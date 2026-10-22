[CmdletBinding()]
param(
    [ValidateRange(0, 65535)]
    [int]$Port = 0,

    [ValidateRange(5, 300)]
    [int]$TimeoutSeconds = 60,

    [switch]$NoLaunch,

    [switch]$Reload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$LayerId = '72216192'

function Get-CodexMainProcesses {
    Get-CimInstance Win32_Process -Filter "Name='ChatGPT.exe'" -ErrorAction SilentlyContinue |
        Where-Object {
            $_.CommandLine -and
            $_.CommandLine -notmatch '--type=' -and
            $_.CommandLine -notmatch 'crashpad-handler'
        }
}

function Get-DebugPortFromProcess {
    param([object]$Process)

    if ($null -eq $Process -or [string]::IsNullOrWhiteSpace($Process.CommandLine)) {
        return $null
    }

    $match = [regex]::Match($Process.CommandLine, '--remote-debugging-port=(\d+)')
    if (-not $match.Success) {
        return $null
    }

    return [int]$match.Groups[1].Value
}

function Test-CdpEndpoint {
    param([int]$CandidatePort)

    if ($CandidatePort -le 0) {
        return $false
    }

    try {
        $null = Invoke-RestMethod -Uri "http://127.0.0.1:$CandidatePort/json/version" -TimeoutSec 1
        return $true
    }
    catch {
        return $false
    }
}

function Find-FreePort {
    foreach ($candidate in 9230..9258) {
        $listener = $null
        try {
            $listener = [System.Net.Sockets.TcpListener]::new(
                [System.Net.IPAddress]::Loopback,
                $candidate
            )
            $listener.Start()
            return $candidate
        }
        catch {
            continue
        }
        finally {
            if ($null -ne $listener) {
                $listener.Stop()
            }
        }
    }

    throw 'No free debugging port was found in the range 9230-9258.'
}

function Add-AppActivationInterop {
    if ('CodexI18nCacheSeeder.NativeActivation' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexI18nCacheSeeder
{
    public enum ActivateOptions
    {
        None = 0,
        DesignMode = 1,
        NoErrorUI = 2,
        NoSplashScreen = 4
    }

    public static class NativeActivation
    {
        private const uint CLSCTX_LOCAL_SERVER = 0x4;

        [DllImport("ole32.dll")]
        private static extern int CoCreateInstance(
            ref Guid rclsid,
            IntPtr pUnkOuter,
            uint dwClsContext,
            ref Guid riid,
            out IntPtr ppv);

        [UnmanagedFunctionPointer(CallingConvention.Winapi)]
        private delegate int ActivateApplicationDelegate(
            IntPtr self,
            [MarshalAs(UnmanagedType.LPWStr)] string appUserModelId,
            [MarshalAs(UnmanagedType.LPWStr)] string arguments,
            int options,
            out uint processId);

        public static int Activate(
            string appUserModelId,
            string arguments,
            int options,
            out uint processId)
        {
            Guid clsid = new Guid("45BA127D-10A8-46EA-8AB7-56EA9078943C");
            Guid iid = new Guid("2e941141-7f97-4756-ba1d-9decde894a3d");
            IntPtr manager;
            int hr = CoCreateInstance(
                ref clsid,
                IntPtr.Zero,
                CLSCTX_LOCAL_SERVER,
                ref iid,
                out manager);
            if (hr < 0)
            {
                processId = 0;
                return hr;
            }

            try
            {
                IntPtr vtable = Marshal.ReadIntPtr(manager);
                IntPtr method = Marshal.ReadIntPtr(vtable, 3 * IntPtr.Size);
                ActivateApplicationDelegate activate =
                    (ActivateApplicationDelegate)Marshal.GetDelegateForFunctionPointer(
                        method,
                        typeof(ActivateApplicationDelegate));
                return activate(
                    manager,
                    appUserModelId,
                    arguments,
                    options,
                    out processId);
            }
            finally
            {
                Marshal.Release(manager);
            }
        }
    }
}
'@
}

function Get-CodexAumid {
    $package = Get-AppxPackage -Name OpenAI.Codex |
        Sort-Object Version -Descending |
        Select-Object -First 1

    if ($null -eq $package) {
        throw 'The OpenAI.Codex MSIX package is not installed for the current user.'
    }

    $manifestPath = Join-Path $package.InstallLocation 'AppxManifest.xml'
    [xml]$manifest = Get-Content -Raw -LiteralPath $manifestPath
    $applications = @($manifest.Package.Applications.Application)
    $application = $applications |
        Where-Object { $_.Id -eq 'App' } |
        Select-Object -First 1

    if ($null -eq $application) {
        $application = $applications |
            Where-Object { $_.Executable -match '(?i)(chatgpt|codex)\.exe$' } |
            Select-Object -First 1
    }

    if ($null -eq $application) {
        throw 'The Codex desktop application entry could not be found in AppxManifest.xml.'
    }

    return "$($package.PackageFamilyName)!$($application.Id)"
}

function Start-CodexWithDebugPort {
    param([int]$DebugPort)

    $running = @(Get-CodexMainProcesses)
    if ($running.Count -gt 0) {
        throw 'Codex is already running without the required debugging port. Exit Codex completely, then run this tool again.'
    }

    Add-AppActivationInterop
    $aumid = Get-CodexAumid
    $arguments = "--remote-debugging-port=$DebugPort --remote-allow-origins=http://127.0.0.1:$DebugPort"
    [uint32]$processId = 0
    $hr = [CodexI18nCacheSeeder.NativeActivation]::Activate(
        $aumid,
        $arguments,
        [int][CodexI18nCacheSeeder.ActivateOptions]::None,
        [ref]$processId
    )

    if ($hr -lt 0) {
        $hrHex = ('0x{0:X8}' -f $hr)
        throw "ApplicationActivationManager failed with HRESULT $hrHex."
    }

    Write-Host "Started Codex with a local debugging port ($DebugPort)."
}

function Resolve-DebugPort {
    if ($Port -gt 0) {
        if (-not $NoLaunch) {
            $running = @(Get-CodexMainProcesses)
            if ($running.Count -gt 0) {
                $existingPort = Get-DebugPortFromProcess $running[0]
                if ($existingPort -ne $Port) {
                    throw "Codex is already running on a different or unavailable port. Exit Codex completely, then run this tool again."
                }
            }
            else {
                Start-CodexWithDebugPort -DebugPort $Port
            }
        }

        return $Port
    }

    foreach ($process in @(Get-CodexMainProcesses)) {
        $candidate = Get-DebugPortFromProcess $process
        if ($null -ne $candidate -and (Test-CdpEndpoint $candidate)) {
            return $candidate
        }
    }

    if ($NoLaunch) {
        throw 'No running Codex debugging endpoint was found. Start Codex with --remote-debugging-port first.'
    }

    $freePort = Find-FreePort
    Start-CodexWithDebugPort -DebugPort $freePort
    return $freePort
}

function Wait-CdpTarget {
    param(
        [int]$DebugPort,
        [int]$WaitSeconds
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($WaitSeconds)
    while ([DateTime]::UtcNow -lt $deadline) {
        try {
            $targets = @(Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json/list" -TimeoutSec 2)
            $candidate = $targets |
                Where-Object {
                    $_.type -eq 'page' -and
                    -not [string]::IsNullOrWhiteSpace($_.webSocketDebuggerUrl) -and
                    $_.url -like 'app://*'
                } |
                Sort-Object -Property @{ Expression = { $_.url -notlike 'app://-/index.html*' } } |
                Select-Object -First 1

            if ($null -ne $candidate) {
                return $candidate
            }
        }
        catch {
            # Codex may still be starting.
        }

        Start-Sleep -Milliseconds 500
    }

    throw "Codex did not expose an app:// page through CDP within $WaitSeconds seconds."
}

function Invoke-CdpExpression {
    param(
        [string]$WebSocketUrl,
        [string]$Expression,
        [int]$WaitSeconds
    )

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $connectTimeout = [System.Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds([Math]::Min($WaitSeconds, 10))
    )

    try {
        $socket.ConnectAsync(
            [Uri]$WebSocketUrl,
            $connectTimeout.Token
        ).GetAwaiter().GetResult()

        $payload = @{
            id = 1
            method = 'Runtime.evaluate'
            params = @{
                expression = $Expression
                awaitPromise = $true
                returnByValue = $true
            }
        } | ConvertTo-Json -Depth 12 -Compress

        $bytes = [System.Text.Encoding]::UTF8.GetBytes($payload)
        $segment = [System.ArraySegment[byte]]::new($bytes)
        $socket.SendAsync(
            $segment,
            [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            [System.Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()

        $buffer = [byte[]]::new(65536)
        $received = [System.Text.StringBuilder]::new()

        while ($true) {
            $result = $socket.ReceiveAsync(
                [System.ArraySegment[byte]]::new($buffer),
                [System.Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()

            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'The Codex debugging WebSocket closed before returning a result.'
            }

            [void]$received.Append(
                [System.Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count)
            )

            if (-not $result.EndOfMessage) {
                continue
            }

            $message = $received.ToString() | ConvertFrom-Json
            [void]$received.Clear()

            $idProperty = $message.PSObject.Properties['id']
            if ($null -eq $idProperty -or [int]$idProperty.Value -ne 1) {
                continue
            }

            $errorProperty = $message.PSObject.Properties['error']
            if ($null -ne $errorProperty -and $null -ne $errorProperty.Value) {
                $errorMessageProperty = $errorProperty.Value.PSObject.Properties['message']
                $errorMessage = if ($null -ne $errorMessageProperty) {
                    [string]$errorMessageProperty.Value
                }
                else {
                    'Unknown DevTools error'
                }
                throw "CDP error: $errorMessage"
            }

            $resultProperty = $message.PSObject.Properties['result']
            if ($null -eq $resultProperty -or $null -eq $resultProperty.Value) {
                throw 'The DevTools response did not contain a result.'
            }

            $resultObject = $resultProperty.Value
            $exceptionProperty = $resultObject.PSObject.Properties['exceptionDetails']
            if ($null -ne $exceptionProperty -and $null -ne $exceptionProperty.Value) {
                $exceptionDetails = $exceptionProperty.Value
                $descriptionProperty = $exceptionDetails.PSObject.Properties['text']
                $description = if (
                    $null -ne $descriptionProperty -and
                    -not [string]::IsNullOrWhiteSpace([string]$descriptionProperty.Value)
                ) {
                    [string]$descriptionProperty.Value
                }
                else {
                    'Unknown page error'
                }
                $exceptionObjectProperty = $exceptionDetails.PSObject.Properties['exception']
                if ($null -ne $exceptionObjectProperty -and $null -ne $exceptionObjectProperty.Value) {
                    $descriptionProperty = $exceptionObjectProperty.Value.PSObject.Properties['description']
                    if ($null -ne $descriptionProperty -and -not [string]::IsNullOrWhiteSpace([string]$descriptionProperty.Value)) {
                        $description = [string]$descriptionProperty.Value
                    }
                }
                throw "Page script failed: $description"
            }

            $valueContainerProperty = $resultObject.PSObject.Properties['result']
            if ($null -eq $valueContainerProperty -or $null -eq $valueContainerProperty.Value) {
                throw 'The DevTools result did not contain a value.'
            }

            $valueProperty = $valueContainerProperty.Value.PSObject.Properties['value']
            if ($null -eq $valueProperty) {
                throw 'The DevTools result did not contain a value field.'
            }

            return $valueProperty.Value
        }
    }
    finally {
        $connectTimeout.Dispose()
        if ($socket.State -eq [System.Net.WebSockets.WebSocketState]::Open) {
            try {
                $socket.CloseAsync(
                    [System.Net.WebSockets.WebSocketCloseStatus]::NormalClosure,
                    'done',
                    [System.Threading.CancellationToken]::None
                ).GetAwaiter().GetResult()
            }
            catch {
                # Closing is best-effort.
            }
        }
        $socket.Dispose()
    }
}

$patchExpression = @'
(async () => {
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const prefix = "statsig.cached.evaluations.";
    const targetLayer = "72216192";
    const targetLayerHash = "4269166702";
    const waitUntil = Date.now() + 15000;

    const cacheKeys = () => {
        const keys = [];
        for (let index = 0; index < localStorage.length; index += 1) {
            const key = localStorage.key(index);
            if (key && key.startsWith(prefix)) {
                keys.push(key);
            }
        }
        return keys;
    };

    let keys = cacheKeys();
    while (keys.length === 0 && Date.now() < waitUntil) {
        await sleep(250);
        keys = cacheKeys();
    }

    if (keys.length === 0) {
        return JSON.stringify({
            ok: false,
            error: "No Statsig evaluation cache was found in the Codex page.",
            keys: [],
            modified: 0
        });
    }

    const hasOwn = (value, key) =>
        value !== null &&
        typeof value === "object" &&
        Object.prototype.hasOwnProperty.call(value, key);

    const valueAt = (values, index) => {
        if (values === null || values === undefined || index === null || index === undefined) {
            return undefined;
        }
        return values[String(index)] ?? values[index];
    };

    const patchPayload = payload => {
        const layerMap = payload && payload.layer_configs;
        const values = payload && payload.values;
        if (!layerMap || typeof layerMap !== "object") {
            return { found: false, changed: false, alreadyTrue: false };
        }

        const candidates = [];
        const targetCandidates = [];
        const seen = new Set();
        const addCandidate = (candidate, isTarget) => {
            if (
                candidate !== null &&
                typeof candidate === "object" &&
                !seen.has(candidate)
            ) {
                seen.add(candidate);
                candidates.push(candidate);
                if (isTarget) {
                    targetCandidates.push(candidate);
                }
            }
        };

        for (const [name, metadata] of Object.entries(layerMap)) {
            if (!metadata || typeof metadata !== "object") {
                continue;
            }

            const isTarget = name === targetLayer || name === targetLayerHash;
            if (metadata.v !== undefined) {
                addCandidate(valueAt(values, metadata.v), isTarget);
            }
            addCandidate(metadata.value, isTarget);

            if (isTarget) {
                addCandidate(metadata, true);
            }
        }

        let found = false;
        let changed = false;
        let alreadyTrue = false;

        for (const candidate of candidates) {
            if (hasOwn(candidate, "enable_i18n")) {
                found = true;
                if (candidate.enable_i18n === true) {
                    alreadyTrue = true;
                }
                else {
                    candidate.enable_i18n = true;
                    changed = true;
                }
            }
        }

        if (!found && targetCandidates.length > 0) {
            found = true;
            targetCandidates[0].enable_i18n = true;
            changed = true;
        }

        return { found, changed, alreadyTrue };
    };

    const processed = [];
    let modified = 0;
    let alreadyTrue = 0;

    for (const key of keys) {
        try {
            const raw = localStorage.getItem(key);
            if (raw === null) {
                continue;
            }

            const wrapper = JSON.parse(raw);
            if (!wrapper || !hasOwn(wrapper, "data")) {
                processed.push({ key, status: "not-a-statsig-cache-wrapper" });
                continue;
            }

            const dataWasString = typeof wrapper.data === "string";
            const payload = dataWasString ? JSON.parse(wrapper.data) : wrapper.data;
            const result = patchPayload(payload);

            if (!result.found) {
                processed.push({ key, status: "layer-not-found" });
                continue;
            }

            if (result.changed) {
                wrapper.data = dataWasString ? JSON.stringify(payload) : payload;
                localStorage.setItem(key, JSON.stringify(wrapper));
                modified += 1;
                processed.push({ key, status: "modified" });
            }
            else {
                if (result.alreadyTrue) {
                    alreadyTrue += 1;
                }
                processed.push({ key, status: "already-true" });
            }
        }
        catch (error) {
            processed.push({
                key,
                status: "error",
                error: String(error && error.message ? error.message : error)
            });
        }
    }

    return JSON.stringify({
        ok: modified > 0 || alreadyTrue > 0,
        modified,
        alreadyTrue,
        cacheKeyCount: keys.length,
        entries: processed
    });
})()
'@

try {
    $debugPort = Resolve-DebugPort
    Write-Host "Connecting to Codex debugging endpoint on 127.0.0.1:$debugPort..."
    $target = Wait-CdpTarget -DebugPort $debugPort -WaitSeconds $TimeoutSeconds

    $rawResult = Invoke-CdpExpression `
        -WebSocketUrl $target.webSocketDebuggerUrl `
        -Expression $patchExpression `
        -WaitSeconds $TimeoutSeconds

    $result = $rawResult | ConvertFrom-Json
    $result.entries | Format-Table -AutoSize

    if (-not $result.ok) {
        throw 'The Statsig cache was read, but the i18n layer could not be changed.'
    }

    Write-Host ''
    Write-Host "Statsig cache updated. Modified: $($result.modified); already true: $($result.alreadyTrue)."
    Write-Host 'The API-key configuration, authentication data, and Codex installation were not changed.'

    if ($Reload) {
        $null = Invoke-CdpExpression `
            -WebSocketUrl $target.webSocketDebuggerUrl `
            -Expression 'window.location.reload(); "reloading"' `
            -WaitSeconds 10
        Write-Host 'Requested a page reload. If Statsig refreshes successfully, its server value may replace the cached value.'
    }
    else {
        Write-Host 'Exit Codex completely, then start it normally to load the modified cache.'
    }

    return
}
catch {
    throw
}
