param([string]$Mode = "")
# PC Bridge 1.2 - setup + launcher. Started by START.bat

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
# ---- кириллица в консоли: UTF-8 + шрифт Consolas (растровый шрифт даёт "???") ----
try {
    Add-Type -ErrorAction Stop -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class PcBridgeConsole {
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct FONTINFO {
        public uint cbSize; public uint nFont; public short X; public short Y;
        public int FontFamily; public int FontWeight;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)] public string FaceName;
    }
    [DllImport("kernel32.dll")] static extern IntPtr GetStdHandle(int h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool GetCurrentConsoleFontEx(IntPtr h, bool max, ref FONTINFO f);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool SetCurrentConsoleFontEx(IntPtr h, bool max, ref FONTINFO f);
    [DllImport("kernel32.dll")] static extern bool SetConsoleOutputCP(uint cp);
    [DllImport("kernel32.dll")] static extern bool SetConsoleCP(uint cp);
    public static void Fix() {
        SetConsoleOutputCP(65001); SetConsoleCP(65001);
        IntPtr h = GetStdHandle(-11);
        FONTINFO f = new FONTINFO(); f.cbSize = (uint)Marshal.SizeOf(typeof(FONTINFO));
        if (!GetCurrentConsoleFontEx(h, false, ref f)) return;
        string n = f.FaceName ?? "";
        if (n.Contains("Consolas") || n.Contains("Lucida") || n.Contains("Cascadia") || n.Contains("Courier")) return;
        f.nFont = 0; f.X = 0; f.Y = (short)(f.Y < 16 ? 16 : f.Y);
        f.FontFamily = 54; f.FontWeight = 400; f.FaceName = "Consolas";
        SetCurrentConsoleFontEx(h, false, ref f);
    }
}
"@
    [PcBridgeConsole]::Fix()
} catch {}
try { [Console]::OutputEncoding = New-Object System.Text.UTF8Encoding $false } catch {}
try { [Console]::InputEncoding  = New-Object System.Text.UTF8Encoding $false } catch {}
$OutputEncoding = New-Object System.Text.UTF8Encoding $false

# ---- запасной режим: транслит латиницей (START_LATIN.bat создаёт latin.flag) ----
$Latin = Test-Path (Join-Path $PSScriptRoot "latin.flag")
$RuChars = "абвгдеёжзийклмнопрстуфхцчшщъыьэюя"
$LaChars = @("a","b","v","g","d","e","yo","zh","z","i","y","k","l","m","n","o","p","r","s","t","u","f","kh","ts","ch","sh","sch","","y","","e","yu","ya")
function Tr([string]$s) {
    if (-not $Latin -or [string]::IsNullOrEmpty($s)) { return $s }
    $sb = New-Object System.Text.StringBuilder
    foreach ($ch in $s.ToCharArray()) {
        $i = $RuChars.IndexOf([char]::ToLowerInvariant($ch))
        if ($i -lt 0) { [void]$sb.Append($ch); continue }
        $t = $LaChars[$i]
        if ([char]::IsUpper($ch) -and $t.Length -gt 0) { $t = $t.Substring(0, 1).ToUpper() + $t.Substring(1) }
        [void]$sb.Append($t)
    }
    return $sb.ToString()
}
function W {
    param([Parameter(Position = 0)]$Object = "", [string]$ForegroundColor = "Gray")
    Microsoft.PowerShell.Utility\Write-Host (Tr ([string]$Object)) -ForegroundColor $ForegroundColor
}
function RH([string]$Prompt) { return (Microsoft.PowerShell.Utility\Read-Host (Tr $Prompt)) }
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$Root     = Split-Path -Parent $MyInvocation.MyCommand.Path
$ToolsDir = Join-Path $Root "tools"
$LogsDir  = Join-Path $Root "logs"
$CfgPath  = Join-Path $Root "config.json"
$PidPath  = Join-Path $LogsDir "pids.json"
$VenvPy   = Join-Path $Root ".venv\Scripts\python.exe"
$ServerPy = Join-Path $Root "server\server.py"
foreach ($d in @($ToolsDir, $LogsDir, (Join-Path $Root "workspace"))) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
Set-Location $Root
try { $Host.UI.RawUI.WindowTitle = "PC Bridge 1.2 для Notion" } catch {}

# ------------------------------------------------------------ helpers ------
function Say($t, $c = "Gray") { W $t -ForegroundColor $c }
function Step($t) { W ""; W "==> $t" -ForegroundColor Cyan }
function Ok($t)   { W "  [OK] $t" -ForegroundColor Green }
function Warn($t) { W "  [!] $t" -ForegroundColor Yellow }
function Fail($t) {
    W ""
    W "  [ОШИБКА] $t" -ForegroundColor Red
    W "  Подробности в папке logs. Описание проблем - README.txt, раздел 'Если что-то не работает'." -ForegroundColor Red
    RH "Нажмите Enter, чтобы закрыть"
    exit 1
}
function AskYN($q, [bool]$def) {
    $d = if ($def) { "Y/n" } else { "y/N" }
    while ($true) {
        $a = RH "  $q [$d]"
        if ([string]::IsNullOrWhiteSpace($a)) { return $def }
        $a = $a.Trim().ToLower()
        if (@("y", "yes", "д", "да", "d", "da", "нуы") -contains $a) { return $true }
        if (@("n", "no", "н", "нет", "net", "т", "тщ") -contains $a) { return $false }
        Warn "Введите y (да) или n (нет)"
    }
}
function AskText($q, $def) {
    $a = RH "  $q [$def]"
    if ([string]::IsNullOrWhiteSpace($a)) { return $def }
    return $a.Trim().Trim('"')
}
function Refresh-Path {
    $env:Path = [Environment]::GetEnvironmentVariable("Path", "Machine") + ";" + [Environment]::GetEnvironmentVariable("Path", "User")
}
function Download($url, $out) {
    Say "  Скачиваю $url"
    Invoke-WebRequest -Uri $url -OutFile $out -UseBasicParsing -Headers @{ "User-Agent" = "pc-bridge" }
}
function Has-Winget { return [bool](Get-Command winget -ErrorAction SilentlyContinue) }
function Test-Port($p) {
    try { $c = New-Object Net.Sockets.TcpClient; $c.Connect("127.0.0.1", [int]$p); $c.Close(); return $true } catch { return $false }
}
function Stop-Old {
    if (Test-Path $PidPath) {
        try {
            $p = Get-Content $PidPath -Raw | ConvertFrom-Json
            foreach ($id in @($p.server, $p.ngrok)) { if ($id) { Stop-Process -Id $id -Force -ErrorAction SilentlyContinue } }
        } catch {}
        Remove-Item $PidPath -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 800
    }
}
function Tail($file, $n = 15) { if (Test-Path $file) { Get-Content $file -Tail $n | ForEach-Object { Say "    $_" DarkGray } } }

W ""
W "  ============================================" -ForegroundColor Cyan
W "     PC Bridge 1.2 - мост между Notion-агентом и ПК" -ForegroundColor Cyan
W "  ============================================" -ForegroundColor Cyan

Stop-Old

# ------------------------------------------------------------- config ------
$cfg = [ordered]@{}
$haveCfg = Test-Path $CfgPath
if ($haveCfg) {
    try { (Get-Content $CfgPath -Raw -Encoding UTF8 | ConvertFrom-Json).psobject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } }
    catch { Warn "config.json повреждён - настроим заново"; $haveCfg = $false; $cfg = [ordered]@{} }
}
function Def($name, [bool]$default) { if ($cfg.Contains($name)) { return [bool]$cfg[$name] } else { return $default } }
function YN($v) { if ($v) { "да" } else { "нет" } }

$doWizard = (-not $haveCfg) -or ($Mode -eq "reconfigure")
if (-not $doWizard) {
    Step "Сохранённые настройки"
    Say "  Интернет:          $(YN $cfg.enable_internet)"
    Say "  Blender:           $(YN $cfg.enable_blender)"
    Say "  Roblox Studio:     $(YN $cfg.enable_roblox)"
    Say "  Экран/мышь:        $(YN $cfg.enable_screen)"
    Say "  Командная строка:  $(YN $cfg.enable_shell)"
    Say "  Весь диск:         $(YN $cfg.full_disk)"
    Say "  Домен ngrok:       $(if ($cfg.ngrok_domain) { $cfg.ngrok_domain } else { '(случайный)' })"
    $doWizard = -not (AskYN "Запустить с этими настройками?" $true)
}

if ($doWizard) {
    Step "Выбор модулей (y = да, n = нет, Enter = вариант по умолчанию)"
    $cfg.enable_internet = AskYN "Интернет: поиск, чтение сайтов, скачивание файлов?" (Def "enable_internet" $true)
    $cfg.enable_blender  = AskYN "Blender: скрипты, создание сцен, рендер?" (Def "enable_blender" $true)
    $cfg.enable_roblox   = AskYN "Roblox Studio: проекты и скрипты Luau через Rojo?" (Def "enable_roblox" $false)
    $cfg.enable_screen   = AskYN "Экран: скриншоты и управление мышью/клавиатурой?" (Def "enable_screen" $false)
    Warn "Командная строка = агент сможет выполнять ЛЮБЫЕ команды и ставить программы."
    $cfg.enable_shell    = AskYN "Командная строка (PowerShell)?" (Def "enable_shell" $false)
    Warn "Весь диск = файловые инструменты работают не только в папке workspace."
    $cfg.full_disk       = AskYN "Доступ ко всему диску?" (Def "full_disk" $false)

    Step "Сеть"
    $cfg.port = [int](AskText "Локальный порт" $(if ($cfg.port) { $cfg.port } else { 8765 }))
    Say "  (Домен ngrok спросим позже - после регистрации в ngrok и ввода токена.)"
    if ($cfg.secret -and (AskYN "Создать новый секретный ключ? (старая ссылка перестанет работать)" $false)) { $cfg.secret = "" }
}
if (-not $cfg.secret) { $cfg.secret = [guid]::NewGuid().ToString("N") + [guid]::NewGuid().ToString("N") }
if (-not $cfg.workspace) { $cfg.workspace = (Join-Path $Root "workspace") }
if (-not $cfg.port) { $cfg.port = 8765 }
if (-not $cfg.Contains("max_download_mb")) { $cfg.max_download_mb = 4096 }
function Save-Config { ($cfg | ConvertTo-Json -Depth 5) | Set-Content -Path $CfgPath -Encoding UTF8 }
Save-Config

# ------------------------------------------------------------- python ------
Step "Проверяю Python 3.10+"
function Find-Python {
    foreach ($c in @("py", "python", "python3")) {
        $cmd = Get-Command $c -ErrorAction SilentlyContinue
        if (-not $cmd -or $cmd.Source -like "*WindowsApps*") { continue }
        try {
            $pa = if ($c -eq "py") { @("-3", "-c") } else { @("-c") }
            $v = & $c @pa "import sys;print(sys.executable);print(sys.version_info>=(3,10))" 2>$null
            if ($LASTEXITCODE -eq 0 -and $v.Count -ge 2 -and $v[1] -eq "True") { return $v[0] }
        } catch {}
    }
    $cands = Get-ChildItem -Path "$env:LOCALAPPDATA\Programs\Python\Python3*\python.exe", "$env:ProgramFiles\Python3*\python.exe" -ErrorAction SilentlyContinue | Sort-Object FullName -Descending
    foreach ($p in $cands) {
        try { $ok = & $p.FullName -c "import sys;print(sys.version_info>=(3,10))" 2>$null; if ($ok -eq "True") { return $p.FullName } } catch {}
    }
    return $null
}
$py = Find-Python
if (-not $py) {
    Warn "Python не найден."
    if (-not (AskYN "Установить Python 3.12 автоматически?" $true)) { Fail "Без Python мост не работает. Установите его с python.org и запустите START.bat снова." }
    $installed = $false
    if (Has-Winget) {
        try { winget install -e --id Python.Python.3.12 --scope user --accept-package-agreements --accept-source-agreements; $installed = ($LASTEXITCODE -eq 0) } catch {}
    }
    if (-not $installed) {
        $inst = Join-Path $ToolsDir "python-installer.exe"
        Download "https://www.python.org/ftp/python/3.12.8/python-3.12.8-amd64.exe" $inst
        Say "  Устанавливаю Python (1-2 минуты)..."
        Start-Process -FilePath $inst -ArgumentList "/quiet", "InstallAllUsers=0", "PrependPath=1", "Include_launcher=1" -Wait
    }
    Refresh-Path
    $py = Find-Python
    if (-not $py) { Fail "Python установился, но не найден. Перезапустите START.bat (или перезагрузите ПК)." }
}
Ok "Python: $py"

# ------------------------------------------------------------- packages ----
Step "Проверяю библиотеки Python"
if (-not (Test-Path $VenvPy)) {
    Say "  Создаю виртуальное окружение .venv ..."
    & $py -m venv (Join-Path $Root ".venv")
    if (-not (Test-Path $VenvPy)) { Fail "Не удалось создать .venv" }
}
$pkgs = @("mcp>=1.10,<2", "httpx", "pillow")
if ($cfg.enable_screen) { $pkgs += "pyautogui" }
$marker = Join-Path $Root ".venv\pc-bridge-packages.txt"
$want = ($pkgs -join " ")
$have = if (Test-Path $marker) { (Get-Content $marker -Raw).Trim() } else { "" }
if ($have -ne $want) {
    Say "  Устанавливаю: $want"
    & $VenvPy -m pip install --disable-pip-version-check -q --upgrade pip
    & $VenvPy -m pip install --disable-pip-version-check -q --upgrade @pkgs
    if ($LASTEXITCODE -ne 0) { Fail "pip не смог установить библиотеки (проверьте интернет)." }
    Set-Content -Path $marker -Value $want
}
& $VenvPy -c "import mcp.server.fastmcp, httpx, PIL"
if ($LASTEXITCODE -ne 0) { Remove-Item $marker -ErrorAction SilentlyContinue; Fail "Библиотеки установлены с ошибкой. Запустите START.bat ещё раз." }
Ok "Библиотеки на месте"

# -------------------------------------------------------------- ngrok ------
Step "Проверяю ngrok"
function Find-Ngrok {
    $local = Join-Path $ToolsDir "ngrok.exe"
    if (Test-Path $local) { return $local }
    $c = Get-Command ngrok -ErrorAction SilentlyContinue
    if ($c) { return $c.Source }
    return $null
}
$NgrokMin = [version]"3.28.0"
function Get-NgrokVer($exe) {
    try { $t = (& $exe version 2>$null) -join " " } catch { return $null }
    if ($t -match "([0-9]+)\.([0-9]+)\.([0-9]+)") { return [version]"$($Matches[1]).$($Matches[2]).$($Matches[3])" }
    return $null
}
function Install-Ngrok {
    $local = Join-Path $ToolsDir "ngrok.exe"
    $zip = Join-Path $ToolsDir "ngrok.zip"
    Get-Process ngrok -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $local } | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 500
    try { Download "https://bin.equinox.io/c/bNyj1mQVY4c/ngrok-v3-stable-windows-amd64.zip" $zip }
    catch { Fail "Не удалось скачать ngrok: $($_.Exception.Message)" }
    if (Test-Path $local) { Remove-Item $local -Force -ErrorAction SilentlyContinue }
    Expand-Archive -Path $zip -DestinationPath $ToolsDir -Force
    Remove-Item $zip -Force -ErrorAction SilentlyContinue
    if (-not (Test-Path $local)) { Fail "ngrok.exe не появился. Возможно, его удалил антивирус - добавьте папку tools в исключения." }
    return $local
}
$ngrok = Find-Ngrok
if (-not $ngrok) {
    Say "  ngrok не найден - скачиваю..."
    $ngrok = Install-Ngrok
}
$ngVer = Get-NgrokVer $ngrok
if (-not $ngVer -or $ngVer -lt $NgrokMin) {
    Warn "ngrok $(if ($ngVer) { $ngVer } else { '(версия неизвестна)' }) устарел: бесплатный ngrok требует версию $NgrokMin или новее."
    Say "  Скачиваю свежую версию в папку tools..."
    $ngrok = Install-Ngrok
    $ngVer = Get-NgrokVer $ngrok
    if (-not $ngVer -or $ngVer -lt $NgrokMin) { Fail "Не удалось обновить ngrok (версия: $ngVer). Скачайте его вручную с https://ngrok.com/download и положите ngrok.exe в папку tools." }
}
Ok "ngrok $ngVer : $ngrok"

$ymls = @("$env:LOCALAPPDATA\ngrok\ngrok.yml", "$env:USERPROFILE\AppData\Local\ngrok\ngrok.yml", "$env:USERPROFILE\.ngrok2\ngrok.yml", "$env:USERPROFILE\.config\ngrok\ngrok.yml")
$hasToken = $false
foreach ($y in $ymls) { if ((Test-Path $y) -and (Select-String -Path $y -Pattern "authtoken" -Quiet)) { $hasToken = $true } }
if (-not $hasToken) {
    Warn "Нужен бесплатный токен ngrok (один раз)."
    Say "  Сейчас откроется сайт ngrok."
    Say "   1. Нет аккаунта? Нажмите Sign up и зарегистрируйтесь (бесплатно, можно через Google или GitHub)."
    Say "   2. После входа откройте раздел Your Authtoken (ссылка та же) и скопируйте токен."
    Say "   3. Вернитесь в это окно и вставьте токен (правый клик или Ctrl+V)."
    Start-Process "https://dashboard.ngrok.com/get-started/your-authtoken"
    $tok = (RH "  Вставьте authtoken и нажмите Enter").Trim()
    if (-not $tok) { Fail "Токен не введён." }
    & $ngrok config add-authtoken $tok
    if ($LASTEXITCODE -ne 0) { Fail "ngrok не принял токен." }
}
Ok "Токен ngrok настроен"

# ---- постоянный домен ngrok: спрашиваем ПОСЛЕ токена, когда аккаунт уже есть ----
if ($doWizard -or -not $cfg.Contains("ngrok_domain")) {
    Step "Постоянный адрес ngrok (необязательно, но удобно)"
    Say "  Без домена адрес для Notion будет новым при каждом запуске, и его придётся менять в настройках агента."
    Say "  С бесплатным доменом адрес постоянный - подключение в Notion настраивается один раз."
    Say "   1. Сейчас откроется страница Domains в ngrok (вы уже вошли в аккаунт)."
    Say "   2. Скопируйте ваш бесплатный домен, например abc-def.ngrok-free.app."
    Say "      Если списка доменов нет - создайте домен на этой странице (на бесплатном тарифе он один)."
    Say "   3. Вставьте его сюда. Не хотите домен - просто нажмите Enter."
    if (AskYN "Открыть страницу доменов ngrok?" $true) { Start-Process "https://dashboard.ngrok.com/domains" }
    $dom = AskText "Ваш домен ngrok ('-' = без домена)" $(if ($cfg.ngrok_domain) { $cfg.ngrok_domain } else { "-" })
    $dom = ($dom -replace '^https?://', '').Trim().TrimEnd('/')
    $cfg.ngrok_domain = if ($dom -eq "-" -or $dom -eq "") { "" } else { $dom }
    if ($cfg.ngrok_domain) { Ok "Домен: $($cfg.ngrok_domain)" } else { Warn "Без домена: адрес будет меняться при каждом запуске" }
    Save-Config
}

# ------------------------------------------------------------ blender ------
if ($cfg.enable_blender) {
    Step "Проверяю Blender"
    function Find-Blender {
        $roots = @("$env:ProgramFiles\Blender Foundation", "${env:ProgramFiles(x86)}\Blender Foundation",
                   "$env:LOCALAPPDATA\Programs\Blender Foundation", "$env:ProgramFiles\Steam\steamapps\common\Blender",
                   "${env:ProgramFiles(x86)}\Steam\steamapps\common\Blender")
        $found = foreach ($r in $roots) { if ($r -and (Test-Path $r)) { Get-ChildItem -Path $r -Filter blender.exe -Recurse -ErrorAction SilentlyContinue } }
        $b = $found | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($b) { return $b.FullName }
        $c = Get-Command blender -ErrorAction SilentlyContinue
        if ($c) { return $c.Source }
        return $null
    }
    if (-not ($cfg.blender_path -and (Test-Path $cfg.blender_path))) { $cfg.blender_path = Find-Blender }
    if (-not $cfg.blender_path) {
        Warn "Blender не найден."
        if ((Has-Winget) -and (AskYN "Установить Blender через winget?" $true)) {
            winget install -e --id BlenderFoundation.Blender --accept-package-agreements --accept-source-agreements
            $cfg.blender_path = Find-Blender
        }
        if (-not $cfg.blender_path) {
            $p = AskText "Путь к blender.exe (или '-' чтобы выключить модуль Blender)" "-"
            if ($p -ne "-" -and (Test-Path $p)) { $cfg.blender_path = $p } else { $cfg.enable_blender = $false; Warn "Модуль Blender выключен" }
        }
    }
    if ($cfg.blender_path) { Ok "Blender: $($cfg.blender_path)" }
}

# ------------------------------------------------------------- roblox ------
if ($cfg.enable_roblox) {
    Step "Проверяю Roblox Studio и Rojo"
    function Find-Studio {
        $dirs = @("$env:LOCALAPPDATA\Roblox\Versions", "${env:ProgramFiles(x86)}\Roblox\Versions", "$env:ProgramFiles\Roblox\Versions")
        $f = foreach ($d in $dirs) { if ($d -and (Test-Path $d)) { Get-ChildItem $d -Filter RobloxStudioBeta.exe -Recurse -ErrorAction SilentlyContinue } }
        $s = $f | Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($s) { return $s.FullName } else { return $null }
    }
    $cfg.studio_path = Find-Studio
    if (-not $cfg.studio_path) {
        Warn "Roblox Studio не найден."
        if (AskYN "Скачать и запустить установщик Roblox Studio?" $true) {
            $inst = Join-Path $ToolsDir "RobloxStudioInstaller.exe"
            try {
                Download "https://setup.rbxcdn.com/RobloxStudioInstaller.exe" $inst
                Start-Process $inst
                RH "  Дождитесь окончания установки (войдите в аккаунт можно позже) и нажмите Enter"
            } catch { Warn "Не удалось скачать: установите Studio вручную с https://create.roblox.com" }
            $cfg.studio_path = Find-Studio
        }
    }
    if ($cfg.studio_path) { Ok "Roblox Studio: $($cfg.studio_path)" } else { Warn "Studio не найден - сборка .rbxlx всё равно будет работать" }

    function Get-RojoAsset($release, [string]$architecture) {
        $target = switch ($architecture) {
            "AMD64" { "x86_64" }
            "ARM64" { "aarch64" }
            default { throw "Rojo не поддерживает архитектуру Windows: $architecture" }
        }
        $asset = $release.assets | Where-Object { $_.name -match "-windows-$target\.zip$" } | Select-Object -First 1
        if (-not $asset) { throw "В выпуске Rojo $($release.tag_name) нет архива для Windows $target" }
        return $asset
    }
    function Test-Rojo([string]$exe) {
        if (-not $exe -or -not (Test-Path -LiteralPath $exe -PathType Leaf)) { return $false }
        try {
            $version = & $exe --version 2>$null
            return ($LASTEXITCODE -eq 0 -and "$version" -match "\brojo\s+\d")
        } catch { return $false }
    }

    $rojoDir = Join-Path $ToolsDir "rojo"
    $rojo = Get-ChildItem -Path $rojoDir -Filter rojo.exe -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($rojo -and -not (Test-Rojo $rojo.FullName)) {
        Warn "Найденный Rojo не запускается - скачаю версию для этого компьютера"
        $rojo = $null
    }
    if (-not $rojo) {
        Say "  Скачиваю Rojo (синхронизация файлов со Studio)..."
        try {
            $rel = Invoke-RestMethod "https://api.github.com/repos/rojo-rbx/rojo/releases/latest" -Headers @{ "User-Agent" = "pc-bridge" }
            $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
            $asset = Get-RojoAsset $rel $arch
            $zip = Join-Path $ToolsDir "rojo.zip"
            Download $asset.browser_download_url $zip
            Expand-Archive -Path $zip -DestinationPath $rojoDir -Force
            Remove-Item $zip -Force
            $rojo = Get-ChildItem -Path $rojoDir -Filter rojo.exe -Recurse | Select-Object -First 1
            $cfg.rojo_plugin_installed = $false
        } catch { Warn "Не удалось скачать Rojo: $($_.Exception.Message)" }
    }
    if ($rojo -and (Test-Rojo $rojo.FullName)) {
        $cfg.rojo_path = $rojo.FullName
        Ok "Rojo: $($cfg.rojo_path)"
        if ($cfg.studio_path -and -not $cfg.rojo_plugin_installed) {
            & $cfg.rojo_path plugin install
            if ($LASTEXITCODE -eq 0) { $cfg.rojo_plugin_installed = $true; Ok "Плагин Rojo установлен в Studio" }
        }
    } else {
        $cfg.rojo_path = $null
        $cfg.rojo_plugin_installed = $false
        Warn "Без рабочего Rojo будут работать только Studio и файлы"
    }
}
Save-Config

# -------------------------------------------------------------- start ------
Step "Запускаю сервер"
$port = [int]$cfg.port
if (Test-Port $port) { Fail "Порт $port уже занят другой программой. Запустите SETTINGS.bat и выберите другой порт." }
$srvOut = Join-Path $LogsDir "server.out.log"
$srvErr = Join-Path $LogsDir "server.err.log"
$server = Start-Process -FilePath $VenvPy -ArgumentList @("-u", "`"$ServerPy`"") -WorkingDirectory $Root -WindowStyle Hidden -PassThru `
          -RedirectStandardOutput $srvOut -RedirectStandardError $srvErr
$up = $false
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    if ($server.HasExited) { break }
    if (Test-Port $port) { $up = $true; break }
}
if (-not $up) { Say "  Лог сервера:"; Tail $srvErr 25; Fail "Сервер не запустился." }
Ok "Сервер работает на порту $port"

$others = Get-Process ngrok -ErrorAction SilentlyContinue
if ($others) {
    if (AskYN "Уже запущен другой ngrok (бесплатный тариф разрешает мало сессий). Закрыть его?" $true) { $others | Stop-Process -Force; Start-Sleep 1 }
}

Step "Открываю туннель ngrok"
$ngLog = Join-Path $LogsDir "ngrok.log"
$ngArgs = @("http", "$port", "--host-header=rewrite", "--log=stdout")
if ($cfg.ngrok_domain) {
    $verText = (& $ngrok version) -join " "
    $useUrl = $true
    if ($verText -match "(\d+)\.(\d+)\.") { $useUrl = ([int]$Matches[1] -gt 3) -or ([int]$Matches[1] -eq 3 -and [int]$Matches[2] -ge 16) }
    if ($useUrl) { $ngArgs += "--url=https://$($cfg.ngrok_domain)" } else { $ngArgs += "--domain=$($cfg.ngrok_domain)" }
}
$ng = Start-Process -FilePath $ngrok -ArgumentList $ngArgs -WindowStyle Hidden -PassThru -RedirectStandardOutput $ngLog
@{ server = $server.Id; ngrok = $ng.Id } | ConvertTo-Json | Set-Content -Path $PidPath

$public = $null
for ($i = 0; $i -lt 30 -and -not $public; $i++) {
    Start-Sleep -Seconds 1
    if ($ng.HasExited) { break }
    try {
        $t = Invoke-RestMethod "http://127.0.0.1:4040/api/tunnels" -TimeoutSec 3
        $public = ($t.tunnels | Where-Object { $_.public_url -like "https*" } | Select-Object -First 1).public_url
    } catch {}
    if (-not $public -and (Test-Path $ngLog)) {
        $m = Select-String -Path $ngLog -Pattern "url=(https://\S+)" | Select-Object -Last 1
        if ($m) { $public = $m.Matches[0].Groups[1].Value }
    }
}
if (-not $public) {
    Say "  Лог ngrok:"; Tail $ngLog 20
    $logText = if (Test-Path $ngLog) { Get-Content $ngLog -Raw } else { "" }
    if ($logText -match "ERR_NGROK_121") { Warn "ngrok слишком старый. Удалите tools\ngrok.exe и запустите START.bat снова - скачается новая версия." }
    if ($logText -match "ERR_NGROK_105|ERR_NGROK_107|ERR_NGROK_4018") { Warn "Неверный authtoken. Выполните: ngrok config add-authtoken ВАШ_ТОКЕН (https://dashboard.ngrok.com/get-started/your-authtoken)" }
    if ($logText -match "ERR_NGROK_108") { Warn "ngrok уже запущен на другом ПК или в другом окне. Закройте его (STOP.bat) и попробуйте снова." }
    if ($logText -match "ERR_NGROK_313|ERR_NGROK_319|ERR_NGROK_320") { Warn "Домен ngrok не ваш или указан с ошибкой. SETTINGS.bat -> укажите домен из https://dashboard.ngrok.com/domains" }
    Stop-Old
    Fail "ngrok не открыл туннель (частые причины: неверный токен, чужой домен, уже запущен ngrok на другом ПК)."
}
$mcpUrl = "$($public.TrimEnd('/'))/$($cfg.secret)/mcp"
Set-Content -Path (Join-Path $Root "URL.txt") -Value $mcpUrl
try { Set-Clipboard -Value $mcpUrl } catch {}
Ok "Туннель: $public"

Step "Самопроверка через интернет"
try {
    $body = '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"selftest","version":"1.2"}}}'
    $r = Invoke-WebRequest -Uri $mcpUrl -Method Post -Body $body -ContentType "application/json" -UseBasicParsing -TimeoutSec 20 `
         -Headers @{ "Accept" = "application/json, text/event-stream"; "ngrok-skip-browser-warning" = "1" }
    if ($r.StatusCode -eq 200 -and $r.Content -match "serverInfo") { Ok "Сервер отвечает из интернета" } else { Warn "Странный ответ: $($r.StatusCode)" }
} catch { Warn "Самопроверка не прошла: $($_.Exception.Message)" }

$mods = @("файлы")
if ($cfg.enable_internet) { $mods += "интернет" }
if ($cfg.enable_blender)  { $mods += "Blender" }
if ($cfg.enable_roblox)   { $mods += "Roblox" }
if ($cfg.enable_screen)   { $mods += "экран" }
if ($cfg.enable_shell)    { $mods += "командная строка" }

W ""
W "  ================================================================" -ForegroundColor Green
W "   ГОТОВО! Адрес для Notion (уже скопирован в буфер обмена):" -ForegroundColor Green
W ""
W "   $mcpUrl" -ForegroundColor White
W ""
W "   Модули: $($mods -join ', ')" -ForegroundColor Green
W "  ================================================================" -ForegroundColor Green
Say ""
Say "  Как подключить к агенту (один раз, если адрес не меняется):" White
Say "   1. Откройте агента в Notion -> Настройки (Settings) -> Tools and access -> Add connection"
Say "   2. Выберите Custom MCP server (свой MCP-сервер)"
Say "   3. В поле URL вставьте адрес (Ctrl+V) - он уже скопирован в буфер обмена"
Say "   4. В поле Authentication выберите None (без авторизации)."
Say "      Логин, пароль или токен вводить НЕ нужно - секретный ключ уже спрятан в адресе"
Say "   5. Сохраните подключение"
Say "   6. Напишите агенту: 'проверь PC Bridge, вызови server_info'"
Say ""
Say "  Адрес также сохранён в URL.txt. Не показывайте его никому - это ключ к вашему ПК." Yellow
if (-not $cfg.ngrok_domain) { Say "  Без своего домена адрес меняется при каждом запуске - придётся обновлять подключение." Yellow }
Say ""
Say "  Мост работает, пока открыто это окно.  Q = остановить." Cyan

try {
    while ($true) {
        if ($server.HasExited) { Warn "Сервер остановился. Лог:"; Tail $srvErr 20; break }
        if ($ng.HasExited) { Warn "ngrok остановился. Лог:"; Tail $ngLog 10; break }
        try {
            if ([Console]::KeyAvailable) { $k = [Console]::ReadKey($true); if ($k.Key -eq "Q") { break } }
        } catch {}
        Start-Sleep -Milliseconds 500
    }
} finally {
    Stop-Old
    Say "  Мост остановлен." Cyan
}
RH "Нажмите Enter, чтобы закрыть"
