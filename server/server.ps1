# FM-Stream Deck (Free Mobile Stream Deck) - servidor web portátil para a rede local.
# PowerShell 5.1+ (já vem no Windows 10/11), sem instalar nada. Abra pelo "FM-Stream Deck.bat".
#
# Parâmetros: -Port 8080  -ObsPort 4455  -NoFirewall  -RemoveFirewall  -NoPanel  -NoUpdateCheck
# Licença MIT.
param(
    [Alias('Porta')][int]$Port = 8080,
    [Alias('ObsPorta')][int]$ObsPort = 4455,
    [Alias('SemFirewall')][switch]$NoFirewall,
    [Alias('RemoverFirewall')][switch]$RemoveFirewall,
    [Alias('SemPainel')][switch]$NoPanel,
    [Alias('SemAtualizacao')][switch]$NoUpdateCheck
)

$Version = 'dev'   # o CI troca pela versão da tag (v1.2.3) ao publicar um release
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
try { $Host.UI.RawUI.WindowTitle = 'FM-Stream Deck - servidor' } catch {}

# pasta servida = a pasta acima de \server (onde fica o obs-deck.html)
$Base = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..')).TrimEnd('\')
$PanelFile = Join-Path $PSScriptRoot 'panel.html'

$Types = @{
    '.html' = 'text/html; charset=utf-8'; '.htm' = 'text/html; charset=utf-8'
    '.js' = 'application/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
    '.json' = 'application/json; charset=utf-8'; '.webmanifest' = 'application/manifest+json'
    '.png' = 'image/png'; '.jpg' = 'image/jpeg'; '.jpeg' = 'image/jpeg'; '.gif' = 'image/gif'
    '.svg' = 'image/svg+xml'; '.ico' = 'image/x-icon'; '.webp' = 'image/webp'
}

function Pause-Exit { if (-not [Console]::IsInputRedirected) { Read-Host 'Aperte Enter para sair' | Out-Null } }

# ---------------- firewall ----------------
function Name-Web { "FM-Stream Deck - pagina (TCP $script:Port)" }
function Name-Obs { "FM-Stream Deck - OBS WebSocket (TCP $script:ObsPort)" }
function Rule-Exists([string]$name) {
    & netsh advfirewall firewall show rule name="$name" *> $null
    return ($LASTEXITCODE -eq 0)
}
function Run-Elevated([string]$cmd) {
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList '/c', $cmd -Verb RunAs -WindowStyle Hidden -Wait | Out-Null
        return $true
    } catch { return $false } # UAC recusado
}
# remoteip=localsubnet: só aceita conexões de aparelhos da mesma rede local
function Open-Firewall {
    $w = Name-Web; $o = Name-Obs
    $cmd = "netsh advfirewall firewall delete rule name=`"$w`" >nul 2>&1 & " +
           "netsh advfirewall firewall add rule name=`"$w`" dir=in action=allow protocol=TCP localport=$Port remoteip=localsubnet profile=any >nul & " +
           "netsh advfirewall firewall delete rule name=`"$o`" >nul 2>&1 & " +
           "netsh advfirewall firewall add rule name=`"$o`" dir=in action=allow protocol=TCP localport=$ObsPort remoteip=localsubnet profile=any >nul"
    $script:FwCache.t = [datetime]::MinValue
    return (Run-Elevated $cmd) -and (Rule-Exists $w) -and (Rule-Exists $o)
}
function Remove-Firewall {
    $w = Name-Web; $o = Name-Obs
    $cmd = "netsh advfirewall firewall delete rule name=`"$w`" >nul 2>&1 & netsh advfirewall firewall delete rule name=`"$o`" >nul 2>&1"
    $script:FwCache.t = [datetime]::MinValue
    return (Run-Elevated $cmd) -and -not (Rule-Exists $w) -and -not (Rule-Exists $o)
}
$FwCache = @{ t = [datetime]::MinValue; web = $false; obs = $false }
function Firewall-State {
    if (((Get-Date) - $script:FwCache.t).TotalSeconds -gt 10) {
        $script:FwCache.web = Rule-Exists (Name-Web)
        $script:FwCache.obs = Rule-Exists (Name-Obs)
        $script:FwCache.t = Get-Date
    }
    return [ordered]@{ web = $script:FwCache.web; obs = $script:FwCache.obs }
}

if ($RemoveFirewall) {
    if (Remove-Firewall) { Write-Host "Regras do FM-Stream Deck removidas do firewall (portas $Port e $ObsPort)." }
    else { Write-Host 'Não foi possível remover as regras (permissão negada?).' }
    Pause-Exit; return
}

# ---------------- rede / OBS ----------------
function Get-Urls {
    $list = @()
    foreach ($ni in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        if ($ni.OperationalStatus -ne 'Up' -or $ni.NetworkInterfaceType -eq 'Loopback') { continue }
        foreach ($ua in $ni.GetIPProperties().UnicastAddresses) {
            if ($ua.Address.AddressFamily -ne 'InterNetwork') { continue }
            $ip = $ua.Address.ToString()
            if ($ip.StartsWith('169.254.')) { continue }
            $sfx = if ($script:Port -eq 80) { '' } else { ":$script:Port" }
            $list += [ordered]@{ ip = $ip; iface = $ni.Name; url = "http://$ip$sfx/" }
        }
    }
    return , $list
}
$ObsCache = @{ t = [datetime]::MinValue; ok = $false }
function Test-Obs {
    if (((Get-Date) - $script:ObsCache.t).TotalSeconds -gt 3) {
        $ok = $false
        try {
            $c = New-Object Net.Sockets.TcpClient
            $ar = $c.BeginConnect('127.0.0.1', $script:ObsPort, $null, $null)
            if ($ar.AsyncWaitHandle.WaitOne(300)) { try { $c.EndConnect($ar); $ok = $true } catch {} }
            $c.Close()
        } catch {}
        $script:ObsCache.ok = $ok; $script:ObsCache.t = Get-Date
    }
    return $script:ObsCache.ok
}

# ---------------- atualização (GitHub Releases) ----------------
# Só funciona em cópias baixadas de um release (versão numérica). Num clone do git a versão é 'dev' e fica desligada.
$Repo = 'yurihoraguti/FM-Stream-Deck'
$ZipName = 'FM-Stream-Deck-windows.zip'
$UpdEnabled = ($Version -match '^\d+\.\d+\.\d+$') -and -not $NoUpdateCheck
$Upd = @{ task = $null; client = $null; checked = [datetime]::MinValue; latest = $null; notes = $null; zip = $null; error = $null }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch {}

function New-WebClient([bool]$api) {
    $wc = New-Object Net.WebClient
    $wc.Headers['User-Agent'] = "FM-Stream-Deck/$script:Version"
    if ($api) { $wc.Headers['Accept'] = 'application/vnd.github+json' }
    return $wc
}
# consulta em segundo plano para não travar o servidor; o resultado é lido no próximo /api/status
function Start-UpdateCheck {
    if (-not $script:UpdEnabled -or $script:Upd.task) { return }
    $script:Upd.checked = Get-Date
    try {
        $script:Upd.client = New-WebClient $true
        $script:Upd.task = $script:Upd.client.DownloadStringTaskAsync("https://api.github.com/repos/$script:Repo/releases/latest")
    } catch { $script:Upd.error = 'sem acesso ao GitHub' }
}
function Update-State {
    if (-not $script:UpdEnabled) { return [ordered]@{ enabled = $false } }
    $t = $script:Upd.task
    if ($t -and $t.IsCompleted) {
        $script:Upd.task = $null
        try { $script:Upd.client.Dispose() } catch {}
        if ($t.Status -eq 'RanToCompletion') {
            try {
                $r = $t.Result | ConvertFrom-Json
                $asset = @($r.assets | Where-Object { $_.name -eq $script:ZipName })[0]
                $script:Upd.latest = ([string]$r.tag_name).TrimStart('v')
                $script:Upd.notes = [string]$r.html_url
                $script:Upd.zip = if ($asset) { [string]$asset.browser_download_url } else { $null }
                $script:Upd.error = $null
            } catch { $script:Upd.error = 'resposta inválida do GitHub' }
        } else { $script:Upd.error = 'sem acesso ao GitHub' }
    }
    if (((Get-Date) - $script:Upd.checked).TotalHours -ge 12) { Start-UpdateCheck }
    $avail = $false
    try { $avail = [bool]$script:Upd.zip -and ([version]$script:Upd.latest -gt [version]$script:Version) } catch {}
    return [ordered]@{
        enabled = $true; checking = [bool]$script:Upd.task; latest = $script:Upd.latest
        available = $avail; notes = $script:Upd.notes; error = $script:Upd.error
    }
}
# baixa o zip do release, confere o conteúdo e copia por cima desta pasta (o servidor reinicia em seguida)
function Install-Update {
    if (-not (Update-State).available) { return 'Nenhuma atualização disponível.' }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('fmsd-update-' + [guid]::NewGuid().ToString('N'))
    try {
        New-Item -ItemType Directory -Force $tmp | Out-Null
        $zip = Join-Path $tmp $script:ZipName
        $wc = New-WebClient $false
        try { $wc.DownloadFile($script:Upd.zip, $zip) } finally { $wc.Dispose() }
        $dir = Join-Path $tmp 'files'
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir)
        foreach ($f in 'obs-deck.html', 'FM-Stream Deck.bat', 'server\server.ps1', 'server\panel.html') {
            if (-not (Test-Path -LiteralPath (Join-Path $dir $f) -PathType Leaf)) { return "O pacote baixado está incompleto (falta $f)." }
        }
        # copia só o que mudou: o .bat que está rodando não é regravado se for igual (o cmd o lê enquanto executa)
        foreach ($f in Get-ChildItem -LiteralPath $dir -Recurse -File) {
            $dst = Join-Path $script:Base $f.FullName.Substring($dir.Length + 1)
            if ((Test-Path -LiteralPath $dst -PathType Leaf) -and
                (Get-FileHash -LiteralPath $dst).Hash -eq (Get-FileHash -LiteralPath $f.FullName).Hash) { continue }
            New-Item -ItemType Directory -Force (Split-Path $dst) | Out-Null
            Copy-Item -LiteralPath $f.FullName -Destination $dst -Force
        }
        return $null
    } catch {
        return 'Falha ao atualizar: ' + $_.Exception.Message
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# ---------------- abre a porta ----------------
$listener = $null
for ($p = $Port; $p -le $Port + 10; $p++) {
    try {
        $l = New-Object Net.Sockets.TcpListener([Net.IPAddress]::Any, $p)
        $l.Start(); $listener = $l; $Port = $p; break
    } catch { }
}
if (-not $listener) {
    Write-Host "Não foi possível abrir as portas $Port a $($Port + 10). Use -Port com outro número." -ForegroundColor Yellow
    Pause-Exit; return
}

$Started = Get-Date
$Clients = @{}
$Log = New-Object Collections.ArrayList
$StopNow = $false
$RestartNow = $false
$sfx = if ($Port -eq 80) { '' } else { ":$Port" }

Write-Host ''
Write-Host "  FM-Stream Deck $Version - servidor da rede local"
Write-Host '  -----------------------------------------------'
Write-Host ''
if (-not (Test-Path (Join-Path $Base 'obs-deck.html'))) { Write-Host "  Atenção: obs-deck.html não encontrado em $Base" -ForegroundColor Yellow }
Write-Host '  Abra num celular ou tablet da mesma rede:'
Write-Host ''
$urls = Get-Urls
if ($urls.Count -eq 0) { Write-Host '    (nenhuma rede encontrada; confira o Wi-Fi ou o cabo)' }
foreach ($u in $urls) {
    Write-Host ('    ' + $u.url) -ForegroundColor Green -NoNewline
    Write-Host ('   (' + $u.iface + ')')
}
Write-Host ''
$fw = Firewall-State
if ($NoFirewall) { Write-Host '  Firewall: não verificado (-NoFirewall).' }
elseif ($fw.web -and $fw.obs) { Write-Host "  Firewall: portas $Port e $ObsPort liberadas para a rede local." }
else { Write-Host '  Firewall: portas ainda não liberadas. Use o botão "Liberar portas" no painel.' -ForegroundColor Yellow }
Write-Host "  Painel de gerenciamento (só neste PC): http://localhost$sfx/panel"
Write-Host '  Deixe esta janela aberta. Para parar, use o painel, feche a janela ou aperte Ctrl+C.'
Write-Host ''
if (-not $NoPanel) { try { Start-Process "http://localhost$sfx/panel" } catch {} }
Start-UpdateCheck

# ---------------- HTTP ----------------
function Add-Log([string]$ip, [string]$method, [string]$target, [int]$code) {
    $cor = if ($code -ge 400) { 'Yellow' } else { 'DarkGray' }
    Write-Host ("  [" + (Get-Date -Format 'HH:mm:ss') + "] $ip  $method $target  $code") -ForegroundColor $cor
    [void]$script:Log.Add([ordered]@{ t = (Get-Date).ToString('o'); ip = $ip; method = $method; path = $target; code = $code })
    while ($script:Log.Count -gt 60) { $script:Log.RemoveAt(0) }
}
function Touch-Client([string]$ip) {
    if (-not $script:Clients.ContainsKey($ip)) { $script:Clients[$ip] = @{ first = Get-Date; last = Get-Date; count = 0 } }
    $script:Clients[$ip].last = Get-Date
    $script:Clients[$ip].count++
}
function Status-Json {
    $cl = @()
    foreach ($k in $script:Clients.Keys) {
        $c = $script:Clients[$k]
        if (((Get-Date) - $c.last).TotalMinutes -gt 30) { continue }
        $cl += [ordered]@{ ip = $k; local = ($k -eq '127.0.0.1'); first = $c.first.ToString('o'); last = $c.last.ToString('o'); requests = $c.count }
    }
    $lg = @()
    for ($i = $script:Log.Count - 1; $i -ge 0 -and $lg.Count -lt 40; $i--) { $lg += $script:Log[$i] }
    $ul = Get-Urls
    $o = [ordered]@{
        app = 'FM-Stream Deck'; version = $Version; server = 'powershell'
        started = $Started.ToString('o'); uptime = [int]((Get-Date) - $Started).TotalSeconds
        port = $Port; obsPort = $ObsPort; obsReachable = (Test-Obs)
        firewallChecked = (-not $NoFirewall); firewall = (Firewall-State)
        urls = $ul; clients = $cl; log = $lg; update = (Update-State)
    }
    return ($o | ConvertTo-Json -Depth 5 -Compress)
}
function Send($ns, [int]$code, [string]$reason, [string]$type, [byte[]]$body, [bool]$headOnly, [string]$extra) {
    $h = "HTTP/1.1 $code $reason`r`nContent-Type: $type`r`nContent-Length: $($body.Length)`r`n" +
         "Cache-Control: no-cache`r`nX-Content-Type-Options: nosniff`r`n$extra" + "Connection: close`r`n`r`n"
    $hb = [Text.Encoding]::ASCII.GetBytes($h)
    $ns.Write($hb, 0, $hb.Length)
    if (-not $headOnly -and $body.Length) { $ns.Write($body, 0, $body.Length) }
}
function Send-Text($ns, [int]$code, [string]$reason, [string]$text, [bool]$headOnly) {
    Send $ns $code $reason 'text/plain; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($text)) $headOnly ''
}
function Send-Json($ns, [string]$json) {
    Send $ns 200 'OK' 'application/json; charset=utf-8' ([Text.Encoding]::UTF8.GetBytes($json)) $false ''
}
function Read-Head($ns) {
    $ms = New-Object IO.MemoryStream
    $buf = New-Object byte[] 4096
    while ($ms.Length -lt 16384) {
        $n = $ns.Read($buf, 0, $buf.Length)
        if ($n -le 0) { break }
        $ms.Write($buf, 0, $n)
        $s = [Text.Encoding]::ASCII.GetString($ms.ToArray())
        $end = $s.IndexOf("`r`n`r`n")
        if ($end -ge 0) { return $s.Substring(0, $end) }
    }
    return $null
}
function Handle($client) {
    $remote = '?'
    try {
        $client.ReceiveTimeout = 5000; $client.SendTimeout = 5000
        $remoteIp = $client.Client.RemoteEndPoint.Address
        $remote = $remoteIp.ToString()
        $localIp = $client.Client.LocalEndPoint.Address
        $ns = $client.GetStream()
        $head = Read-Head $ns
        if (-not $head) { return }
        $lines = $head -split "`r`n"
        $first = $lines[0] -split ' '
        if ($first.Count -lt 2) { Send-Text $ns 400 'Bad Request' 'Requisição inválida' $false; return }
        $hdr = @{}
        for ($i = 1; $i -lt $lines.Count; $i++) {
            $c = $lines[$i].IndexOf(':')
            if ($c -gt 0) { $hdr[$lines[$i].Substring(0, $c).Trim().ToLower()] = $lines[$i].Substring($c + 1).Trim() }
        }
        $method = $first[0].ToUpper(); $target = $first[1]; $headOnly = ($method -eq 'HEAD')
        $path = ($target -split '\?', 2)[0]
        try { $path = [Uri]::UnescapeDataString($path) } catch {}

        # painel e API: só neste PC (loopback) e com Host local (evita DNS rebinding)
        $isAdmin = ($path -eq '/panel' -or $path -eq '/panel/' -or $path.StartsWith('/api/'))
        if ($isAdmin) {
            $hostHdr = ''; if ($hdr.ContainsKey('host')) { $hostHdr = $hdr['host'].ToLower() }
            $hostOk = $hostHdr -match '^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$'
            if (-not [Net.IPAddress]::IsLoopback($remoteIp) -or -not $hostOk) {
                Send-Text $ns 403 'Forbidden' 'O painel só pode ser aberto no PC que roda o servidor.' $headOnly
                Add-Log $remote $method $target 403; return
            }
            if ($path.StartsWith('/api/')) {
                if ($method -eq 'GET' -and $path -eq '/api/status') { Send-Json $ns (Status-Json); return }
                # ações: só POST com cabeçalho próprio (um site qualquer não consegue enviar sem CORS)
                if ($method -ne 'POST' -or $hdr['x-fmsd'] -ne '1') { Send-Text $ns 403 'Forbidden' 'Ação não permitida' $false; return }
                if ($path -eq '/api/firewall/open') {
                    $ok = if ($NoFirewall) { $false } else { Open-Firewall }
                    Send-Json $ns ('{"ok":' + $ok.ToString().ToLower() + '}'); Add-Log $remote $method $path 200; return
                }
                if ($path -eq '/api/firewall/remove') {
                    $ok = if ($NoFirewall) { $false } else { Remove-Firewall }
                    Send-Json $ns ('{"ok":' + $ok.ToString().ToLower() + '}'); Add-Log $remote $method $path 200; return
                }
                if ($path -eq '/api/stop') {
                    Send-Json $ns '{"ok":true}'; Add-Log $remote $method $path 200
                    $script:StopNow = $true; return
                }
                if ($path -eq '/api/update/apply') {
                    Write-Host '  Baixando a atualização...'
                    $err = Install-Update
                    if ($err) {
                        Write-Host "  $err" -ForegroundColor Yellow
                        Send-Json $ns ([ordered]@{ ok = $false; error = $err } | ConvertTo-Json -Compress); Add-Log $remote $method $path 200; return
                    }
                    Send-Json $ns '{"ok":true}'; Add-Log $remote $method $path 200
                    $script:RestartNow = $true; $script:StopNow = $true; return
                }
                Send-Text $ns 404 'Not Found' 'Não encontrado' $false; return
            }
            if (-not (Test-Path -LiteralPath $PanelFile)) { Send-Text $ns 404 'Not Found' 'panel.html não encontrado' $headOnly; return }
            Send $ns 200 'OK' 'text/html; charset=utf-8' ([IO.File]::ReadAllBytes($PanelFile)) $headOnly ''
            return
        }

        if ($method -ne 'GET' -and -not $headOnly) {
            Send-Text $ns 405 'Method Not Allowed' 'Método não permitido' $false
            Add-Log $remote $method $target 405; return
        }
        Touch-Client $remote

        # raiz: abre o deck já apontando para o OBS deste PC (o IP pelo qual o aparelho chegou aqui)
        if ($path -eq '/' -or $path -eq '') {
            $obsHost = if ([Net.IPAddress]::IsLoopback($localIp)) { 'localhost' } else { $localIp.ToString() }
            Send $ns 302 'Found' 'text/plain; charset=utf-8' ([byte[]]@()) $true "Location: /obs-deck.html?host=$obsHost&port=$ObsPort`r`n"
            Add-Log $remote $method $target 302; return
        }

        $body = $null
        $ext = [IO.Path]::GetExtension($path).ToLower()
        if ($Types.ContainsKey($ext) -and -not $path.ToLower().StartsWith('/server/')) {
            try { $full = [IO.Path]::GetFullPath((Join-Path $Base ($path.TrimStart('/').Replace('/', '\')))) } catch { $full = $null }
            # só arquivos desta pasta (e subpastas), sem sair dela com ../
            if ($full -and $full.StartsWith($Base + '\', [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $full -PathType Leaf)) {
                $body = [IO.File]::ReadAllBytes($full)
            }
        }
        if ($null -eq $body) {
            Send-Text $ns 404 'Not Found' 'Não encontrado' $headOnly
            Add-Log $remote $method $target 404; return
        }
        Send $ns 200 'OK' $Types[$ext] $body $headOnly ''
        Add-Log $remote $method $target 200
    } catch {
    } finally {
        try { $client.Close() } catch {}
    }
}

try {
    while (-not $StopNow) {
        if (-not $listener.Pending()) { Start-Sleep -Milliseconds 30; continue } # permite Ctrl+C
        Handle ($listener.AcceptTcpClient())
    }
    if (-not $RestartNow) { Write-Host '  Servidor parado pelo painel.' }
} finally {
    $listener.Stop()
}

# depois de atualizar: abre a versão nova na mesma porta (o painel aberto reconecta sozinho)
if ($RestartNow) {
    Write-Host "  Atualizado para a versão $($Upd.latest). Reiniciando..."
    $argv = @('-Port', $Port, '-ObsPort', $ObsPort, '-NoPanel')
    if ($NoFirewall) { $argv += '-NoFirewall' }
    Start-Process -FilePath (Join-Path $Base 'FM-Stream Deck.bat') -ArgumentList $argv -WorkingDirectory $Base
}
