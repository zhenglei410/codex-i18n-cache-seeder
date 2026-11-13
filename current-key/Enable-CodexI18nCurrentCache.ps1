[CmdletBinding()]
param(
    [ValidateRange(0, 65535)]
    [int]$Port = 0,

    [ValidateRange(5, 300)]
    [int]$TimeoutSeconds = 90,

    [switch]$NoLaunch,

    [switch]$InspectOnly,

    [switch]$NoBootstrap,

    [switch]$RestartAfterSuccess
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    foreach ($candidate in 9230..9270) {
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

    throw 'No free debugging port was found in the range 9230-9270.'
}

function Add-AppActivationInterop {
    if ('CodexCurrentCache.NativeActivation' -as [type]) {
        return
    }

    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

namespace CodexCurrentCache
{
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
                return activate(manager, appUserModelId, arguments, 0, out processId);
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
        throw 'The Codex desktop application entry could not be found.'
    }

    return "$($package.PackageFamilyName)!$($application.Id)"
}

function Start-CodexWithDebugPort {
    param([int]$DebugPort)

    if (@(Get-CodexMainProcesses).Count -gt 0) {
        throw 'Codex is already running without the required debugging port.'
    }

    Add-AppActivationInterop
    [uint32]$processId = 0
    $arguments = "--remote-debugging-port=$DebugPort --remote-allow-origins=http://127.0.0.1:$DebugPort"
    $hr = [CodexCurrentCache.NativeActivation]::Activate(
        (Get-CodexAumid),
        $arguments,
        [ref]$processId
    )

    if ($hr -lt 0) {
        throw ('ApplicationActivationManager failed with HRESULT 0x{0:X8}.' -f $hr)
    }

    Write-Host "Started Codex with debugging port $DebugPort."
}

function Stop-CodexRuntimeProcesses {
    $pattern = '^(ChatGPT|Codex|codex-command-runner|codex-windows-sandbox-service|codex-code-mode-host)(\.exe)?$'
    $targets = @(
        Get-CimInstance Win32_Process |
            Where-Object { $_.Name -match $pattern }
    )

    foreach ($process in $targets) {
        if ($null -ne (Get-Process -Id $process.ProcessId -ErrorAction SilentlyContinue)) {
            try {
                Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop
            }
            catch {
                # A parent process may already have stopped this child.
            }
        }
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        Start-Sleep -Milliseconds 250
        $remaining = @(
            Get-CimInstance Win32_Process |
                Where-Object { $_.Name -match $pattern }
        )
    }
    while ($remaining.Count -gt 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($remaining.Count -gt 0) {
        throw 'Codex processes did not stop before restart.'
    }
}

function Start-CodexNormally {
    Add-AppActivationInterop
    [uint32]$processId = 0
    $hr = [CodexCurrentCache.NativeActivation]::Activate(
        (Get-CodexAumid),
        '',
        [ref]$processId
    )

    if ($hr -lt 0) {
        throw ('ApplicationActivationManager failed with HRESULT 0x{0:X8}.' -f $hr)
    }

    $deadline = [DateTime]::UtcNow.AddSeconds(30)
    do {
        Start-Sleep -Milliseconds 300
        $running = @(Get-CodexMainProcesses)
    }
    while ($running.Count -eq 0 -and [DateTime]::UtcNow -lt $deadline)

    if ($running.Count -eq 0) {
        throw 'Codex did not start after activation.'
    }
}

function Resolve-DebugPort {
    if ($Port -gt 0) {
        if (-not $NoLaunch) {
            $running = @(Get-CodexMainProcesses)
            if ($running.Count -eq 0) {
                Start-CodexWithDebugPort -DebugPort $Port
            }
            elseif ((Get-DebugPortFromProcess $running[0]) -ne $Port) {
                throw 'Codex is already running without the requested debugging port.'
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
        throw 'No running Codex debugging endpoint was found.'
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
            $targets = [object[]](Invoke-RestMethod -Uri "http://127.0.0.1:$DebugPort/json/list" -TimeoutSec 2)
            foreach ($target in $targets) {
                if ($null -eq $target) {
                    continue
                }

                $type = $target.PSObject.Properties['type']
                $url = $target.PSObject.Properties['url']
                $webSocket = $target.PSObject.Properties['webSocketDebuggerUrl']

                if (
                    $null -ne $type -and
                    $null -ne $url -and
                    $null -ne $webSocket -and
                    $type.Value -eq 'page' -and
                    $url.Value -eq 'app://-/index.html' -and
                    -not [string]::IsNullOrWhiteSpace([string]$webSocket.Value)
                ) {
                    return $target
                }
            }
        }
        catch {
            # Codex may still be starting.
        }

        Start-Sleep -Milliseconds 500
    }

    throw "Codex did not expose app://-/index.html within $WaitSeconds seconds."
}

function Get-WebSocketUrl {
    param([object]$Target)

    $property = $Target.PSObject.Properties['webSocketDebuggerUrl']
    foreach ($value in @($property.Value)) {
        $match = [regex]::Match([string]$value, '(?i)wss?://[^\s]+')
        if ($match.Success) {
            $uri = [Uri]$match.Value
            if ($uri.Host -in @('localhost', '::1', '[::1]')) {
                $builder = [UriBuilder]$uri
                $builder.Host = '127.0.0.1'
                return $builder.Uri.AbsoluteUri
            }
            return $uri.AbsoluteUri
        }
    }

    throw 'The selected Codex target does not contain a valid WebSocket URL.'
}

function Invoke-CdpExpression {
    param(
        [string]$WebSocketUrl,
        [string]$Expression,
        [int]$WaitSeconds
    )

    $socket = [System.Net.WebSockets.ClientWebSocket]::new()
    $socket.Options.Proxy = $null
    $timeout = [System.Threading.CancellationTokenSource]::new(
        [TimeSpan]::FromSeconds([Math]::Min($WaitSeconds, 10))
    )

    try {
        [void]$socket.ConnectAsync([Uri]$WebSocketUrl, $timeout.Token).GetAwaiter().GetResult()

        $payload = @{
            id = 1
            method = 'Runtime.evaluate'
            params = @{
                expression = $Expression
                awaitPromise = $true
                returnByValue = $true
            }
        } | ConvertTo-Json -Depth 12 -Compress

        $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
        [void]$socket.SendAsync(
            [ArraySegment[byte]]::new($bytes),
            [System.Net.WebSockets.WebSocketMessageType]::Text,
            $true,
            [Threading.CancellationToken]::None
        ).GetAwaiter().GetResult()

        $buffer = [byte[]]::new(65536)
        $received = [Text.StringBuilder]::new()

        while ($true) {
            $result = $socket.ReceiveAsync(
                [ArraySegment[byte]]::new($buffer),
                [Threading.CancellationToken]::None
            ).GetAwaiter().GetResult()

            if ($result.MessageType -eq [System.Net.WebSockets.WebSocketMessageType]::Close) {
                throw 'The Codex WebSocket closed before returning a result.'
            }

            [void]$received.Append([Text.Encoding]::UTF8.GetString($buffer, 0, $result.Count))
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
                $errorTextProperty = $errorProperty.Value.PSObject.Properties['message']
                throw "CDP error: $([string]$errorTextProperty.Value)"
            }

            $resultProperty = $message.PSObject.Properties['result']
            $resultObject = $resultProperty.Value
            $exceptionProperty = $resultObject.PSObject.Properties['exceptionDetails']
            if ($null -ne $exceptionProperty -and $null -ne $exceptionProperty.Value) {
                $textProperty = $exceptionProperty.Value.PSObject.Properties['text']
                throw "Page script failed: $([string]$textProperty.Value)"
            }

            $container = $resultObject.PSObject.Properties['result'].Value
            return $container.PSObject.Properties['value'].Value
        }
    }
    finally {
        $timeout.Dispose()
        $socket.Dispose()
    }
}

function Confirm-CurrentCacheAfterReload {
    param(
        [int]$DebugPort,
        [string]$CurrentCacheKey,
        [int]$TimeoutSeconds
    )

    $target = Wait-CdpTarget -DebugPort $DebugPort -WaitSeconds $TimeoutSeconds
    $webSocketUrl = Get-WebSocketUrl -Target $target

    try {
        $null = Invoke-CdpExpression `
            -WebSocketUrl $webSocketUrl `
            -Expression 'location.reload(); "reload-requested"' `
            -WaitSeconds 5
    }
    catch {
        # Reload normally closes the old CDP connection.
    }

    Start-Sleep -Milliseconds 750
    $escapedKey = $CurrentCacheKey.Replace('\', '\\').Replace("'", "\'")
    $verifyExpression = @"
(() => {
    const key = '$escapedKey';
    const raw = localStorage.getItem(key);
    if (raw === null) {
        return JSON.stringify({ ok: false, reason: "cache-key-missing", key });
    }
    try {
        const wrapper = JSON.parse(raw);
        const payload = typeof wrapper.data === "string"
            ? JSON.parse(wrapper.data)
            : wrapper.data;
        const values = payload?.values;
        let value = null;
        for (const metadata of Object.values(payload?.layer_configs || {})) {
            if (!metadata || typeof metadata !== "object") continue;
            const candidates = [];
            if (metadata.v !== undefined && values) {
                candidates.push(values[String(metadata.v)]);
            }
            candidates.push(metadata.value, metadata);
            value = candidates.find(candidate =>
                candidate &&
                Object.prototype.hasOwnProperty.call(candidate, "enable_i18n")
            ) || null;
            if (value) break;
        }
        return JSON.stringify({
            ok: Boolean(value && value.enable_i18n === true),
            key,
            cachedEnableI18n: value?.enable_i18n ?? null,
            cachedLocaleSource: value?.locale_source ?? null
        });
    }
    catch (error) {
        return JSON.stringify({
            ok: false,
            reason: "cache-parse-failed",
            key,
            error: String(error)
        });
    }
})()
"@

    $lastVerification = $null
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        try {
            $target = Wait-CdpTarget -DebugPort $DebugPort -WaitSeconds 5
            $webSocketUrl = Get-WebSocketUrl -Target $target
            $rawVerification = Invoke-CdpExpression `
                -WebSocketUrl $webSocketUrl `
                -Expression $verifyExpression `
                -WaitSeconds 10
            $verificationText = @($rawVerification) |
                Where-Object { $_ -is [string] } |
                Select-Object -Last 1

            if (-not [string]::IsNullOrWhiteSpace($verificationText)) {
                $lastVerification = $verificationText | ConvertFrom-Json
                if ($lastVerification.ok -eq $true) {
                    return $lastVerification
                }
            }
        }
        catch {
            # The app may still be recreating the renderer after reload.
        }

        Start-Sleep -Milliseconds 500
    }

    if ($null -ne $lastVerification) {
        throw (
            'Cache persistence verification failed. ' +
            "Cached enable_i18n: $($lastVerification.cachedEnableI18n)"
        )
    }

    throw 'Cache persistence verification failed after page reload.'
}

$pageExpression = @'
(async () => {
    const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
    const inspectOnly = __INSPECT_ONLY__;
    const noBootstrap = __NO_BOOTSTRAP__;
    const targetLayer = "72216192";
    const targetLayerHash = "4269166702";
    const cachePrefix = "statsig.cached.evaluations.";
    const deadline = Date.now() + __READY_TIMEOUT_MS__;

    const getRoot = () => window.__STATSIG__ || globalThis.__STATSIG__;
    const getClient = () => {
        const root = getRoot();
        if (!root) return null;
        return root.firstInstance ||
            (typeof root.instance === "function" ? root.instance() : null);
    };

    let client = getClient();
    while (
        (!client || String(client.loadingStatus || "") !== "Ready") &&
        Date.now() < deadline
    ) {
        await sleep(250);
        client = getClient();
    }

    if (!client) {
        return JSON.stringify({
            ok: false,
            error: "Statsig Client did not become available.",
            origin: location.origin,
            href: location.href,
            hasStatsigRoot: Boolean(getRoot())
        });
    }

    if (String(client.loadingStatus || "") !== "Ready") {
        return JSON.stringify({
            ok: false,
            error: "Statsig Client did not reach Ready before the timeout.",
            origin: location.origin,
            href: location.href,
            htmlLang: document.documentElement.lang,
            statsigStatus: client.loadingStatus
        });
    }

    const context = client.getContext();
    const currentCacheKey = String(client.dataAdapter._getCacheKey(context.user));

    const allCacheKeys = Object.keys(localStorage)
        .filter(key => key.startsWith(cachePrefix));
    const staleCacheKeys = allCacheKeys
        .filter(key => key !== currentCacheKey);

    const layer = client.getLayer(targetLayer, { disableExposureLog: true });
    const liveEnableI18n = layer ? layer.get("enable_i18n", null) : null;
    const currentCacheValue = localStorage.getItem(currentCacheKey);

    if (inspectOnly) {
        return JSON.stringify({
            ok: true,
            mode: "inspect",
            origin: location.origin,
            href: location.href,
            htmlLang: document.documentElement.lang,
            statsigStatus: client.loadingStatus,
            currentCacheKey,
            currentCacheKeyExists: currentCacheValue !== null,
            allCacheKeys,
            staleCacheKeys,
            liveEnableI18n
        });
    }

    const parseCurrentPayload = () => {
        if (currentCacheValue === null) return null;
        const wrapper = JSON.parse(currentCacheValue);
        const dataWasString = typeof wrapper.data === "string";
        const payload = dataWasString ? JSON.parse(wrapper.data) : wrapper.data;
        return { wrapper, payload, dataWasString };
    };

    let parsed = null;
    try {
        parsed = parseCurrentPayload();
    }
    catch {
        parsed = null;
    }

    let wrapper = parsed?.wrapper ?? null;
    let dataWasString = parsed?.dataWasString ?? true;
    let payload = parsed?.payload ?? null;
    let seededFrom = parsed ? "current-cache" : null;

    if (!payload && context.values && context.values.has_updates === true) {
        payload = JSON.parse(JSON.stringify(context.values));
        seededFrom = "context-values";
    }

    if (!payload && !noBootstrap) {
        payload = {
            has_updates: true,
            response_format: "init-v2",
            time: Date.now(),
            feature_gates: {},
            dynamic_configs: {},
            layer_configs: {},
            values: {},
            param_stores: {},
            sdk_flags: {},
            exposures: {}
        };
        seededFrom = "minimal-bootstrap";
    }

    if (!payload) {
        return JSON.stringify({
            ok: false,
            error: "Current cache key is missing and bootstrap is disabled.",
            currentCacheKey,
            allCacheKeys,
            staleCacheKeys,
            liveEnableI18n
        });
    }

    const hasOwn = (value, key) =>
        value !== null &&
        typeof value === "object" &&
        Object.prototype.hasOwnProperty.call(value, key);

    const patchExistingLayer = () => {
        const layerMap = payload?.layer_configs;
        const values = payload?.values;
        if (!layerMap || typeof layerMap !== "object") return false;

        for (const [name, metadata] of Object.entries(layerMap)) {
            if (!metadata || typeof metadata !== "object") continue;

            const isTarget = name === targetLayer || name === targetLayerHash;
            const candidates = [];
            if (metadata.v !== undefined && values && typeof values === "object") {
                candidates.push(values[String(metadata.v)]);
            }
            if (metadata.value && typeof metadata.value === "object") {
                candidates.push(metadata.value);
            }
            if (isTarget) candidates.push(metadata);

            for (const candidate of candidates) {
                if (candidate && hasOwn(candidate, "enable_i18n")) {
                    candidate.enable_i18n = true;
                    if (!hasOwn(candidate, "locale_source")) {
                        candidate.locale_source = "SYSTEM";
                    }
                    return true;
                }
            }
        }

        return false;
    };

    const findCachedI18nValue = currentPayload => {
        const layerMap = currentPayload?.layer_configs;
        const values = currentPayload?.values;
        if (!layerMap || typeof layerMap !== "object") return null;

        for (const metadata of Object.values(layerMap)) {
            if (!metadata || typeof metadata !== "object") continue;

            const candidates = [];
            if (metadata.v !== undefined && values && typeof values === "object") {
                candidates.push(values[String(metadata.v)]);
            }
            if (metadata.value && typeof metadata.value === "object") {
                candidates.push(metadata.value);
            }
            candidates.push(metadata);

            for (const candidate of candidates) {
                if (
                    candidate &&
                    hasOwn(candidate, "enable_i18n")
                ) {
                    return candidate;
                }
            }
        }

        return null;
    };

    let layerPatched = patchExistingLayer();
    if (!layerPatched && !noBootstrap) {
        payload.has_updates = true;
        payload.layer_configs = payload.layer_configs || {};

        if (payload.response_format === "init-v2" || payload.values) {
            payload.response_format = "init-v2";
            payload.values = payload.values || {};
            let index = 0;
            while (hasOwn(payload.values, String(index))) index += 1;
            payload.values[String(index)] = {
                enable_i18n: true,
                locale_source: "SYSTEM"
            };
            payload.layer_configs[targetLayer] = {
                v: String(index),
                r: "codex-current-key",
                s: [],
                is_device_based: true
            };
        }
        else {
            payload.layer_configs[targetLayer] = {
                enable_i18n: true,
                locale_source: "SYSTEM"
            };
        }
        layerPatched = true;
    }

    if (!layerPatched) {
        return JSON.stringify({
            ok: false,
            error: "The current cache payload has no target Layer and bootstrap is disabled.",
            currentCacheKey,
            allCacheKeys,
            staleCacheKeys,
            liveEnableI18n
        });
    }

    wrapper = wrapper || {};
    wrapper.source = wrapper.source || "Bootstrap";
    wrapper.data = dataWasString ? JSON.stringify(payload) : payload;
    wrapper.receivedAt = Date.now();
    wrapper.stableID = context.stableID ?? wrapper.stableID ?? null;
    wrapper.fullUserHash = wrapper.fullUserHash ?? null;

    const serialized = JSON.stringify(wrapper);
    localStorage.setItem(currentCacheKey, serialized);

    const savedWrapper = JSON.parse(localStorage.getItem(currentCacheKey));
    const savedPayload = typeof savedWrapper.data === "string"
        ? JSON.parse(savedWrapper.data)
        : savedWrapper.data;
    const savedValue = findCachedI18nValue(savedPayload);

    return JSON.stringify({
        ok: Boolean(savedValue && savedValue.enable_i18n === true),
        mode: "write",
        origin: location.origin,
        href: location.href,
        htmlLang: document.documentElement.lang,
        statsigStatus: client.loadingStatus,
        currentCacheKey,
        currentCacheKeyExists: currentCacheValue !== null,
        seededFrom,
        liveEnableI18n,
        cachedEnableI18n: savedValue?.enable_i18n ?? null,
        cachedLocaleSource: savedValue?.locale_source ?? null,
        allCacheKeys,
        staleCacheKeys,
        staleCachesModified: false
    });
})()
'@

$effectiveExpression = $pageExpression.Replace(
    '__INSPECT_ONLY__',
    $(if ($InspectOnly) { 'true' } else { 'false' })
).Replace(
    '__NO_BOOTSTRAP__',
    $(if ($NoBootstrap) { 'true' } else { 'false' })
).Replace(
    '__READY_TIMEOUT_MS__',
    [string]([Math]::Min(60000, $TimeoutSeconds * 1000))
)

$debugPort = Resolve-DebugPort
Write-Host "Connecting to Codex main page on 127.0.0.1:$debugPort..."
$target = Wait-CdpTarget -DebugPort $debugPort -WaitSeconds $TimeoutSeconds
$webSocketUrl = Get-WebSocketUrl -Target $target
$rawResult = Invoke-CdpExpression `
    -WebSocketUrl $webSocketUrl `
    -Expression $effectiveExpression `
    -WaitSeconds $TimeoutSeconds

$cleanResult = @($rawResult) |
    Where-Object { $_ -is [string] } |
    Select-Object -Last 1

if ([string]::IsNullOrWhiteSpace($cleanResult)) {
    throw 'The Codex main page did not return a JSON result.'
}

$result = $cleanResult | ConvertFrom-Json
$result | Format-List

if (-not $result.ok) {
    $errorProperty = $result.PSObject.Properties['error']
    if ($null -ne $errorProperty) {
        throw [string]$errorProperty.Value
    }
    throw 'Current-cache operation failed.'
}

if ($InspectOnly) {
    Write-Host 'Inspection only: no cache values were modified.'
    return
}

Write-Host ''
Write-Host "Current client cache key: $($result.currentCacheKey)"
Write-Host "Cached enable_i18n: $($result.cachedEnableI18n)"
Write-Host "Stale cache keys left untouched: $(@($result.staleCacheKeys).Count)"

if ($RestartAfterSuccess) {
    Write-Host "Reloading the Codex page to verify cache key persistence..."
    $persistence = Confirm-CurrentCacheAfterReload `
        -DebugPort $debugPort `
        -CurrentCacheKey $result.currentCacheKey `
        -TimeoutSeconds $TimeoutSeconds
    Write-Host "Cache persistence verified: $($persistence.cachedEnableI18n)"

    Write-Host 'Stopping the debugging instance and restarting Codex normally...'
    Stop-CodexRuntimeProcesses
    Start-CodexNormally
    Write-Host 'Codex restarted normally with the current-key cache.'
}
else {
    Write-Host 'Completely exit Codex, then start it normally to load the current-key cache.'
}
