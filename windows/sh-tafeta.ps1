<#
.SYNOPSIS
    sh-tafeta for Windows Terminal: one tab per tmux session, in WSL or on a remote host.

.DESCRIPTION
    WSL (default): starts tmux inside WSL, restores the saved sessions (with the
    WSL clock-jump workaround when sh-tafeta is installed in WSL), then opens one
    Windows Terminal tab per session. Claude Code panes come back with their own
    conversation thanks to the tmux side of sh-tafeta.

    Remote host: lists the tmux sessions on an SSH host and opens one tab per
    session, over ssh or mosh (mosh runs from WSL).

    https://github.com/ScIEnzY/sh-tafeta - MIT License

.EXAMPLE
    .\sh-tafeta.ps1
    .\sh-tafeta.ps1 -Target devbox
    .\sh-tafeta.ps1 -Target devbox -Transport mosh
    .\sh-tafeta.ps1 -Target devbox -ListOnly
    .\sh-tafeta.ps1 -Target devbox -Transport mosh -InstallShortcut
    .\sh-tafeta.ps1 -InstallShortcut -Startup                 # run `sh-tafeta autostart` at login
    .\sh-tafeta.ps1 -Target devbox -InstallProfile            # Windows Terminal dropdown entry
    .\sh-tafeta.ps1 -Target '*' -Remove                       # remove shortcuts and profiles
    .\sh-tafeta.ps1 -Target devbox -Shots                     # tabs, then send new screenshots to devbox
    .\sh-tafeta.ps1 -ShotsOnly -ShotsTarget devbox            # only the screenshot bridge
    .\sh-tafeta.ps1 -Target devbox -Shots -ShotsFrom clipboard # Win+Shift+S only, no folder
#>
[CmdletBinding()]
param(
    # 'wsl' or an SSH host (an alias from your ssh config works best)
    [string]$Target = 'wsl',
    # WSL distribution to use (default distribution if empty)
    [string]$Distro = '',
    # Remote transport: ssh and mosh run inside WSL (one ssh config, one set of keys);
    # winssh uses Windows' own OpenSSH (for machines without WSL)
    [ValidateSet('ssh', 'mosh', 'winssh')]
    [string]$Transport = 'ssh',
    # Only list the sessions, don't open tabs
    [switch]$ListOnly,
    # Keep the tab titles set here instead of letting tmux change them
    [switch]$KeepTitles,
    # Don't wait for a key press at the end
    [switch]$NoPause,
    # Create a desktop shortcut that runs this script with the same options
    [switch]$InstallShortcut,
    # With -InstallShortcut: put it in the Startup folder (runs at login) instead
    [switch]$Startup,
    # Add an entry to the Windows Terminal dropdown (a JSON fragment, not your settings.json)
    [switch]$InstallProfile,
    # Remove the shortcuts and dropdown entries for -Target ('*' = all of them)
    [switch]$Remove,
    # Windows Terminal window to open the tabs in (0 = most recent)
    # Windows Terminal window for the tabs: by default one named after the target, so the
    # tabs land together even when another window (e.g. a minimized one at login) is newer
    [string]$WtWindow = '',
    # After opening the tabs, keep running as the screenshot bridge: every new image in
    # -ShotsFolder is delivered to -ShotsTarget and its path put on the clipboard
    [switch]$Shots,
    # Only the screenshot bridge, no tabs (e.g. in the background from login)
    [switch]$ShotsOnly,
    # Folder to watch (default: Pictures\Screenshots, where Windows saves screenshots)
    [string]$ShotsFolder = '',
    # Where Claude Code runs: 'wsl' or an SSH host (default: -Target)
    [string]$ShotsTarget = '',
    # What the bridge watches: the clipboard (Win+Shift+S, nothing to save), the folder, or both
    [ValidateSet('both', 'clipboard', 'folder')]
    [string]$ShotsFrom = 'both',
    # Stop a screenshot bridge running in the background
    [switch]$StopShots
)

# non-ASCII paths and names come back from wsl.exe/ssh as UTF-8
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
$BootSession = '_shtafeta_boot'
$IsLocal = $Target -eq 'wsl'
$NoiseCommands = @('bash', 'zsh', 'sh', 'fish', 'dash', 'login', 'tmux', '-bash', 'mosh-server', 'sshd')
$HomeMarker = '__SHTAFETA_HOME__'

function Write-Step([string]$Text, [string]$Color = 'Gray') { Write-Host "  $Text" -ForegroundColor $Color }

function Wait-Exit([int]$Code = 0) {
    if (-not $NoPause) {
        Write-Host ''
        Write-Host '  Press any key to close.'
        try { $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown') } catch { }
    }
    exit $Code
}

function Get-WslArgs { if ($Distro) { return @('-d', $Distro) } return @() }

function Invoke-Wsl([string]$Command) {
    $wslArgs = @(Get-WslArgs) + @('-e', 'bash', '-lc', $Command)
    & wsl.exe @wslArgs
}

function Invoke-Remote([string]$Command) {
    if ($Transport -eq 'winssh') {
        & ssh.exe -o ConnectTimeout=10 -o BatchMode=yes -o ClearAllForwardings=yes $Target $Command
    } else {
        # WSL's ssh: same keys and ssh config as everything else.
        # base64 avoids PowerShell 5.1 mangling nested quotes on native command lines.
        $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
        Invoke-Wsl ("ssh -o ConnectTimeout=10 -o BatchMode=yes -o ClearAllForwardings=yes '{0}' 'echo {1} | base64 -d | sh'" -f $Target, $b64)
    }
}

# Sessions are attached by their tmux id ($N), never by name: a name is free text.
# Name, command and path are only used for the tab title, after Format-Title.
$ListFormat = '#{session_id}|#{session_windows}|#{session_attached}|#{session_name}|#{pane_current_command}|#{session_path}'
$ListCommand = "printf '$HomeMarker|%s\n' `$HOME; tmux list-sessions -F '$ListFormat' 2>/dev/null"

function Get-Sessions([string]$Prefix = '') {
    $cmd = $Prefix + $ListCommand
    $raw = if ($IsLocal) { Invoke-Wsl $cmd } else { Invoke-Remote $cmd }
    $script:RemoteHome = ''
    $list = @()
    foreach ($line in @($raw)) {
        if (-not $line -or $line -notmatch '\S') { continue }
        $p = $line -split '\|', 6
        if ($p[0] -ceq $HomeMarker) { $script:RemoteHome = $p[1]; continue }
        if ($p.Count -lt 6 -or $p[0] -cnotmatch '^\$[0-9]+$' -or $p[3] -ceq $BootSession) { continue }
        $list += [PSCustomObject]@{
            Id       = $p[0]
            Windows  = if ($p[1] -match '^[0-9]+$') { [int]$p[1] } else { 1 }
            Attached = ($p[2] -match '^[0-9]+$') -and [int]$p[2] -gt 0
            Name     = $p[3]
            Command  = $p[4]
            Path     = $p[5]
        }
    }
    return $list
}

# Keep titles to harmless characters: wt.exe treats ';' as a command separator and
# PowerShell 5.1 mangles quotes on native command lines.
function Format-Title([string]$Text) {
    $t = $Text -replace '[^A-Za-z0-9 _.,:()\[\]@+#=-]', '_'
    if ($t.Length -gt 60) { $t = $t.Substring(0, 60) }
    return $t
}

function Get-TabTitle($s) {
    $leaf = if ($s.Path -and $s.Path -ne $script:RemoteHome) { ($s.Path -split '/')[-1] } else { '' }
    if ($s.Name -match '^\d+$') {
        # default numeric tmux names say nothing: lead with the folder
        $title = if ($leaf) { "$leaf [$($s.Name)]" } else { "home [$($s.Name)]" }
    } else {
        $title = $s.Name
        if ($leaf -and $leaf -ne $s.Name) { $title = "$($s.Name) ($leaf)" }
    }
    if ($s.Command -and ($NoiseCommands -notcontains $s.Command.ToLower())) { $title += " - $($s.Command)" }
    if ($s.Windows -gt 1) { $title += " [$($s.Windows)w]" }
    if (-not $IsLocal) { $title = "${Target}: $title" }
    return (Format-Title $title)
}

function Open-Tab($s) {
    $title = Get-TabTitle $s
    $win = $WtWindow
    if (-not $win) { $win = 'sh-tafeta-' + ((Format-Title $Label) -replace '[^A-Za-z0-9_-]', '_') }
    $wtArgs = @('-w', $win, 'new-tab', '--title', $title)
    if ($KeepTitles) { $wtArgs += '--suppressApplicationTitle' }
    $attach = "tmux attach-session -t '$($s.Id)'"
    if ($IsLocal) {
        $wtArgs += @('--', 'wsl.exe') + @(Get-WslArgs) + @('-e', 'bash', '-lc', $attach)
    } elseif ($Transport -eq 'ssh') {
        # -d: detach stale clients left behind by a dropped connection
        # no shell in between: the remote shell gets "tmux attach-session -d -t '$N'" intact
        $wtArgs += @('--', 'wsl.exe') + @(Get-WslArgs) + @('-e', 'ssh', '-t', $Target, "tmux attach-session -d -t '$($s.Id)'")
    } elseif ($Transport -eq 'winssh') {
        $wtArgs += @('--', 'ssh.exe', '-t', $Target, "tmux attach-session -d -t '$($s.Id)'")
    } else {
        $mosh = "MOSH_TITLE_NOPREFIX=1 mosh --server='MOSH_SERVER_NETWORK_TMOUT=86400 mosh-server' '$Target' -- tmux attach-session -d -t '$($s.Id)'"
        $wtArgs += @('--', 'wsl.exe') + @(Get-WslArgs) + @('-e', 'bash', '-lc', $mosh)
    }
    Write-Step "tab: $title" 'DarkCyan'
    & wt.exe @wtArgs
    if ($LASTEXITCODE -ne 0) { throw "wt.exe failed (exit $LASTEXITCODE)" }
    if (-not $script:WtReady) {
        # Right after login Windows Terminal isn't running yet, and requests that arrive
        # while it starts are dropped: wait for its window before asking for more tabs.
        for ($i = 0; $i -lt 60; $i++) {
            $p = Get-Process WindowsTerminal -ErrorAction SilentlyContinue | Where-Object { $_.MainWindowHandle -ne 0 }
            if ($p) { break }
            Start-Sleep -Milliseconds 250
        }
        Start-Sleep -Milliseconds 1500
        $script:WtReady = $true
    }
    Start-Sleep -Milliseconds 400   # keeps the tabs in order
}

# --- screenshot bridge ---
$ShotExt = @('.png', '.jpg', '.jpeg', '.gif', '.webp', '.bmp')
$ShotsPidFile = Join-Path $env:LOCALAPPDATA 'sh-tafeta\shots.pid'

function Get-ShotsFolder {
    if ($ShotsFolder) { return $ShotsFolder.TrimEnd('\\') }
    return Join-Path ([Environment]::GetFolderPath('MyPictures')) 'Screenshots'
}

function Get-ShotsTarget { if ($ShotsTarget) { return $ShotsTarget } return $Target }

# true once the file exists, is not empty, can be opened exclusively and stopped growing
function Wait-FileReady([string]$Path) {
    $last = -1
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep -Milliseconds 250
        try {
            $fs = [IO.File]::Open($Path, 'Open', 'Read', 'None')
            $len = $fs.Length
            $fs.Close()
            if ($len -gt 0 -and $len -eq $last) { return $true }
            $last = $len
        } catch { }
    }
    return $false
}

# Put text on the clipboard; with -Image the image stays there too, so pasting into a
# document still gives the picture while a terminal pastes the path.
function Set-ClipboardPath([string]$Text, $Image) {
    for ($i = 0; $i -lt 10; $i++) {
        try {
            if ($Image) {
                $do = New-Object System.Windows.Forms.DataObject
                $do.SetImage($Image)
                $do.SetText($Text)
                [System.Windows.Forms.Clipboard]::SetDataObject($do, $true)
            } else {
                [System.Windows.Forms.Clipboard]::SetText($Text)
            }
            return $true
        } catch { Start-Sleep -Milliseconds 100 }   # another app holds the clipboard
    }
    return $false
}

# Deliver one image through sh-tafeta in WSL (same ssh config and keys as everything
# else); WSLENV hands the path over already translated (/p), so no quoting is involved.
# Returns the path on the target, or $null.
function Send-Shot([string]$Path, [string]$To, $Notify, $Image, $ExpectSeq = $null) {
    $env:SHT_SHOT_FILE = $Path
    $env:SHT_SHOT_TARGET = $To
    $extra = 'SHT_SHOT_FILE/p:SHT_SHOT_TARGET'
    $env:WSLENV = if ($script:OrigWslEnv) { $script:OrigWslEnv + ':' + $extra } else { $extra }
    $wslArgs = @(Get-WslArgs) + @('-e', 'bash', '-lc', 'sh-tafeta shot')
    $out = @(& wsl.exe @wslArgs 2>&1)
    $code = $LASTEXITCODE
    # sh-tafeta prints the path it delivered as the last line starting with '/'
    $dest = @($out | Where-Object { "$_" -match '^/[^\x00-\x1f]*$' }) | Select-Object -Last 1
    $name = Split-Path $Path -Leaf
    if ($code -eq 0 -and $dest) {
        if ($null -ne $ExpectSeq -and [ShTafeta.Clip]::GetClipboardSequenceNumber() -ne $ExpectSeq) {
            # you copied something else while it was uploading: leave your clipboard alone
            Write-Step "$name -> $dest  (clipboard changed meanwhile: path NOT copied)" 'Yellow'
            if ($Notify) { $Notify.ShowBalloonTip(3000, 'sh-tafeta', "Screenshot sent to ${To} (clipboard left as you changed it)", 'Info') }
            return "$dest"
        }
        if (Set-ClipboardPath "$dest" $Image) {
            Write-Step "$name -> $dest  (path copied: Ctrl+V in Claude Code)" 'Green'
            if ($Notify) { $Notify.ShowBalloonTip(3000, 'sh-tafeta', "Screenshot sent to ${To}: Ctrl+V pastes its path", 'Info') }
            return "$dest"
        }
    }
    Write-Step "$name -> FAILED: $(($out | Select-Object -Last 1))" 'Red'
    if ($Notify) { $Notify.ShowBalloonTip(5000, 'sh-tafeta', "Screenshot NOT sent to $To", 'Error') }
    return $null
}

function Get-ImageSize([string]$Path) {
    try {
        $img = [System.Drawing.Image]::FromFile($Path)
        $size = "$($img.Width)x$($img.Height)"
        $img.Dispose()
        return $size
    } catch { return '' }
}

function Start-ShotsBridge {
    $to = Get-ShotsTarget
    $folder = Get-ShotsFolder
    $useFolder = $ShotsFrom -ne 'clipboard'
    $useClip = $ShotsFrom -ne 'folder'
    $mutex = New-Object System.Threading.Mutex($false, 'Local\sh-tafeta-shots')
    if (-not $mutex.WaitOne(0)) {
        Write-Step 'Screenshots: a bridge is already running (only one at a time).' 'Yellow'
        return
    }
    $script:OrigWslEnv = $env:WSLENV
    New-Item -ItemType Directory -Force -Path (Split-Path $ShotsPidFile) | Out-Null
    Set-Content -Path $ShotsPidFile -Value $PID
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    if (-not ('ShTafeta.Clip' -as [type])) {
        Add-Type -Namespace ShTafeta -Name Clip -MemberDefinition '[DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();'
    }
    # clipboard screenshots are saved here before they are sent (kept one day)
    $clipDir = Join-Path $env:LOCALAPPDATA 'sh-tafeta\clipboard'
    New-Item -ItemType Directory -Force -Path $clipDir | Out-Null
    Get-ChildItem $clipDir -Filter *.png -ErrorAction SilentlyContinue |
        Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -ErrorAction SilentlyContinue
    $notify = $null
    try {
        $notify = New-Object System.Windows.Forms.NotifyIcon
        $notify.Icon = [System.Drawing.SystemIcons]::Information
        $notify.Text = "sh-tafeta: screenshots -> $to"
        $notify.Visible = $true
    } catch { $notify = $null }
    $fsw = $null
    if ($useFolder) {
        if (-not (Test-Path $folder)) { New-Item -ItemType Directory -Force -Path $folder | Out-Null }
        $fsw = New-Object IO.FileSystemWatcher $folder
        $fsw.IncludeSubdirectories = $false
        $fsw.EnableRaisingEvents = $true
        Register-ObjectEvent $fsw Created -SourceIdentifier 'sht.created' | Out-Null
        Register-ObjectEvent $fsw Renamed -SourceIdentifier 'sht.renamed' | Out-Null
    }
    $from = @()
    if ($useClip) { $from += 'the clipboard (Win+Shift+S)' }
    if ($useFolder) { $from += "new images in $folder" }
    Write-Step "Screenshots: $($from -join ' and ') go to $to; Ctrl+V then pastes the path. Ctrl+C to stop." 'Cyan'
    $seen = @{}
    $lastSeq = [ShTafeta.Clip]::GetClipboardSequenceNumber()   # what is there now is old news
    $lastClip = $null                                            # size + time of the last clipboard shot
    try {
        $lastPrune = Get-Date
        while ($true) {
            Start-Sleep -Milliseconds 400
            if (((Get-Date) - $lastPrune).TotalHours -ge 1) {
                $lastPrune = Get-Date
                Get-ChildItem $clipDir -Filter *.png -ErrorAction SilentlyContinue |
                    Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-1) } | Remove-Item -ErrorAction SilentlyContinue
            }
            # --- clipboard: a fresh image with no text (Win+Shift+S, PrintScreen) ---
            if ($useClip) {
                $seq = [ShTafeta.Clip]::GetClipboardSequenceNumber()
                if ($seq -ne $lastSeq) {
                    $lastSeq = $seq
                    $img = $null
                    try {
                        if ([System.Windows.Forms.Clipboard]::ContainsImage() -and -not [System.Windows.Forms.Clipboard]::ContainsText()) {
                            $img = [System.Windows.Forms.Clipboard]::GetImage()
                        }
                    } catch { $img = $null }
                    if ($img) {
                        $file = Join-Path $clipDir ('Screenshot_{0}.png' -f (Get-Date -Format 'yyyy-MM-dd_HHmmss'))
                        $img.Save($file, [System.Drawing.Imaging.ImageFormat]::Png)
                        $lastClip = @{ Size = "$($img.Width)x$($img.Height)"; Time = Get-Date }
                        [void](Send-Shot $file $to $notify $img $seq)
                        $img.Dispose()
                        $lastSeq = [ShTafeta.Clip]::GetClipboardSequenceNumber()   # our own write
                    }
                }
            }
            # --- folder ---
            foreach ($e in @(Get-Event -ErrorAction SilentlyContinue)) {
                Remove-Event -EventIdentifier $e.EventIdentifier
                if ($e.SourceIdentifier -notlike 'sht.*') { continue }
                $path = $e.SourceEventArgs.FullPath
                if ($ShotExt -notcontains [IO.Path]::GetExtension($path).ToLower()) { continue }
                if ($seen.ContainsKey($path) -and ((Get-Date) - $seen[$path]).TotalSeconds -lt 15) { continue }
                $seen[$path] = Get-Date
                if (-not (Wait-FileReady $path)) { Write-Step "$path is still being written: skipped" 'Yellow'; continue }
                # the same snip saved after it was already sent from the clipboard
                if ($lastClip -and ((Get-Date) - $lastClip.Time).TotalSeconds -lt 120 -and (Get-ImageSize $path) -eq $lastClip.Size) {
                    Write-Step "$(Split-Path $path -Leaf): already sent from the clipboard" 'Gray'
                    continue
                }
                [void](Send-Shot $path $to $notify $null ([ShTafeta.Clip]::GetClipboardSequenceNumber()))
                $lastSeq = [ShTafeta.Clip]::GetClipboardSequenceNumber()
            }
        }
    } finally {
        if ($fsw) {
            Unregister-Event -SourceIdentifier 'sht.created' -ErrorAction SilentlyContinue
            Unregister-Event -SourceIdentifier 'sht.renamed' -ErrorAction SilentlyContinue
            $fsw.Dispose()
        }
        if ($notify) { $notify.Visible = $false; $notify.Dispose() }
        Remove-Item $ShotsPidFile -ErrorAction SilentlyContinue
        $mutex.ReleaseMutex()
        Write-Step 'Screenshots: stopped.' 'Gray'
    }
}

if ($StopShots) {
    $p = Get-Content $ShotsPidFile -ErrorAction SilentlyContinue
    $proc = $null
    if ($p -match '^[0-9]+$') { $proc = Get-CimInstance Win32_Process -Filter "ProcessId = $p" -ErrorAction SilentlyContinue }
    # the pid file may be stale and the number reused: only stop a process that is our bridge
    if ($proc -and $proc.Name -eq 'powershell.exe' -and $proc.CommandLine -like '*sh-tafeta.ps1*' -and $proc.CommandLine -like '*-Shots*') {
        Stop-Process -Id $p -Force
        Remove-Item $ShotsPidFile -ErrorAction SilentlyContinue
        Write-Step "screenshot bridge stopped (pid $p)" 'Green'
    } else {
        Remove-Item $ShotsPidFile -ErrorAction SilentlyContinue
        Write-Step 'no screenshot bridge running in the background' 'Gray'
    }
    exit 0
}

# --- shortcuts, Windows Terminal dropdown entries ---
# Shortcuts and dropdown entries start wsl.exe (signed by Microsoft) running
# `sh-tafeta open TARGET`, never PowerShell directly: a shortcut that runs
# "powershell -ExecutionPolicy Bypass -File ..." looks exactly like malware persistence
# to antivirus software. sh-tafeta then starts this script with the options it keeps
# in ~/.config/sh-tafeta (transport, screenshot bridge...).
$Label = if ($IsLocal) { 'WSL' } else { $Target }
$Fragment = Join-Path $env:LOCALAPPDATA 'Microsoft\Windows Terminal\Fragments\sh-tafeta\sh-tafeta.json'
$WslExe = Join-Path $env:WINDIR 'System32\wsl.exe'

function Get-WslCommand([string]$ShCommand) {
    $a = ''
    if ($Distro) { $a = "-d $Distro " }
    return $a + "-e bash -lc `"$ShCommand`""
}

function Get-Icon {
    # WSL penguin for local sessions, the Remote Desktop icon for remote hosts
    if ($IsLocal -or $Startup) { return $WslExe + ',0' }
    return (Join-Path $env:WINDIR 'System32\mstsc.exe') + ',0'
}

function Read-Fragment {
    if (Test-Path $Fragment) {
        try { return (Get-Content $Fragment -Raw | ConvertFrom-Json) } catch { }
    }
    return [PSCustomObject]@{ profiles = @() }
}

function Write-Fragment($doc) {
    $list = @($doc.profiles)
    if ($list.Count -eq 0) {
        if (Test-Path $Fragment) { Remove-Item (Split-Path $Fragment) -Recurse -Force }
        return
    }
    New-Item -ItemType Directory -Force -Path (Split-Path $Fragment) | Out-Null
    $json = ConvertTo-Json -InputObject @{ profiles = $list } -Depth 5
    [IO.File]::WriteAllText($Fragment, $json, (New-Object Text.UTF8Encoding($false)))
}

if ($Remove) {
    $desk = [Environment]::GetFolderPath('Desktop')
    $start = [Environment]::GetFolderPath('Startup')
    $files = @(Get-ChildItem -Path $desk -Filter "sh-tafeta - $Label.lnk" -ErrorAction SilentlyContinue)
    if ($Target -eq '*' -or $Startup) {
        $files += @(Get-ChildItem -Path $start -Filter 'sh-tafeta*.lnk' -ErrorAction SilentlyContinue)
    }
    foreach ($f in $files) { Remove-Item $f.FullName -Force; Write-Step "removed $($f.FullName)" 'Green' }
    if (-not $Startup) {
        $doc = Read-Fragment
        $doc.profiles = @($doc.profiles | Where-Object { $_.name -notlike "sh-tafeta: $Label" })
        Write-Fragment $doc
    }
    exit 0
}

if ($InstallShortcut) {
    $shell = New-Object -ComObject WScript.Shell
    if ($Startup) {
        # one login entry: sh-tafeta autostart does what ~/.config/sh-tafeta/windows.conf says
        $path = Join-Path ([Environment]::GetFolderPath('Startup')) 'sh-tafeta.lnk'
        $lnkArgs = Get-WslCommand 'sh-tafeta autostart'
    } else {
        $path = Join-Path ([Environment]::GetFolderPath('Desktop')) "sh-tafeta - $Label.lnk"
        $lnkArgs = Get-WslCommand "sh-tafeta open $Target"
    }
    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath = $WslExe
    $lnk.Arguments = $lnkArgs
    $lnk.IconLocation = Get-Icon
    $lnk.WindowStyle = if ($Startup) { 7 } else { 1 }   # minimized at login
    $lnk.Description = 'sh-tafeta: reopen your tmux and Claude Code sessions'
    $lnk.Save()
    Write-Step "shortcut: $path" 'Green'
    exit 0
}

if ($InstallProfile) {
    $name = "sh-tafeta: $Label"
    # stable GUID from the name, so re-running updates the same entry
    $md5 = [Security.Cryptography.MD5]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($name))
    $guid = '{' + ([guid]::new($md5)).ToString() + '}'
    $doc = Read-Fragment
    $others = @($doc.profiles | Where-Object { $_.name -ne $name })
    $entry = [PSCustomObject]@{
        name        = $name
        guid        = $guid
        commandline = 'wsl.exe ' + (Get-WslCommand "sh-tafeta open $Target --no-pause")
        icon        = Get-Icon
        closeOnExit = 'always'
    }
    $doc.profiles = @($others) + $entry
    Write-Fragment $doc
    Write-Step "Windows Terminal entry: $name (restart Windows Terminal to see it)" 'Green'
    exit 0
}

# --- main ---
try { $Host.UI.RawUI.WindowTitle = if ($ShotsOnly) { 'sh-tafeta: screenshot bridge' } elseif ($Shots) { "sh-tafeta: $Label (screenshot bridge)" } else { "sh-tafeta: $Label" } } catch { }
if ($ShotsOnly) {
    Start-ShotsBridge
    exit 0
}

# with -Shots this window becomes the screenshot bridge instead of waiting for a key
function Finish([int]$Code) {
    if ($Shots) { Write-Host ''; Start-ShotsBridge; exit $Code }
    Wait-Exit $Code
}

Write-Host ''
Write-Host '  sh-tafeta' -ForegroundColor Cyan -NoNewline
if ($IsLocal) {
    $d = if ($Distro) { $Distro } else { 'default distro' }
    Write-Host "  WSL ($d)" -ForegroundColor Gray
} else {
    Write-Host "  $Target via $Transport" -ForegroundColor Gray
}
Write-Host ''

if (-not $ListOnly -and -not (Get-Command wt.exe -ErrorAction SilentlyContinue)) {
    Write-Step 'Windows Terminal (wt.exe) not found: install it from the Microsoft Store or winget.' 'Red'
    Wait-Exit 1
}

# WSL: one wsl.exe call restores tmux (sh-tafeta restore works around the WSL clock
# jump) and lists the sessions.
$prefix = ''
if ($IsLocal) {
    $prefix = '{ if command -v sh-tafeta >/dev/null 2>&1; then sh-tafeta restore; else tmux has-session 2>/dev/null || tmux new-session -d -s main; fi; } >&2; '
}
$sessions = @(Get-Sessions $prefix)
if ($sessions.Count -eq 0) {
    if ($IsLocal) { Write-Step 'Could not start tmux in WSL.' 'Red' }
    else { Write-Step "No tmux sessions on $Target (or the host is unreachable)." 'Yellow' }
    Finish 1
}

Write-Step "$($sessions.Count) session(s):" 'Green'
foreach ($s in $sessions) {
    $mark = if ($s.Attached) { '*' } else { ' ' }
    Write-Step ("{0} {1,-24} {2}" -f $mark, (Format-Title $s.Name), (Get-TabTitle $s)) 'White'
}
Write-Host ''

if (-not $ListOnly) {
    try {
        foreach ($s in $sessions) { Open-Tab $s }
    } catch {
        Write-Step "Could not open the tabs: $_" 'Red'
        Finish 1
    }
    Write-Host ''
    Write-Step 'All sessions attached.' 'Green'
}
Finish 0
