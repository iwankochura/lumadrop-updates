@echo off
setlocal DisableDelayedExpansion
set "LUMADROP_UPDATER_SELF=%~f0"
start "" powershell.exe -NoLogo -NoProfile -STA -WindowStyle Hidden -Command "try { $s=[IO.File]::ReadAllText($env:LUMADROP_UPDATER_SELF,[Text.Encoding]::UTF8); & ([scriptblock]::Create(($s -split '(?m)^# LUMADROP_UI_START\r?\n',2)[1])) } catch { Add-Type -AssemblyName PresentationFramework; [void][Windows.MessageBox]::Show($_.Exception.Message,'LumaDrop Updater') }"
exit /b
# LUMADROP_UI_START
# Standalone updater. Generated from the private app repository.
$LumaCoreSource = @'
# Windows PowerShell 5.1. Embedded in the standalone public update.bat.
Set-StrictMode -Version 2

function Get-LumaInstallDirectory([string]$ScriptDirectory) {
    $candidates = @((Join-Path $ScriptDirectory 'LumaDropV3'), (Join-Path $ScriptDirectory 'LumaDrop'), $ScriptDirectory)
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'),
            (Join-Path $env:USERPROFILE 'Downloads'), [Environment]::GetFolderPath('MyDocuments'), $env:LOCALAPPDATA)) {
        if ($folder) { $candidates += Join-Path $folder 'LumaDropV3'; $candidates += Join-Path $folder 'LumaDrop' }
    }
    foreach ($candidate in $candidates) {
        if ([IO.Path]::GetFileName($candidate.TrimEnd('\')) -notin @('LumaDrop','LumaDropV3')) { continue }
        if (Test-Path -LiteralPath (Join-Path $candidate 'extension\manifest.json') -PathType Leaf) {
            $item = Get-Item -LiteralPath $candidate -Force
            if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                $canonical = Join-Path ([IO.Path]::GetDirectoryName($candidate.TrimEnd('\'))) 'LumaDrop'
                $linkTargets = @($item.Target)
                if ($item.Name -ne 'LumaDropV3' -or $item.LinkType -ne 'Junction' -or $linkTargets.Count -ne 1 -or
                    [IO.Path]::GetFullPath([string]$linkTargets[0]).TrimEnd('\') -ne [IO.Path]::GetFullPath($canonical).TrimEnd('\')) {
                    throw 'Неизвестная ссылка вместо папки установки. Файлы не изменены.'
                }
                Assert-LumaPlainDirectory $canonical
                return [IO.Path]::GetFullPath($canonical).TrimEnd('\')
            }
            return [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        }
    }
    throw 'Не найдена папка LumaDrop или LumaDropV3. Положи update.bat рядом с ней.'
}

function Assert-LumaPlainDirectory([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Папка установки не должна быть ссылкой или точкой перенаправления.'
    }
}

function Remove-LumaWorkDirectory([string]$Path, [string]$ExpectedParent, [string]$ExpectedName) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).ProviderPath.TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($resolved) -ne [IO.Path]::GetFullPath($ExpectedParent).TrimEnd('\') -or
        [IO.Path]::GetFileName($resolved) -ne $ExpectedName) { throw 'Небезопасный путь временной папки.' }
    Assert-LumaPlainDirectory $resolved
    foreach ($child in Get-ChildItem -LiteralPath $resolved -Recurse -Force -ErrorAction Stop) {
        if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Обнаружена ссылка во временной папке.' }
    }
    Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction Stop
}

function Move-LumaDirectory([string]$Source, [string]$Destination) {
    [IO.Directory]::Move($Source, $Destination)
}

function New-LumaCompatibilityLink([string]$Legacy, [string]$Canonical) {
    if ([IO.Path]::GetFileName($Legacy) -ne 'LumaDropV3' -or [IO.Path]::GetFileName($Canonical) -ne 'LumaDrop' -or
        [IO.Path]::GetDirectoryName($Legacy) -ne [IO.Path]::GetDirectoryName($Canonical) -or
        (Test-Path -LiteralPath $Legacy)) { throw 'Небезопасный путь совместимости.' }
    Assert-LumaPlainDirectory $Canonical
    New-Item -ItemType Junction -Path $Legacy -Target $Canonical -ErrorAction Stop | Out-Null
}

function Stop-LumaPatcher([string]$Target, [Threading.CancellationToken]$Token) {
    # Check busy before stopping any process. No changes to the patcher API.
    $listeners = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
        Where-Object Port -eq 54789)
    if ($listeners.Count) {
        try { $health = Invoke-RestMethod -Uri 'http://127.0.0.1:54789/health' -TimeoutSec 3 -ErrorAction Stop }
        catch { throw 'Не удалось проверить патчер. Останови его вручную и повтори обновление.' }
        if ($health.status -ne 'ok' -or $null -eq $health.PSObject.Properties['busy']) {
            throw 'Состояние патчера неизвестно. Останови его вручную и повтори обновление.'
        }
        if ($health.busy) { throw 'Сейчас обрабатывается видео. Дождись завершения и повтори обновление.' }
    }
    $paths = @((Join-Path $Target 'LumaDropPatcher.exe'), (Join-Path $Target 'server\LumaDropPatcher.exe'))
    $processes = @(Get-Process -Name LumaDropPatcher -ErrorAction SilentlyContinue)
    foreach ($process in $processes) {
        $Token.ThrowIfCancellationRequested()
        $exe = $null
        try { $exe = $process.Path } catch { }
        if ($exe -and $paths -contains $exe) {
            Stop-Process -Id $process.Id -Force -ErrorAction Stop
            if (-not $process.WaitForExit(10000)) { throw 'Патчер не завершил работу. Закрой его вручную.' }
        }
    }
    $deadline = [DateTime]::UtcNow.AddSeconds(10)
    do {
        $Token.ThrowIfCancellationRequested()
        $occupied = @([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners() |
            Where-Object Port -eq 54789)
        if (-not $occupied.Count) { return }
        Start-Sleep -Milliseconds 200
    } while ([DateTime]::UtcNow -lt $deadline)
    throw 'Порт патчера занят другой программой. Закрой её и повтори обновление.'
}

function Start-LumaPatcher([string]$Target) {
    Start-Process -FilePath (Join-Path $Target 'LumaDropPatcher.exe') -ArgumentList '--start-server' -WorkingDirectory $Target -WindowStyle Normal -ErrorAction Stop | Out-Null
}

function Get-LumaRemoteText($Client, [string]$Uri, [Threading.CancellationToken]$Token) {
    $response = $Client.GetAsync($Uri, $Token).GetAwaiter().GetResult()
    try {
        [void]$response.EnsureSuccessStatusCode()
        return $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    } finally { $response.Dispose() }
}

function Invoke-LumaUpdate {
    param(
        [Parameter(Mandatory=$true)][string]$ScriptDirectory,
        [Parameter(Mandatory=$true)][scriptblock]$Publish,
        [Threading.CancellationToken]$Token = [Threading.CancellationToken]::None,
        [hashtable]$SharedState = @{},
        [string]$ReleaseApiUri = 'https://iwankochura.github.io/lumadrop-updates/version.json'
    )
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Net.Http,System.IO.Compression.FileSystem
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $work = $null; $stageRoot = $null; $backup = $null; $swapped = $false; $movedOld = $false; $canonicalBackup = $null; $movedCanonical = $false
    $client = [Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(20)
    $client.DefaultRequestHeaders.UserAgent.ParseAdd('LumaDrop-Updater/2.0')
    try {
        & $Publish @{ Kind='Status'; Stage='ПРОВЕРКА ОБНОВЛЕНИЯ'; Detail='Ищем установленную программу'; Progress=0; Indeterminate=$true }
        $target = Get-LumaInstallDirectory $ScriptDirectory
        Assert-LumaPlainDirectory $target
        # Never rename the folder hosting this updater process's working directory.
        Set-Location -LiteralPath ([IO.Path]::GetTempPath())
        [Environment]::CurrentDirectory = [IO.Path]::GetTempPath()
        $parent = [IO.Path]::GetDirectoryName($target)
        $originalTarget = $target
        $installTarget = Join-Path $parent 'LumaDrop'
        $migrating = [IO.Path]::GetFileName($target) -eq 'LumaDropV3'
        if ($migrating) { & $Publish @{Kind='Log';Text='Обнаружена старая папка LumaDropV3. Новая версия будет установлена в LumaDrop.'} }
        if ($migrating -and (Test-Path -LiteralPath $installTarget)) {
            Assert-LumaPlainDirectory $installTarget
            $priorManifestPath = Join-Path $installTarget 'extension\manifest.json'
            if (-not (Test-Path -LiteralPath $priorManifestPath -PathType Leaf)) { throw 'Рядом уже есть другая папка LumaDrop. Файлы не изменены.' }
            $priorManifest = Get-Content -LiteralPath $priorManifestPath -Raw | ConvertFrom-Json
            if ([string]$priorManifest.name -notmatch '^LumaDrop(?: V3)?$') { throw 'Папка LumaDrop принадлежит другой программе. Файлы не изменены.' }
        }
        $manifest = Get-Content -LiteralPath (Join-Path $target 'extension\manifest.json') -Raw | ConvertFrom-Json
        if ([string]$manifest.name -notmatch '^LumaDrop(?: V3)?$') { throw 'В выбранной папке нет расширения LumaDrop. Файлы не изменены.' }
        $installed = [version]([string]$manifest.version)
        & $Publish @{ Kind='Log'; Text=('Установлена версия ' + $installed + '.'); Target=$target }
        $Token.ThrowIfCancellationRequested()
        $releaseText = Get-LumaRemoteText $client $ReleaseApiUri $Token
        $release = $releaseText | ConvertFrom-Json
        if ([string]$release.current_version -notmatch '^(\d+\.\d+\.\d+)$') {
            throw 'Сервер вернул некорректную версию релиза.'
        }
        $version = [version]$Matches[1]
        if ($version -lt $installed) { throw 'Опубликованная версия старее установленной. Обновление остановлено.' }
        if ($migrating -and (Test-Path -LiteralPath $installTarget) -and [version]([string]$priorManifest.version) -gt $version) { throw 'В папке LumaDrop уже есть более новая версия. Обновление остановлено.' }
        $expected = [string]$release.sha256
        if ($expected -notmatch '^[a-fA-F0-9]{64}$') { throw 'Контрольная сумма архива не найдена.' }
        $downloadUri = [uri]([string]$release.download_zip_url)
        $policyUri = [uri]$ReleaseApiUri
        $sameOrigin = $downloadUri.Authority -eq $policyUri.Authority -and $downloadUri.Scheme -eq $policyUri.Scheme
        $githubRelease = $downloadUri.Scheme -eq 'https' -and $downloadUri.Host -eq 'github.com' -and $downloadUri.AbsolutePath.StartsWith('/iwankochura/lumadrop-bin/releases/download/',[StringComparison]::Ordinal) -and [string]::IsNullOrEmpty($downloadUri.UserInfo) -and $downloadUri.IsDefaultPort
        if (-not $sameOrigin -and -not $githubRelease) { throw 'Недопустимый сервер архива.' }
        $privateLan = $downloadUri.Host -match '^(192\.168\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.)'
        if ($downloadUri.Scheme -ne 'https' -and -not $downloadUri.IsLoopback -and -not $privateLan) { throw 'HTTP разрешён только в локальной сети.' }
        $asset = @(@{ browser_download_url = $downloadUri.AbsoluteUri; size = [long]$release.size_bytes })
        & $Publish @{ Kind='Log'; Text=('Доступна версия ' + $version + '. Скачиваем архив.'); Version=$version.ToString() }
        $id = [Guid]::NewGuid().ToString('N')
        $workName = 'LumaDrop-update-' + $id
        $work = Join-Path ([IO.Path]::GetTempPath()) $workName
        [void][IO.Directory]::CreateDirectory($work)
        $zipPath = Join-Path $work 'LumaDrop.zip'
        $response = $null; $inputStream = $null; $outputStream = $null
        try {
            $response = $client.GetAsync([string]$asset[0].browser_download_url,
                [Net.Http.HttpCompletionOption]::ResponseHeadersRead,$Token).GetAwaiter().GetResult()
            [void]$response.EnsureSuccessStatusCode()
            $total = $response.Content.Headers.ContentLength
            if ($total -and [long]$asset[0].size -gt 0 -and $total -ne [long]$asset[0].size) {
                throw 'Размер архива отличается от размера в релизе.'
            }
            $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
            $outputStream = [IO.File]::Create($zipPath)
            $buffer = New-Object byte[] 1048576
            [long]$received = 0
            $watch = [Diagnostics.Stopwatch]::StartNew(); $lastPublish = -1.0
            while ($true) {
                $Token.ThrowIfCancellationRequested()
                $readTask = $inputStream.ReadAsync($buffer,0,$buffer.Length,$Token)
                if (-not $readTask.Wait(90000,$Token)) { throw 'Скачивание прервалось: сервер слишком долго не отвечает.' }
                $count = $readTask.GetAwaiter().GetResult()
                if ($count -eq 0) { break }
                $outputStream.Write($buffer,0,$count); $received += $count
                if ($received -gt 2147483648) { throw 'Архив превышает допустимый размер.' }
                if ($watch.Elapsed.TotalSeconds - $lastPublish -ge 0.1) {
                    $lastPublish = $watch.Elapsed.TotalSeconds
                    $speed = $received / [Math]::Max(0.1,$watch.Elapsed.TotalSeconds) / 1MB
                    $ratio = if ($total -gt 0) { [Math]::Min(1,$received / $total) } else { 0 }
                    $detail = if ($total -gt 0) { '{0:N1} / {1:N1} МБ · {2:N1} МБ/с · {3:0}%' -f ($received/1MB),($total/1MB),$speed,($ratio*100) } else { '{0:N1} МБ · {1:N1} МБ/с' -f ($received/1MB),$speed }
                    & $Publish @{ Kind='Status'; Stage='СКАЧИВАНИЕ ОБНОВЛЕНИЯ'; Detail=$detail; Progress=(5+55*$ratio); Indeterminate=($null -eq $total) }
                }
            }
            if ($received -eq 0 -or ($total -and $received -ne $total) -or
                ([long]$asset[0].size -gt 0 -and $received -ne [long]$asset[0].size)) { throw 'Архив скачан не полностью.' }
        } finally {
            if ($outputStream) { $outputStream.Dispose() }; if ($inputStream) { $inputStream.Dispose() }; if ($response) { $response.Dispose() }
        }
        $Token.ThrowIfCancellationRequested()
        & $Publish @{ Kind='Status'; Stage='ПРОВЕРКА АРХИВА'; Detail='Проверяем SHA-256 и состав файлов'; Progress=60; Indeterminate=$true }
        $hashStream = [IO.File]::OpenRead($zipPath)
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [BitConverter]::ToString($sha.ComputeHash($hashStream)).Replace('-','') }
        finally { $hashStream.Dispose(); $sha.Dispose() }
        if ($actualHash -ne $expected) {
            throw 'Контрольная сумма не совпала. Архив не будет установлен.'
        }
        $stageName = '.lumadrop-stage-' + $id
        $stageRoot = Join-Path $parent $stageName
        $backupName = '.lumadrop-backup-' + $id
        $backup = Join-Path $parent $backupName
        if ((Test-Path -LiteralPath $stageRoot) -or (Test-Path -LiteralPath $backup)) { throw 'Временная папка уже существует.' }
        $archive = [IO.Compression.ZipFile]::OpenRead($zipPath)
        try {
            $required = @('LumaDrop/extension/manifest.json','LumaDrop/LumaDropPatcher.exe','LumaDrop/version.txt')
            foreach ($name in $required) { if (-not $archive.GetEntry($name)) { throw ('В архиве отсутствует файл: ' + $name) } }
            if ($archive.Entries.Count -gt 20000) { throw 'Слишком много файлов в архиве.' }
            [long]$expandedBytes = 0
            $destinations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName.Replace('\','/')
                if (-not $name.StartsWith('LumaDrop/',[StringComparison]::Ordinal) -or
                    $name -match '(^|/)\.\.?(/|$)|:|[<>"|?*]|[. ](/|$)' -or
                    $name -match '(^|/)(CON|PRN|AUX|NUL|COM[0-9]|LPT[0-9])(\.|/|$)') { throw 'Небезопасное имя файла в архиве.' }
                $full = [IO.Path]::GetFullPath((Join-Path $stageRoot $name))
                if (-not $full.StartsWith($stageRoot+'\',[StringComparison]::OrdinalIgnoreCase) -or -not $destinations.Add($full)) {
                    throw 'Небезопасный или повторяющийся путь в архиве.'
                }
                $expandedBytes += $entry.Length
            }
            if ($expandedBytes -gt 10737418240) { throw 'Распакованный архив слишком большой.' }
            [void][IO.Directory]::CreateDirectory($stageRoot)
            [long]$doneBytes = 0
            foreach ($entry in $archive.Entries) {
                $Token.ThrowIfCancellationRequested()
                $destination = [IO.Path]::GetFullPath((Join-Path $stageRoot $entry.FullName))
                if ($entry.FullName.EndsWith('/')) { [void][IO.Directory]::CreateDirectory($destination); continue }
                [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                $source = $null; $dest = $null
                try {
                    $source = $entry.Open(); $dest = [IO.File]::Create($destination)
                    while (($count=$source.Read($buffer,0,$buffer.Length)) -gt 0) {
                        $Token.ThrowIfCancellationRequested(); $dest.Write($buffer,0,$count); $doneBytes += $count
                        & $Publish @{ Kind='Status'; Stage='ПОДГОТОВКА ФАЙЛОВ'; Detail=('Распаковка · {0:0}%' -f ($doneBytes/[Math]::Max(1,$expandedBytes)*100)); Progress=(65+20*$doneBytes/[Math]::Max(1,$expandedBytes)); Indeterminate=$false }
                    }
                } finally { if ($source) { $source.Dispose() }; if ($dest) { $dest.Dispose() } }
            }
        } finally { $archive.Dispose() }
        $newRoot = Join-Path $stageRoot 'LumaDrop'
        $newManifest = Get-Content -LiteralPath (Join-Path $newRoot 'extension\manifest.json') -Raw | ConvertFrom-Json
        $versionText = (Get-Content -LiteralPath (Join-Path $newRoot 'version.txt') -Raw).Trim()
        if ([version]([string]$newManifest.version) -ne $version -or [version]$versionText -ne $version) { throw 'Версия внутри архива не совпадает с версией релиза.' }
        $exe = [IO.File]::OpenRead((Join-Path $newRoot 'LumaDropPatcher.exe'))
        try { if ($exe.ReadByte() -ne 77 -or $exe.ReadByte() -ne 90) { throw 'В архиве некорректный EXE патчера.' } } finally { $exe.Dispose() }
        & $Publish @{ Kind='Log'; Text='Архив проверен. Готовим замену программы.' }
        & $Publish @{ Kind='Status'; Stage='УСТАНОВКА ОБНОВЛЕНИЯ'; Detail='Проверяем, завершена ли обработка видео'; Progress=88; Indeterminate=$true }
        $Token.ThrowIfCancellationRequested()
        Stop-LumaPatcher $originalTarget $Token
        if ($migrating -and (Test-Path -LiteralPath $installTarget)) { Stop-LumaPatcher $installTarget $Token }
        $Token.ThrowIfCancellationRequested()
        $SharedState.Critical = $true
        Assert-LumaPlainDirectory $originalTarget
        $canonicalBackupName = '.lumadrop-existing-' + $id
        $canonicalBackup = Join-Path $parent $canonicalBackupName
        if ([IO.Path]::GetDirectoryName($backup) -ne $parent -or [IO.Path]::GetDirectoryName($stageRoot) -ne $parent -or
            [IO.Path]::GetDirectoryName($installTarget) -ne $parent -or (Test-Path -LiteralPath $canonicalBackup)) { throw 'Небезопасный путь установки.' }
        & $Publish @{ Kind='Status'; Stage='УСТАНОВКА ОБНОВЛЕНИЯ'; Detail='Заменяем файлы программы'; Progress=93; Indeterminate=$true }
        try {
            Move-LumaDirectory $originalTarget $backup; $movedOld = $true
            if ($migrating -and (Test-Path -LiteralPath $installTarget)) {
                Move-LumaDirectory $installTarget $canonicalBackup; $movedCanonical = $true
            }
            Move-LumaDirectory $newRoot $installTarget; $swapped = $true
            if ($migrating) { New-LumaCompatibilityLink $originalTarget $installTarget }
        } catch {
            $swapError = $_.Exception.Message
            try {
                if ($swapped) {
                    $compat = Get-Item -LiteralPath $originalTarget -Force -ErrorAction SilentlyContinue
                    if ($migrating -and $compat -and $compat.LinkType -eq 'Junction' -and @($compat.Target)[0] -eq $installTarget) {
                        [IO.Directory]::Delete($originalTarget)
                    }
                    Move-LumaDirectory $installTarget $newRoot; $swapped = $false
                }
                if ($movedCanonical) { Move-LumaDirectory $canonicalBackup $installTarget; $movedCanonical = $false }
                if ($movedOld) { Move-LumaDirectory $backup $originalTarget; $movedOld = $false }
            } catch { throw ('Не удалось восстановить папки. Резервные копии сохранены рядом с установкой: ' + $backup) }
            throw ('Не удалось заменить файлы. Старая версия восстановлена. Закрой программы, открытые в папке LumaDrop. Причина: ' + $swapError)
        }
        $target = $installTarget
        foreach ($saved in @($backup,$canonicalBackup)) {
            if ($saved -and (Test-Path -LiteralPath $saved)) {
                try { [IO.File]::SetAttributes($saved,([IO.File]::GetAttributes($saved) -bor [IO.FileAttributes]::Hidden)) } catch { }
            }
        }
        & $Publish @{ Kind='Log'; Text=('Установлена версия ' + $version + '.') }
        $launched = $true
        try { Start-LumaPatcher $target }
        catch { $launched = $false; & $Publish @{ Kind='Log'; Text='Открой LumaDropPatcher.exe вручную. Резервная копия сохранена.' } }
        & $Publish @{ Kind='Log'; Text=('Резервная копия сохранена в папке: ' + $backup) }
        if ($migrating) {
            & $Publish @{ Kind='Log'; Text='Файлы установлены в LumaDrop. Старый путь LumaDropV3 сохранён как ссылка для Chrome. В chrome://extensions нажми «Обновить» у LumaDrop, затем обнови вкладку TikTok Studio.' }
        } else { & $Publish @{ Kind='Log'; Text='В Chrome открой chrome://extensions и перезагрузи LumaDrop, затем обнови вкладку TikTok Studio.' } }
        & $Publish @{ Kind='Done'; Stage='ОБНОВЛЕНИЕ УСТАНОВЛЕНО'; Detail=('Версия ' + $version + ' · обнови расширение в Chrome'); Progress=100; Target=$target; Version=$version.ToString(); Launched=$launched }
        return @{ Version=$version.ToString(); Target=$target; Launched=$launched }
    } finally {
        $client.Dispose()
        $SharedState.Critical = $false
        if ($stageRoot) { try { Remove-LumaWorkDirectory $stageRoot $parent $stageName } catch { } }
        if ($work) { try { Remove-LumaWorkDirectory $work ([IO.Path]::GetTempPath()) $workName } catch { } }
        # A backup is deliberately NEVER removed after a failed swap/rollback.
    }
}

'@
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName PresentationFramework,PresentationCore,WindowsBase
$mutex = [Threading.Mutex]::new($false,'Local\LumaDropUpdater')
$ownsMutex = $false
try { $ownsMutex = $mutex.WaitOne(0) } catch [Threading.AbandonedMutexException] { $ownsMutex = $true }
if (-not $ownsMutex) {
    [void][Windows.MessageBox]::Show('Обновлятор уже открыт. Переключись в его окно.','LumaDrop Updater')
    $mutex.Dispose(); return
}
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="LumaDrop Updater" Width="560" Height="600" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen" Background="#111610" Foreground="#F1F5ED" FontFamily="Segoe UI" FontSize="12" UseLayoutRounding="True">
<Window.Icon><DrawingImage><DrawingImage.Drawing><DrawingGroup><GeometryDrawing Brush="#D0FA70" Geometry="M0,0 H16 V16 H0 Z"/><GeometryDrawing Brush="#243715" Geometry="M4,3 H7 V10 H12 V13 H4 Z"/></DrawingGroup></DrawingImage.Drawing></DrawingImage></Window.Icon>
<Window.Resources>
 <Style TargetType="Button"><Setter Property="Foreground" Value="#243715"/><Setter Property="Background" Value="#C9EF86"/><Setter Property="BorderBrush" Value="#C9EF86"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="13"/><Setter Property="FontWeight" Value="SemiBold"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="Surface" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1" CornerRadius="12"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="Surface" Property="Background" Value="#DDFDA0"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="Surface" Property="BorderBrush" Value="#F1F5ED"/><Setter TargetName="Surface" Property="BorderThickness" Value="2"/></Trigger><Trigger Property="IsEnabled" Value="False"><Setter TargetName="Surface" Property="Opacity" Value="0.5"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style>
 <Style TargetType="ScrollBar"><Setter Property="Width" Value="8"/><Setter Property="Background" Value="Transparent"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}"><Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False" Opacity="0"/></Track.DecreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border Background="#46533A" CornerRadius="3" Margin="1,0"/></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False" Opacity="0"/></Track.IncreaseRepeatButton></Track></ControlTemplate></Setter.Value></Setter></Style>
</Window.Resources>
<Grid x:Name="Root"><Grid.Background><LinearGradientBrush StartPoint="0,0" EndPoint="1,1"><GradientStop Color="#1E241B" Offset="0"/><GradientStop Color="#131912" Offset="0.55"/><GradientStop Color="#111610" Offset="1"/></LinearGradientBrush></Grid.Background>
 <Grid Height="36" VerticalAlignment="Top" Margin="26,24,26,0"><Grid.ColumnDefinitions><ColumnDefinition Width="36"/><ColumnDefinition Width="*"/><ColumnDefinition Width="Auto"/></Grid.ColumnDefinitions><Image x:Name="BrandLogo" Width="36" Height="36"><Image.Clip><RectangleGeometry Rect="0,0,36,36" RadiusX="10" RadiusY="10"/></Image.Clip></Image><TextBlock Grid.Column="1" Text="LumaDrop" FontSize="19" FontWeight="SemiBold" VerticalAlignment="Center" Margin="12,0,0,0"/><TextBlock x:Name="BrandCaption" Grid.Column="2" Text="v2.0.0" Foreground="#A8B49B" VerticalAlignment="Center"/></Grid>
 <Border Width="58" Height="58" VerticalAlignment="Top" Margin="0,92,0,0" CornerRadius="18" Background="#253020" BorderBrush="#46533A" BorderThickness="1"><Path Data="M12,0 V20 M4,12 L12,20 20,12 M0,23 V29 H24 V23" Width="26" Height="29" Stretch="Uniform" Stroke="#D0FA70" StrokeThickness="1.8" StrokeStartLineCap="Round" StrokeEndLineCap="Round" StrokeLineJoin="Round"/></Border>
 <StackPanel VerticalAlignment="Top" Margin="28,169,28,0"><StackPanel Orientation="Horizontal" HorizontalAlignment="Center"><Ellipse x:Name="Dot" Width="7" Height="7" Fill="#D0FA70" Margin="0,2,9,0"/><TextBlock x:Name="Status" Text="Проверка обновления" FontSize="20" FontWeight="SemiBold" TextWrapping="Wrap" TextAlignment="Center" MaxWidth="440"/></StackPanel><TextBlock x:Name="Detail" Text="Подключаемся к серверу обновлений" Foreground="#A8B49B" Margin="0,10,0,0" TextAlignment="Center" TextWrapping="Wrap" MaxWidth="460"/></StackPanel>
 <Grid ClipToBounds="True" x:Name="Track" Margin="44,242,44,0" Height="5" VerticalAlignment="Top" Background="#35402E"><Border x:Name="Fill" Width="0" Background="#D0FA70" CornerRadius="3" HorizontalAlignment="Left"/></Grid>
 <Button x:Name="Action" Content="Отмена" Width="190" Height="42" VerticalAlignment="Top" Margin="0,267,0,0"/>
 <Border BorderBrush="#35402E" BorderThickness="1" CornerRadius="14" Background="#1A2217" Margin="26,331,26,58"><Grid Margin="14,12"><Grid.RowDefinitions><RowDefinition Height="26"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="Журнал обновления" Foreground="#C3D1B5" FontSize="12" FontWeight="SemiBold"/><ScrollViewer x:Name="Scroll" Grid.Row="1" VerticalScrollBarVisibility="Auto"><TextBlock x:Name="Log" FontSize="12" TextWrapping="Wrap" LineHeight="20"/></ScrollViewer></Grid></Border>
 <Grid VerticalAlignment="Bottom" Margin="28,0,28,20"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock x:Name="OpenFolder" Cursor="Hand" Text="Папка LumaDrop" Foreground="#A8B49B"/><TextBlock Grid.Column="1" Text="Закрыть · Ctrl+Q" Foreground="#A8B49B" HorizontalAlignment="Right"/></Grid>
</Grid></Window>
'@
$window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))

# LUMA_BRAND_START
$logoBytes=[Convert]::FromBase64String('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')
$logoMemory=[IO.MemoryStream]::new([byte[]]$logoBytes)
$brandBitmap=[Windows.Media.Imaging.BitmapImage]::new()
$brandBitmap.BeginInit();$brandBitmap.CacheOption=[Windows.Media.Imaging.BitmapCacheOption]::OnLoad;$brandBitmap.StreamSource=$logoMemory;$brandBitmap.EndInit();$brandBitmap.Freeze();$logoMemory.Dispose()
$window.Icon=$brandBitmap;$window.FindName('BrandLogo').Source=$brandBitmap
# LUMA_BRAND_END

$ui = @{}
'Root','Dot','Status','Detail','Track','Fill','Action','Scroll','Log','OpenFolder','BrandCaption' | ForEach-Object { $ui[$_]=$window.FindName($_) }
$script:directory = [IO.Path]::GetDirectoryName($env:LUMADROP_UPDATER_SELF)
$script:queue = [Collections.Concurrent.ConcurrentQueue[hashtable]]::new()
$script:shared = [hashtable]::Synchronized(@{ Critical=$false; Finished=$false })
$script:cts = $null; $script:worker = $null; $script:async = $null
$script:running = $false; $script:closeRequested = $false; $script:terminal = $null
$script:target = $null; $script:marquee = $false; $script:lastProgress = 0.0
$slide = [Windows.Media.TranslateTransform]::new()
$ui.Fill.RenderTransform = $slide
$pulse = [Windows.Media.Animation.DoubleAnimation]::new(0.4,1,[Windows.Duration]::new([TimeSpan]::FromMilliseconds(650)))
$pulse.AutoReverse=$true; $pulse.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
$timer = [Windows.Threading.DispatcherTimer]::new()
$timer.Interval = [TimeSpan]::FromMilliseconds(60)

function Add-UiLog([string]$Text) {
    if ($ui.Log.Inlines.Count) { $ui.Log.Inlines.Add([Windows.Documents.LineBreak]::new()) }
    $stamp=[Windows.Documents.Run]::new(('['+(Get-Date -Format 'HH:mm:ss')+']  '))
    $stamp.Foreground='#A8B49B'; $ui.Log.Inlines.Add($stamp)
    $ui.Log.Inlines.Add([Windows.Documents.Run]::new($Text)); $ui.Scroll.ScrollToEnd()
}
function Set-UiProgress([double]$Value,[bool]$Indeterminate) {
    $script:lastProgress = $Value
    if ($Indeterminate) {
        if (-not $script:marquee) {
            $ui.Fill.BeginAnimation([Windows.FrameworkElement]::WidthProperty,$null)
            $ui.Fill.Width=100
            $anim=[Windows.Media.Animation.DoubleAnimation]::new(-100,$ui.Track.ActualWidth,[Windows.Duration]::new([TimeSpan]::FromSeconds(1.4)))
            $anim.RepeatBehavior=[Windows.Media.Animation.RepeatBehavior]::Forever
            $slide.BeginAnimation([Windows.Media.TranslateTransform]::XProperty,$anim)
            $script:marquee=$true
        }
    } else {
        $slide.BeginAnimation([Windows.Media.TranslateTransform]::XProperty,$null); $slide.X=0
        $script:marquee=$false
        $width=[Math]::Max(0,$ui.Track.ActualWidth*[Math]::Min(100,[Math]::Max(0,$Value))/100)
        $anim=[Windows.Media.Animation.DoubleAnimation]::new($width,[Windows.Duration]::new([TimeSpan]::FromMilliseconds(120)))
        $ui.Fill.BeginAnimation([Windows.FrameworkElement]::WidthProperty,$anim)
    }
}
function Request-UiCancel {
    if (-not $script:running) { $window.Close(); return }
    if (-not $script:shared.Critical -and -not $script:cts.IsCancellationRequested) {
        $script:cts.Cancel(); $ui.Action.Content='Отменяю…'; $ui.Action.IsEnabled=$false
        Add-UiLog 'Отменяем обновление. Ждём завершения текущей операции.'
    } elseif ($script:shared.Critical) {
        Add-UiLog 'Завершаем замену файлов. Это окно закроется после установки.'
    }
}
function Open-InstallFolder {
    $folder=if ($script:target) { $script:target } else { $script:directory }
    if (Test-Path -LiteralPath $folder -PathType Container) {
        Start-Process -FilePath explorer.exe -ArgumentList ('"'+$folder+'"')
    }
}
function Start-UiUpdate {
    if ($script:running) { return }
    $script:terminal=$null; $script:closeRequested=$false; $script:shared.Finished=$false
    $script:cts=[Threading.CancellationTokenSource]::new()
    $script:worker=[powershell]::Create()
    [void]$script:worker.AddScript({
        param($queue,$shared,$token,$directory,$core)
        $ErrorActionPreference='Stop'
        try {
            . ([scriptblock]::Create($core))
            $publish={ param($event) $queue.Enqueue($event) }
            [void](Invoke-LumaUpdate -ScriptDirectory $directory -Publish $publish -Token $token -SharedState $shared)
        } catch {
            $cause=$_.Exception
            while ($cause.InnerException) { $cause=$cause.InnerException }
            if ($token.IsCancellationRequested -and $cause -is [OperationCanceledException]) {
                $queue.Enqueue(@{Kind='Cancelled'; Stage='ОБНОВЛЕНИЕ ОТМЕНЕНО'; Detail='Файлы программы не заменены'; Text='Обновление отменено.'})
            } else {
                $message=$_.Exception.Message
                if ($cause -is [Net.Http.HttpRequestException]) { $message='Не удалось скачать обновление. Проверь интернет и повтори попытку.' }
                elseif ($cause -is [IO.InvalidDataException]) { $message='Архив повреждён. Повтори скачивание обновления.' }
                elseif ($cause -is [UnauthorizedAccessException]) { $message='Нет доступа к папке программы. Проверь права доступа и повтори попытку.' }
                elseif ($cause -is [IO.IOException]) { $message='Не удалось прочитать или записать файлы. Проверь свободное место и закрой программы, использующие папку LumaDrop.' }
                $queue.Enqueue(@{Kind='Error'; Stage='Не удалось обновить'; Detail='Подробности в журнале ниже'; Text=$message})
            }
        } finally { $shared.Finished=$true }
    }.ToString()).AddArgument($script:queue).AddArgument($script:shared).AddArgument($script:cts.Token).AddArgument($script:directory).AddArgument($LumaCoreSource)
    $script:running=$true
    $ui.Dot.Fill='#D0FA70'; $ui.Dot.BeginAnimation([Windows.UIElement]::OpacityProperty,$pulse)
    $ui.Action.Content='Отмена'; $ui.Action.IsEnabled=$true
    $ui.Status.Text='Проверка обновления'; $ui.Detail.Text='Подключаемся к серверу обновлений'
    Set-UiProgress 0 $true
    $script:async=$script:worker.BeginInvoke()
    $timer.Start()
}
$timer.Add_Tick({
    $event=$null; $latest=$null
    while ($script:queue.TryDequeue([ref]$event)) {
        if ($event.ContainsKey('Target')) { $script:target=$event.Target }
        if ($event.ContainsKey('Version')) { $ui.BrandCaption.Text='v'+$event.Version }
        if ($event.Kind -eq 'Log') { Add-UiLog $event.Text }
        elseif ($event.Kind -eq 'Status') { $latest=$event }
        else { $script:terminal=$event }
    }
    if ($latest -and -not $script:terminal) {
        $ui.Status.Text=$latest.Stage; $ui.Detail.Text=$latest.Detail
        Set-UiProgress $latest.Progress ([bool]$latest.Indeterminate)
    }
    if ($script:async -and $script:async.IsCompleted) {
        try { [void]$script:worker.EndInvoke($script:async) }
        catch { if (-not $script:terminal) { $script:terminal=@{Kind='Error'; Stage='Не удалось обновить'; Detail='Повтори запуск обновлятора'; Text=$_.Exception.Message} } }
        # Drain terminal events once more after EndInvoke to avoid a completion race.
        while ($script:queue.TryDequeue([ref]$event)) {
            if ($event.ContainsKey('Target')) { $script:target=$event.Target }
            if ($event.ContainsKey('Version')) { $ui.BrandCaption.Text='v'+$event.Version }
            if ($event.Kind -eq 'Log') { Add-UiLog $event.Text }
            elseif ($event.Kind -ne 'Status') { $script:terminal=$event }
        }
        $script:worker.Dispose(); $script:cts.Dispose(); $script:async=$null
        $script:running=$false; $timer.Stop()
        $ui.Dot.BeginAnimation([Windows.UIElement]::OpacityProperty,$null); $ui.Dot.Opacity=1
        $ui.Action.IsEnabled=$true
        if (-not $script:terminal) { $script:terminal=@{Kind='Error'; Stage='Не удалось обновить'; Detail='Повтори запуск обновлятора'; Text='Операция завершилась без подтверждения установки.'} }
        $result=$script:terminal
        $ui.Status.Text=$result.Stage; $ui.Detail.Text=$result.Detail
        if ($result.Kind -eq 'Done') {
            $ui.Action.Content='Закрыть'; Set-UiProgress 100 $false
            if (-not $result.Launched) { $ui.Detail.Text='Открой LumaDropPatcher.exe вручную' }
        } else {
            Add-UiLog $result.Text
            $ui.Dot.Fill=if ($result.Kind -eq 'Error') { '#E49C88' } else { '#A8B49B' }
            $ui.Action.Content='Повторить'; Set-UiProgress $script:lastProgress $false
        }
        if ($script:closeRequested) { $window.Close() }
    }
})
$ui.Action.Add_Click({
    if ($script:running) { Request-UiCancel }
    elseif ($script:terminal -and $script:terminal.Kind -eq 'Done') { $window.Close() }
    else { Start-UiUpdate }
})
$ui.OpenFolder.Add_MouseLeftButtonUp({ Open-InstallFolder })
$window.Add_KeyDown({
    if (($_.KeyboardDevice.Modifiers -band [Windows.Input.ModifierKeys]::Control) -ne 0) {
        if ($_.Key -eq 'Q') { $window.Close(); $_.Handled=$true }
        if ($_.Key -eq 'O') { Open-InstallFolder; $_.Handled=$true }
    }
})
$window.Add_Closing({
    if ($script:running) { $_.Cancel=$true; $script:closeRequested=$true; Request-UiCancel }
})
$window.Add_Loaded({ Start-UiUpdate })
try { [void]$window.ShowDialog() }
finally {
    $timer.Stop()
    if ($ownsMutex) { $mutex.ReleaseMutex() }
    $mutex.Dispose()
}
