<#
.SYNOPSIS
    captantan fork of Sunshine: make Virtual Display Driver (VDD) offer the connecting client's mode.

.DESCRIPTION
    Sunshine runs this through the pre_display_cmd option, before it sets up the display, with
    SUNSHINE_CLIENT_WIDTH, SUNSHINE_CLIENT_HEIGHT and SUNSHINE_CLIENT_FPS set.

    If vdd_settings.xml lacks the resolution, it is added to <resolutions>. If the refresh rate is
    missing from the <global> list (which applies to every resolution) and from that resolution's
    own entry, it is added to the <global> list. After a change the VDD device is restarted, because
    the driver reads the file only when the device starts (its RELOAD_DRIVER pipe command does not
    re-read it), and the script waits until the virtual monitor is back.

    Exit code 0 means the mode is offered; any other code makes Sunshine abort the launch.
    Exit codes: 1 bad input, 2 settings file problem, 3 no VDD device, 4 restart failed, 5 busy.

    With -Disable (Sunshine's post_display_cmd, after it has restored the displays or failed to)
    it disables the VDD device, so Windows has no second screen between streams; the next normal
    run enables it again. It does nothing if a normal run finished less than -SkipIfPreparedWithin
    seconds ago, because that means a launch is using VDD right now. Its exit code is only logged.

    Runs as SYSTEM under the Sunshine service. Can also be run by hand from an elevated
    PowerShell, for example:  .\vdd-prepare.ps1 -Width 2960 -Height 1848 -Fps 120

    See CAPTANTAN.md in https://github.com/captantan/Sunshine
#>
[CmdletBinding()]
param(
    [int]$Width = $env:SUNSHINE_CLIENT_WIDTH,
    [int]$Height = $env:SUNSHINE_CLIENT_HEIGHT,
    [int]$Fps = $env:SUNSHINE_CLIENT_FPS,
    # Default: Sunshine's config folder, next to sunshine.log (only admins can change it).
    [string]$LogDir,
    [int]$TimeoutSeconds = 45,
    [int]$SettleSeconds = 2,
    [switch]$ForceRestart,
    # For tests: use this file instead of the driver's, and only edit it (no device restart).
    [string]$SettingsPath,
    [switch]$NoRestart,
    # Sunshine's post_display_cmd: disable the VDD device until the next stream.
    [switch]$Disable,
    [int]$SkipIfPreparedWithin = 15
)

$ErrorActionPreference = 'Stop'
if (-not $LogDir) {
    # Not a parameter default: Windows PowerShell 5.1 leaves $PSScriptRoot empty there under -File,
    # which is how Sunshine runs this script.
    $here = $PSScriptRoot
    if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
    $LogDir = Join-Path $here '..\..\config'
}
$LogDir = [System.IO.Path]::GetFullPath($LogDir)
$LogFile = Join-Path $LogDir 'vdd-prepare.log'
$PendingFile = Join-Path $LogDir 'vdd-prepare.restart-pending'
$OriginalCopy = Join-Path $LogDir 'vdd_settings.original.xml'
$PreparedFile = Join-Path $LogDir 'vdd-prepare.last-prepare'

function Write-Log([string]$Message) {
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $PID, $Message
    try { Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8 } catch { }
    Write-Host $line
}

function Exit-With([int]$Code, [string]$Message) {
    Write-Log $Message
    if (-not $Disable) {
        # Tells a -Disable run that a launch is using VDD right now.
        try { Set-Content -LiteralPath $PreparedFile -Value (Get-Date -Format o) } catch { }
    }
    Write-Log "exit $Code"
    exit $Code
}

function Test-Reparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue
    return ($item -and ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint))
}

function Get-IntList($Nodes) {
    $list = @()
    foreach ($n in $Nodes) {
        $v = 0
        if ([int]::TryParse($n.InnerText.Trim(), [ref]$v)) { $list += $v }
    }
    return , $list
}

# Insert a new element after the parent's last element, indented like the rest of the file.
function Add-Element([System.Xml.XmlElement]$Parent, [string]$Name, [string]$Text, [string]$Indent) {
    $doc = $Parent.OwnerDocument
    $el = $doc.CreateElement($Name)
    if ($Text) { $el.InnerText = $Text }
    $last = $null
    foreach ($c in $Parent.ChildNodes) {
        if ($c.NodeType -eq [System.Xml.XmlNodeType]::Element) { $last = $c }
    }
    if ($last) {
        [void]$Parent.InsertAfter($el, $last)
        [void]$Parent.InsertAfter($doc.CreateWhitespace("`r`n$Indent"), $last)
    } else {
        [void]$Parent.AppendChild($doc.CreateWhitespace("`r`n$Indent"))
        [void]$Parent.AppendChild($el)
        [void]$Parent.AppendChild($doc.CreateWhitespace("`r`n" + $Indent.Substring(0, [Math]::Max(0, $Indent.Length - 4))))
    }
    return $el
}

function Get-VddDevices {
    $all = @(Get-PnpDevice -Class Display -PresentOnly -ErrorAction SilentlyContinue)
    $vdd = @($all | Where-Object { $_.HardwareID -contains 'Root\MttVDD' })
    if ($vdd.Count -eq 0) {
        $vdd = @($all | Where-Object { $_.FriendlyName -match 'Virtual Display Driver' })
    }
    return , $vdd
}

function Get-VddMonitors($Device) {
    $kids = @()
    try {
        $kids = @((Get-PnpDeviceProperty -InstanceId $Device.InstanceId -KeyName 'DEVPKEY_Device_Children' -ErrorAction Stop).Data)
    } catch { }
    $mons = @()
    foreach ($k in $kids) {
        if (-not $k) { continue }
        $m = Get-PnpDevice -InstanceId $k -ErrorAction SilentlyContinue
        if ($m -and $m.Class -eq 'Monitor' -and $m.Status -eq 'OK') { $mons += $m }
    }
    return , $mons
}

# --- start ---------------------------------------------------------------------------------------

if (-not (Test-Path -LiteralPath $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }
if ((Test-Path -LiteralPath $LogFile) -and (Get-Item -LiteralPath $LogFile).Length -gt 1MB) {
    Move-Item -LiteralPath $LogFile -Destination "$LogFile.old" -Force
}

$who = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
if ($Disable) {
    Write-Log ("start: disable (display settings restored: {0}) as {1}" -f $env:SUNSHINE_DISPLAY_RESTORED, $who)
} else {
    Write-Log ("start: {0}x{1}@{2} HDR={3} client='{4}' as {5}" -f $Width, $Height, $Fps, $env:SUNSHINE_CLIENT_HDR, $env:SUNSHINE_CLIENT_NAME, $who)
}

if (-not $Disable -and ($Width -le 0 -or $Height -le 0 -or $Fps -le 0)) {
    Exit-With 1 'width, height or fps missing (SUNSHINE_CLIENT_* not set and no parameters given)'
}

# Two clients connecting at once must not restart the device under each other.
$mutex = New-Object System.Threading.Mutex($false, 'Global\captantan-vdd-prepare')
try {
    if (-not $mutex.WaitOne([TimeSpan]::FromSeconds(60))) { Exit-With 5 'another run is still busy after 60 s' }
} catch [System.Threading.AbandonedMutexException] {
    Write-Log 'previous run ended without releasing the lock; continuing'
}

if ($Disable) {
    try {
        if ($SkipIfPreparedWithin -gt 0 -and (Test-Path -LiteralPath $PreparedFile)) {
            $age = ((Get-Date) - (Get-Item -LiteralPath $PreparedFile).LastWriteTime).TotalSeconds
            if ($age -lt $SkipIfPreparedWithin) {
                Exit-With 0 ("a launch prepared VDD {0:N1} s ago; leaving it on" -f $age)
            }
        }
        $devices = Get-VddDevices
        if ($devices.Count -eq 0) { Exit-With 3 'no Virtual Display Driver device found (Root\MttVDD)' }
        $on = @($devices | Where-Object { $_.Status -eq 'OK' })
        if ($on.Count -eq 0) { Exit-With 0 'VDD already disabled' }
        foreach ($d in $on) {
            Write-Log "disabling $($d.InstanceId)"
            Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
        }
        $deadline = (Get-Date).AddSeconds(10)
        do {
            Start-Sleep -Milliseconds 250
            $still = @($on | Where-Object { (Get-PnpDevice -InstanceId $_.InstanceId -ErrorAction SilentlyContinue).Status -eq 'OK' })
        } until ($still.Count -eq 0 -or (Get-Date) -gt $deadline)
        if ($still.Count -gt 0) { Exit-With 4 'VDD still running 10 s after disabling it' }
        Exit-With 0 'VDD disabled until the next stream'
    } catch {
        Exit-With 4 ("failed: {0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
    } finally {
        try { $mutex.ReleaseMutex() } catch { }
    }
}

try {
    # The driver looks for its folder in this registry value first.
    $vddDir = 'C:\VirtualDisplayDriver'
    try {
        $p = (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\MikeTheTech\VirtualDisplayDriver' -Name VDDPATH -ErrorAction Stop).VDDPATH
        if ($p) { $vddDir = $p }
    } catch { }
    $settings = Join-Path $vddDir 'vdd_settings.xml'
    if ($SettingsPath) { $settings = [System.IO.Path]::GetFullPath($SettingsPath); $vddDir = Split-Path -Parent $settings }
    if (-not (Test-Path -LiteralPath $settings)) { Exit-With 2 "settings file not found: $settings" }
    if ((Test-Reparse $vddDir) -or (Test-Reparse $settings)) { Exit-With 2 "refusing to write through a link: $settings" }

    $devices = @()
    if (-not $NoRestart) {
        $devices = Get-VddDevices
        if ($devices.Count -eq 0) { Exit-With 3 'no Virtual Display Driver device found (Root\MttVDD)' }
    }
    $notOk = @($devices | Where-Object { $_.Status -ne 'OK' })

    $doc = New-Object System.Xml.XmlDocument
    $doc.XmlResolver = $null
    $doc.PreserveWhitespace = $true
    $doc.Load($settings)
    $root = $doc.DocumentElement
    if (-not $root -or $root.Name -ne 'vdd_settings') { Exit-With 2 "unexpected root element in $settings" }

    $globalNode = $root.SelectSingleNode('global')
    $globalRates = Get-IntList $root.SelectNodes('global/g_refresh_rate')
    $matching = @()
    foreach ($r in $root.SelectNodes('resolutions/resolution')) {
        $w = Get-IntList $r.SelectNodes('width')
        $h = Get-IntList $r.SelectNodes('height')
        if ($w.Count -eq 1 -and $h.Count -eq 1 -and $w[0] -eq $Width -and $h[0] -eq $Height) { $matching += $r }
    }
    $ownRates = @()
    foreach ($r in $matching) { $ownRates += Get-IntList $r.SelectNodes('refresh_rate') }

    $hasRes = $matching.Count -gt 0
    $hasRate = ($globalRates -contains $Fps) -or ($ownRates -contains $Fps)
    $pending = Test-Path -LiteralPath $PendingFile
    Write-Log ("file: resolution {0}, rate {1} (global: {2}); device: {3}; restart pending: {4}" -f `
        $(if ($hasRes) { 'present' } else { 'missing' }), $(if ($hasRate) { 'present' } else { 'missing' }),
        ($globalRates -join ','), (($devices | ForEach-Object { "$($_.InstanceId)=$($_.Status)" }) -join ' '), $pending)

    if ($hasRes -and $hasRate -and -not $pending -and $notOk.Count -eq 0 -and -not $ForceRestart) {
        Exit-With 0 'mode already offered; no restart needed'
    }

    if (-not ($hasRes -and $hasRate)) {
        if (-not (Test-Path -LiteralPath $OriginalCopy)) {
            Copy-Item -LiteralPath $settings -Destination $OriginalCopy
            Write-Log "kept the original file as $OriginalCopy"
        }
        if (-not $hasRate) {
            if (-not $globalNode) { $globalNode = Add-Element $root 'global' $null '    ' }
            [void](Add-Element $globalNode 'g_refresh_rate' ([string]$Fps) '        ')
            Write-Log "added global refresh rate $Fps"
        }
        if (-not $hasRes) {
            $list = $root.SelectSingleNode('resolutions')
            if (-not $list) { $list = Add-Element $root 'resolutions' $null '    ' }
            $res = Add-Element $list 'resolution' $null '        '
            # The driver needs width, height, refresh_rate in this order.
            foreach ($pair in @(@('width', $Width), @('height', $Height), @('refresh_rate', $Fps))) {
                [void]$res.AppendChild($doc.CreateWhitespace("`r`n            "))
                $c = $doc.CreateElement($pair[0]); $c.InnerText = [string]$pair[1]
                [void]$res.AppendChild($c)
            }
            [void]$res.AppendChild($doc.CreateWhitespace("`r`n        "))
            Write-Log "added resolution ${Width}x${Height} (refresh_rate $Fps)"
        }

        # Write a new file under a fresh name, then rename it over the old one.
        $tmp = Join-Path $vddDir ('vdd_settings.{0}.tmp' -f [guid]::NewGuid().ToString('N'))
        $ws = New-Object System.Xml.XmlWriterSettings
        $ws.Encoding = New-Object System.Text.UTF8Encoding($false)
        $writer = [System.Xml.XmlWriter]::Create($tmp, $ws)
        try { $doc.Save($writer) } finally { $writer.Close() }
        Set-Content -LiteralPath $PendingFile -Value (Get-Date -Format o)
        Move-Item -LiteralPath $tmp -Destination $settings -Force
        Write-Log "saved $settings"
    }

    if ($NoRestart) { Exit-With 0 'file checked; no restart (-NoRestart)' }

    # Restart the device so the driver reads the file again.
    $expected = 1
    $countNode = $root.SelectSingleNode('monitors/count')
    if ($countNode) { [void][int]::TryParse($countNode.InnerText.Trim(), [ref]$expected) }
    if ($expected -lt 1) { $expected = 1 }

    $started = Get-Date
    foreach ($d in $devices) {
        if ($d.Status -eq 'OK') {
            Write-Log "disabling $($d.InstanceId)"
            Disable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
        }
    }
    foreach ($d in $devices) {
        Write-Log "enabling $($d.InstanceId)"
        Enable-PnpDevice -InstanceId $d.InstanceId -Confirm:$false
    }

    $deadline = $started.AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Milliseconds 500
        $ready = $true
        $found = 0
        foreach ($d in $devices) {
            $cur = Get-PnpDevice -InstanceId $d.InstanceId -ErrorAction SilentlyContinue
            if (-not $cur -or $cur.Status -ne 'OK') { $ready = $false; continue }
            $found += (Get-VddMonitors $d).Count
        }
        if ($found -lt $expected) { $ready = $false }
    } until ($ready -or (Get-Date) -gt $deadline)

    if (-not $ready) {
        Exit-With 4 ("VDD not back after {0} s (monitors found: {1} of {2})" -f $TimeoutSeconds, $found, $expected)
    }
    Write-Log ("VDD back with {0} monitor(s) after {1:N1} s; settling {2} s" -f $found, ((Get-Date) - $started).TotalSeconds, $SettleSeconds)
    Start-Sleep -Seconds $SettleSeconds
    Remove-Item -LiteralPath $PendingFile -Force -ErrorAction SilentlyContinue
    Exit-With 0 'ready'
} catch {
    Exit-With 4 ("failed: {0} (line {1})" -f $_.Exception.Message, $_.InvocationInfo.ScriptLineNumber)
} finally {
    try { $mutex.ReleaseMutex() } catch { }
}
