# Cloud PC for Windows  (https://perchance.org/cloud-pc)
# ---------------------------------------------------------------------------
# Turns a throwaway GitHub Actions Windows runner into a Windows desktop that
# the Cloud PC page can show inside a phone or desktop browser.
#
#   Windows runner  ->  TightVNC (screen)  ->  noVNC + websockify (web viewer)
#                   ->  Cloudflare quick tunnel (public https address)
#
# The address of the desktop is published into this repository as
# cloud-pc-windows.json (status / url / password / session / timestamps) so the
# Cloud PC page can read it with your own GitHub token. The file is deleted
# again when the session ends.
#
# Nothing here is secret in a dangerous way, but please read:
#   * On a PUBLIC repository, cloud-pc-windows.json is readable by anyone while
#     the session runs - so treat this desktop as a throwaway machine. Don't
#     sign in to personal accounts in it, and press "End session" when done.
#   * The desktop lives only as long as this job (6 hours maximum) and every
#     byte of it disappears with the runner afterwards.
#
# You can safely edit this file - it is plain PowerShell, and everything it
# prints is prefixed with "cloud pc:" so you can find it in the job log.

$ErrorActionPreference = "Continue"
$ProgressPreference = "SilentlyContinue"

$script:StartedUtc = (Get-Date).ToUniversalTime()
$script:MaxMinutes = 350                 # the job itself is capped at 355 minutes
# NOTE: never call this $script:Home - PowerShell's own $HOME variable is
# read-only, so assigning to $script:Home throws and leaves it empty.
$script:RepoRoot = if ($env:GITHUB_WORKSPACE) { $env:GITHUB_WORKSPACE } else { (Get-Location).Path }
$script:StateName = if ($env:CLOUDPC_STATE) { $env:CLOUDPC_STATE } else { "cloud-pc-windows.json" }
$script:StatePath = Join-Path $script:RepoRoot $script:StateName
# A workflow token is handed in so the address can also be published through the
# GitHub REST API, which works even when the local git checkout is unusable.
$script:Token = "$env:CLOUDPC_TOKEN"
$script:RepoFullName = "$env:GITHUB_REPOSITORY"
$script:Pw = if ([string]::IsNullOrWhiteSpace($env:CLOUDPC_PASSWORD)) { "cloudpc" } else { $env:CLOUDPC_PASSWORD }
# VNC only ever uses the first 8 characters of a password, and the install command
# carries the password as an MSI property, so keep it to plain 8 characters here -
# the published password then always matches the one that really works.
$script:Pw = (($script:Pw -replace '[^A-Za-z0-9]', ''))
if (-not $script:Pw) { $script:Pw = "cloudpc" }
if ($script:Pw.Length -gt 8) { $script:Pw = $script:Pw.Substring(0, 8) }
$script:Session = if ($env:CLOUDPC_SESSION) { $env:CLOUDPC_SESSION } else { "local" }
# The workflow passes the repository's visibility in. Unless it says the
# repository is private, treat it as public: that way the password is never
# printed in the log or published in the state file when anybody could read them.
$script:PublicRepo = ($env:CLOUDPC_REPO_PRIVATE -ne "true")
$script:RunId = "$env:GITHUB_RUN_ID"
$script:RunUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
# The branch the page committed this workflow into; pushes go to it explicitly so
# the publish works even if checkout left us in a detached HEAD state.
$script:Branch = "$env:GITHUB_REF_NAME"
$script:TunnelUrl = ""
$script:VncPort = 5900
$script:WebPort = 6080
# TightVNC refuses connections that arrive on the loopback address unless
# "allow loopback" is switched on, and the install command below switches it on.
# So the viewer talks to 127.0.0.1 - the one address that is always reachable on
# the machine - and only falls back to the machine's own LAN address if the
# loopback connection is refused (a runner has several virtual network adapters,
# so guessing a LAN address is the less reliable option of the two).
$script:TargetHost = "127.0.0.1"
function Get-LanAddress {
  try {
    return (Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
            Where-Object { $_.IPAddress -notlike "127.*" -and $_.IPAddress -notlike "169.254.*" } |
            Select-Object -First 1).IPAddress
  } catch { return "" }
}
$script:NoVncDir = "C:\noVNC-1.7.0"
$script:CloudflaredExe = "C:\cloudflared.exe"
$script:CloudflaredLog = "C:\cloudflared.log"

function Note($m) { Write-Host ("cloud pc: {0}" -f $m) }
function Warn($m) { Write-Host ("cloud pc: WARNING: {0}" -f $m); Write-Host "::warning title=Cloud PC::$m" }
function Fail($m) { Write-Host ("cloud pc: ERROR: {0}" -f $m); Write-Host "::error title=Cloud PC::$m" }
function Announce($m) { Write-Host "::notice title=Cloud PC::$m" }

function Get-Web($url, $out, $tries = 3) {
  for ($i = 1; $i -le $tries; $i++) {
    try {
      Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -TimeoutSec 180
      if ((Test-Path $out) -and ((Get-Item $out).Length -gt 0)) { return $true }
      Note "the download of $url produced an empty file"
    } catch {
      Note ("download attempt {0} of {1} failed for {2}: {3}" -f $i, $tries, $url, $_.Exception.Message)
    }
    Start-Sleep -Seconds 5
  }
  return $false
}

function Test-PortOn($hostName, $port) {
  try {
    $client = New-Object Net.Sockets.TcpClient
    $ok = $client.BeginConnect($hostName, $port, $null, $null)
    $done = $ok.AsyncWaitHandle.WaitOne(2500)
    if ($done) { try { $client.EndConnect($ok) } catch { $done = $false } }
    $client.Close()
    return $done
  } catch { return $false }
}

function Test-Port($port) { return (Test-PortOn $script:TargetHost $port) }

function Test-DesktopReachable() {
  if (-not $script:TunnelUrl) { return $false }
  try {
    $r = Invoke-WebRequest -Uri ($script:TunnelUrl + "/vnc.html") -UseBasicParsing -TimeoutSec 25
    return ($r.StatusCode -eq 200)
  } catch { return $false }
}

function Get-RepoRoot {
  if ($script:RepoRoot -and (Test-Path $script:RepoRoot)) { return $script:RepoRoot }
  if ($env:GITHUB_WORKSPACE -and (Test-Path $env:GITHUB_WORKSPACE)) { return $env:GITHUB_WORKSPACE }
  return (Get-Location).Path
}

function Publish-ThroughApi([string]$message, [bool]$remove = $false) {
  # Second way of publishing, which does not need a working git checkout at all.
  if (-not $script:Token) { return $false }
  if (-not $script:RepoFullName -or $script:RepoFullName -notmatch "/") { return $false }
  $uri = "https://api.github.com/repos/$($script:RepoFullName)/contents/$($script:StateName)"
  $headers = @{
    Authorization          = "Bearer $($script:Token)"
    "User-Agent"           = "cloud-pc"
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
  }
  try {
    $sha = $null
    $getUri = $uri
    if ($script:Branch) { $getUri = $uri + "?ref=" + [uri]::EscapeDataString($script:Branch) }
    try {
      $cur = Invoke-RestMethod -Uri $getUri -Headers $headers -Method Get -TimeoutSec 30
      $sha = $cur.sha
    } catch { }
    if ($remove) {
      if (-not $sha) { Note "there is no published address to remove"; return $true }
      $body = @{ message = $message; sha = $sha }
      if ($script:Branch) { $body.branch = $script:Branch }
      Invoke-RestMethod -Uri $uri -Headers $headers -Method Delete -Body ($body | ConvertTo-Json -Compress) -ContentType "application/json" -TimeoutSec 30 | Out-Null
      Note "removed the published address through the GitHub API"
      return $true
    }
    if (-not (Test-Path $script:StatePath)) { return $false }
    $body = @{
      message = $message
      content = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($script:StatePath))
    }
    if ($script:Branch) { $body.branch = $script:Branch }
    if ($sha) { $body.sha = $sha }
    Invoke-RestMethod -Uri $uri -Headers $headers -Method Put -Body ($body | ConvertTo-Json -Compress) -ContentType "application/json" -TimeoutSec 30 | Out-Null
    Note "published the desktop address through the GitHub API"
    return $true
  } catch {
    Note "publishing through the GitHub API failed: $($_.Exception.Message)"
    return $false
  }
}

function Push-State([switch]$Remove) {
  $published = $false
  $message = if ($Remove) { "Cloud PC: end Windows session $($script:RunId)" } else { "Cloud PC: Windows session $($script:RunId)" }
  Push-Location (Get-RepoRoot)
  try {
    try {
      if ((& git rev-parse --is-inside-work-tree 2>$null | Out-String).Trim() -eq "true") {
        git config user.name "cloud-pc" 2>$null
        git config user.email "cloud-pc@users.noreply.github.com" 2>$null
        git add -- $script:StateName 2>$null
        git diff --cached --quiet 2>$null
        if ($LASTEXITCODE -eq 0) {
          Note "the published address is already up to date"
          $published = $true
        } else {
          git commit -q -m $message 2>$null
          for ($i = 1; $i -le 3; $i++) {
            if ($script:Branch) { git push -q origin "HEAD:$($script:Branch)" 2>&1 | Out-String | Write-Host }
            else { git push -q 2>&1 | Out-String | Write-Host }
            if ($LASTEXITCODE -eq 0) {
              if ($Remove) { Note "removed the published address from the repository" }
              else { Note "published the desktop address into the repository" }
              $published = $true
              break
            }
            Note "pushing to the repository failed (attempt $i) - retrying"
            if ($script:Branch) { git pull -q --rebase --autostash origin $script:Branch 2>$null }
            else { git pull -q --rebase --autostash 2>$null }
            Start-Sleep -Seconds 5
          }
        }
      } else {
        Note "this directory is not a git working tree - using the GitHub API instead"
      }
    } catch { Note "git could not be used here: $($_.Exception.Message)" }
  } finally { Pop-Location }
  if ($published) { return }
  if (Publish-ThroughApi $message $Remove) { return }
  if ($Remove) { Note "the published address could not be removed by this job - the Cloud PC page removes it again the next time you start or end a session" }
  else { Warn "could not publish the desktop address into the repository (the workflow may not have write permission). The address is: $($script:TunnelUrl) (password: $($script:Pw)) - note that this job log is public if the repository is public." }
}

function Remove-PublishedState {
  if (-not (Test-Path $script:StatePath)) {
    # Nothing to commit - but the published copy may still be in the repository,
    # so ask the API to delete it.
    Note "there is no local $($script:StateName) to remove - asking the GitHub API"
    Publish-ThroughApi "Cloud PC: end Windows session $($script:RunId)" $true | Out-Null
    return
  }
  try { Remove-Item $script:StatePath -Force -ErrorAction Stop }
  catch { Note "could not remove $($script:StateName): $($_.Exception.Message)" }
  Push-State -Remove
}

function Save-State([string]$status) {
  if (-not $script:TunnelUrl) { return }
  $obj = [ordered]@{
    status     = $status
    url        = $script:TunnelUrl
    viewer     = ($script:TunnelUrl + "/vnc.html")
    # On a public repository anybody can read this file, and the address plus the
    # password would be a working key to the desktop, so the password is only
    # published when the repository is private. The Cloud PC page keeps its own
    # copy of the password it generated, so it does not need this field.
    session    = $script:Session
    runId      = $script:RunId
    runUrl     = $script:RunUrl
    repository = "$env:GITHUB_REPOSITORY"
    startedAt  = $script:StartedUtc.ToString("o")
    updatedAt  = (Get-Date).ToUniversalTime().ToString("o")
    expiresAt  = $script:StartedUtc.AddMinutes($script:MaxMinutes).ToString("o")
    os         = (Get-CimInstance Win32_OperatingSystem).Caption
  }
  if (-not $script:PublicRepo) { $obj.password = $script:Pw }
  try { [System.IO.File]::WriteAllText($script:StatePath, ($obj | ConvertTo-Json -Compress)) }
  catch { Warn "could not write $($script:StateName): $($_.Exception.Message)"; return }
  Push-State
}

function Start-Tunnel {
  Get-Process cloudflared -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 2
  if (Test-Path $script:CloudflaredLog) { Remove-Item $script:CloudflaredLog -Force -ErrorAction SilentlyContinue }
  Note "opening a free Cloudflare tunnel to the viewer..."
  Start-Process -FilePath $script:CloudflaredExe `
    -ArgumentList "tunnel --url http://127.0.0.1:$($script:WebPort) --no-autoupdate" `
    -RedirectStandardError $script:CloudflaredLog -WindowStyle Hidden | Out-Null
  for ($i = 1; $i -le 45; $i++) {
    Start-Sleep -Seconds 2
    if (Test-Path $script:CloudflaredLog) {
      $text = Get-Content $script:CloudflaredLog -Raw -ErrorAction SilentlyContinue
      $m = [regex]::Match([string]$text, "https://[a-zA-Z0-9-]+\.trycloudflare\.com")
      if ($m.Success) {
        $script:TunnelUrl = $m.Value
        Note "tunnel ready: $($script:TunnelUrl)"
        return $true
      }
    }
  }
  return $false
}

# --- who am I, what am I running on --------------------------------------
try {
  $os = (Get-CimInstance Win32_OperatingSystem).Caption
  $cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
  $ram = [math]::Round((Get-CimInstance Win32_ComputerSystem).TotalPhysicalMemory / 1GB, 1)
  Note "host: $os / $cpu / ${ram} GB RAM"
} catch { Note "host: unknown" }
Note "session $($script:Session), run $($script:RunId), password set"

# --- keep the desktop awake and out of the way ---------------------------
try {
  Set-ItemProperty -Path "HKCU:\Control Panel\Desktop" -Name ScreenSaveActive -Value "0" -ErrorAction SilentlyContinue
  Set-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System" -Name InactivityTimeoutSecs -Value 0 -ErrorAction SilentlyContinue
  Get-Process ServerManager -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
  Get-ScheduledTask -TaskName "ServerManager" -ErrorAction SilentlyContinue | Disable-ScheduledTask -ErrorAction SilentlyContinue | Out-Null
  Note "asked Windows to stay awake (no screensaver, no auto-lock)"
} catch { Note "could not change the power/lock settings: $($_.Exception.Message)" }

# --- let the machine talk to itself --------------------------------------
try {
  New-NetFirewallRule -DisplayName "Cloud PC screen" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $script:VncPort -ErrorAction Stop | Out-Null
  New-NetFirewallRule -DisplayName "Cloud PC viewer" -Direction Inbound -Action Allow -Protocol TCP -LocalPort $script:WebPort -ErrorAction Stop | Out-Null
  Note "opened the local firewall for the screen port and the viewer port"
} catch { Note "could not add a firewall rule: $($_.Exception.Message)" }

# --- 1. the screen: TightVNC ---------------------------------------------
# The property names below are the ones TightVNC's own 2.8.88 MSI declares
# (checked against the installer's string table), so the silent install really
# does set the password, the port and "allow loopback" instead of silently
# ignoring them. SET_POLLINGINTERVAL keeps the screen fresh often enough to feel
# like a desktop rather than a slideshow, and SERVER_ALLOW_SAS lets a viewer send
# Ctrl+Alt+Del.
$tvnExe = "C:\Program Files\TightVNC\tvnserver.exe"
if (-not (Test-Path $tvnExe)) {
  $msi = Join-Path $env:TEMP "tightvnc.msi"
  Note "downloading TightVNC..."
  if (Get-Web "https://www.tightvnc.com/download/2.8.88/tightvnc-2.8.88-gpl-setup-64bit.msi" $msi) {
    $props = @(
      "ADDLOCAL=Server"
      "SET_USEVNCAUTHENTICATION=1", "VALUE_OF_USEVNCAUTHENTICATION=1"
      "SET_PASSWORD=1", "VALUE_OF_PASSWORD=$($script:Pw)"
      "SET_ALLOWLOOPBACK=1", "VALUE_OF_ALLOWLOOPBACK=1"
      "SET_RFBPORT=1", "VALUE_OF_RFBPORT=$($script:VncPort)"
      "SET_POLLINGINTERVAL=1", "VALUE_OF_POLLINGINTERVAL=100"
      "SERVER_REGISTER_AS_SERVICE=1"
      "SERVER_ADD_FIREWALL_EXCEPTION=1"
      "SERVER_ALLOW_SAS=1"
    ) -join " "
    Note "installing TightVNC (silent)..."
    Start-Process -FilePath "msiexec.exe" -Wait -ArgumentList "/i `"$msi`" /qn /norestart $props"
  } else {
    Fail "TightVNC could not be downloaded, so there is no screen to show."
  }
}

# Service mode mirrors the console session (the desktop the runner logs into),
# which is exactly what we want; if the service will not start we fall back to
# application mode, which serves the session this script runs in.
if (Get-Service -Name "tvnserver" -ErrorAction SilentlyContinue) {
  try { Start-Service -Name "tvnserver" -ErrorAction Stop; Note "TightVNC service started" }
  catch { Note "TightVNC service did not start: $($_.Exception.Message)" }
}
Start-Sleep -Seconds 3
if ((-not (Test-Port $script:VncPort)) -and (Test-Path $tvnExe)) {
  Note "no VNC server on port $($script:VncPort) yet - starting TightVNC in application mode"
  Start-Process -FilePath $tvnExe -ArgumentList "-run" -WindowStyle Hidden | Out-Null
  Start-Sleep -Seconds 4
}
if (-not (Test-Port $script:VncPort)) {
  # Loopback was refused. The usual reason is that TightVNC was already
  # installed and its "allow loopback" setting is still off, so try the
  # machine's own address before giving up.
  $lan = Get-LanAddress
  if ($lan -and (Test-PortOn $lan $script:VncPort)) {
    $script:TargetHost = $lan
    Note "the screen answers on the machine's own address ($lan) rather than on loopback - using that"
  }
}
if (Test-Port $script:VncPort) {
  Note "the screen is being served on port $($script:VncPort) (reached at $($script:TargetHost))"
} else {
  Fail "no VNC server is listening on port $($script:VncPort)."
  netstat -ano | Select-String ":5900" | ForEach-Object { Note ("netstat: " + $_.ToString()) }
}

# --- 2. the web viewer: noVNC + websockify -------------------------------
if (-not (Test-Path $script:NoVncDir)) {
  $zip = Join-Path $env:TEMP "novnc.zip"
  Note "downloading noVNC..."
  if (Get-Web "https://github.com/novnc/noVNC/archive/refs/tags/v1.7.0.zip" $zip) {
    try { Expand-Archive -Path $zip -DestinationPath "C:\" -Force; Note "noVNC unpacked to $($script:NoVncDir)" }
    catch { Fail "noVNC could not be unpacked: $($_.Exception.Message)" }
  } else {
    Fail "noVNC could not be downloaded."
  }
}
Note "installing websockify..."
python -m pip install --quiet --disable-pip-version-check --user websockify 2>&1 | Out-String | Write-Host
Start-Process -FilePath "python" `
  -ArgumentList "-m websockify --web `"$($script:NoVncDir)`" $($script:WebPort) $($script:TargetHost):$($script:VncPort)" `
  -WindowStyle Hidden | Out-Null
for ($i = 1; $i -le 20; $i++) {
  Start-Sleep -Seconds 1
  if (Test-Port $script:WebPort) { break }
}
if (Test-Port $script:WebPort) {
  Note "the web viewer is being served on port $($script:WebPort)"
} else {
  Fail "the web viewer did not start on port $($script:WebPort)."
}

# A tiny diagnostic page served by the same viewer: open
#   <the viewer address>/cloudpc-probe.html?p=<password>
# in a browser and it says whether the screen really answers, and (when it can)
# sends a picture of the current screen to the page that opened it. Only written
# when the workflow is started with the "probe" input, so a normal session never
# has it.
if ($env:CLOUDPC_PROBE -eq "true") {
  $probe = @'
<!doctype html><meta charset="utf-8"><title>cloud pc probe</title>
<style>html,body{margin:0;height:100%;background:#111}canvas{display:block;width:100%;height:100%}</style>
<canvas id="c"></canvas>
<script type="module">
const q = new URLSearchParams(location.search);
const tell = (status, shot) => { try { parent.postMessage({ cloudpc: "probe", status: status, shot: shot || null }, "*"); } catch (e) {} };
try {
  const mod = await import("./core/rfb.js");
  const rfb = new mod.default(document.getElementById("c"), "wss://" + location.host + "/websockify", { credentials: { password: q.get("p") || "" } });
  rfb.scaleViewport = true;
  rfb.addEventListener("connect", () => {
    tell("connected " + rfb._fbWidth + "x" + rfb._fbHeight);
    setTimeout(() => { try { tell("shot", document.getElementById("c").toDataURL("image/png")); } catch (e) { tell("canvas read failed: " + e.message); } }, 2500);
  });
  rfb.addEventListener("disconnect", (e) => tell("disconnected " + ((e.detail && e.detail.clean) ? "clean" : "error")));
  rfb.addEventListener("credentialsrequired", () => tell("the screen asked for a password"));
} catch (e) { tell("failed: " + (e && e.message)); }
</script>
'@
  try {
    [System.IO.File]::WriteAllText((Join-Path $script:NoVncDir "cloudpc-probe.html"), $probe)
    Note "wrote the connection probe page (viewer address + /cloudpc-probe.html?p=password)"
  } catch { Note "could not write the probe page: $($_.Exception.Message)" }
}

# --- 3. the address: Cloudflare quick tunnel -----------------------------
Note "downloading cloudflared..."
if (-not (Test-Path $script:CloudflaredExe)) {
  if (-not (Get-Web "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-windows-amd64.exe" $script:CloudflaredExe)) {
    Fail "cloudflared could not be downloaded."
  }
}
if (Start-Tunnel) {
  Save-State "starting"
  Announce "Your Windows desktop is ready - its address is published in the repository, and the Cloud PC page shows the password."
  Write-Host "CLOUDPC_URL=$($script:TunnelUrl)/vnc.html"
  if ($script:PublicRepo) {
    Note "this repository is public, so the desktop password is deliberately neither printed here nor published in the repository - the Cloud PC page keeps its own copy"
  } else {
    Write-Host "CLOUDPC_PASSWORD=$($script:Pw)"
  }
  Note "waiting for the desktop to answer through the tunnel..."
  for ($i = 1; $i -le 30; $i++) {
    if (Test-DesktopReachable) { Note "the desktop answered through the tunnel (status ready)"; Save-State "ready"; break }
    Start-Sleep -Seconds 5
  }
} else {
  Fail "the Cloudflare tunnel did not come up, so this machine has no public address."
}

# --- 4. keep the desktop alive until the 6 hour job limit ----------------
$lastPublish = Get-Date
$deadline = (Get-Date).AddMinutes($script:MaxMinutes)
try {
  while ((Get-Date) -lt $deadline) {
    Start-Sleep -Seconds 60
    if (-not (Test-Port $script:VncPort)) {
      Warn "the screen server stopped - starting it again"
      if (Test-Path $tvnExe) { Start-Process -FilePath $tvnExe -ArgumentList "-run" -WindowStyle Hidden | Out-Null }
    }
    if (-not (Test-DesktopReachable)) {
      $alive = $false
      for ($i = 1; $i -le 5; $i++) { Start-Sleep -Seconds 6; if (Test-DesktopReachable) { $alive = $true; break } }
      if (-not $alive) {
        Warn "the tunnel stopped answering - opening a new one"
        if (Start-Tunnel) { Save-State "running"; $lastPublish = Get-Date }
      }
    }
    if (((Get-Date) - $lastPublish).TotalMinutes -ge 30 -and $script:TunnelUrl) {
      Save-State "running"
      $lastPublish = Get-Date
    }
    Note ("session has been running for {0:N0} minutes" -f ((Get-Date) - $script:StartedUtc.ToLocalTime()).TotalMinutes)
  }
  Note "the 6 hour limit is close - ending the session cleanly"
} finally {
  # Remove the published address, so the desktop cannot be reached after the
  # session is over (the machine itself is thrown away by GitHub anyway).
  try {
    Remove-PublishedState
  } catch { Note "could not remove $($script:StateName): $($_.Exception.Message)" }
  Note "session over. Thanks for flying Cloud PC."
}
