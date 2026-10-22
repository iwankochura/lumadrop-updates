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
    $candidates = @((Join-Path $ScriptDirectory 'LumaDropV3'), $ScriptDirectory)
    foreach ($folder in @([Environment]::GetFolderPath('Desktop'),
            (Join-Path $env:USERPROFILE 'Downloads'), [Environment]::GetFolderPath('MyDocuments'),
            $env:LOCALAPPDATA)) {
        if ($folder) { $candidates += Join-Path $folder 'LumaDropV3' }
    }
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'extension\manifest.json') -PathType Leaf) {
            return [IO.Path]::GetFullPath($candidate).TrimEnd('\')
        }
    }
    throw 'Не найдена папка LumaDropV3. Положи update.bat рядом с ней и повтори запуск.'
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
    Start-Process -FilePath (Join-Path $Target 'LumaDropPatcher.exe') -WorkingDirectory $Target -ErrorAction Stop | Out-Null
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
        [string]$ReleaseApiUri = 'https://api.github.com/repos/iwankochura/lumadrop-bin/releases/latest'
    )
    $ErrorActionPreference = 'Stop'
    Add-Type -AssemblyName System.Net.Http,System.IO.Compression.FileSystem
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $work = $null; $stageRoot = $null; $backup = $null; $swapped = $false; $movedOld = $false
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
        $manifest = Get-Content -LiteralPath (Join-Path $target 'extension\manifest.json') -Raw | ConvertFrom-Json
        $installed = [version]([string]$manifest.version)
        & $Publish @{ Kind='Log'; Text=('Установлена версия ' + $installed + '.'); Target=$target }
        $Token.ThrowIfCancellationRequested()
        $releaseText = Get-LumaRemoteText $client $ReleaseApiUri $Token
        $release = $releaseText | ConvertFrom-Json
        if ($release.draft -or $release.prerelease -or [string]$release.tag_name -notmatch '^v?(\d+\.\d+\.\d+(?:\.\d+)?)$') {
            throw 'Сервер вернул некорректную версию релиза.'
        }
        $version = [version]$Matches[1]
        if ($version -lt $installed) { throw 'Опубликованная версия старее установленной. Обновление остановлено.' }
        $asset = @($release.assets | Where-Object name -eq 'LumaDropV3.zip')
        $sumsAsset = @($release.assets | Where-Object name -eq 'SHA256SUMS.txt')
        if ($asset.Count -ne 1 -or $sumsAsset.Count -ne 1) { throw 'В релизе отсутствует архив или контрольная сумма.' }
        $Token.ThrowIfCancellationRequested()
        $sums = Get-LumaRemoteText $client ([string]$sumsAsset[0].browser_download_url) $Token
        $expected = $null
        foreach ($line in ($sums -split '\r?\n')) {
            if ($line -match '^([a-fA-F0-9]{64})\s+\*?LumaDropV3\.zip\s*$') { $expected = $Matches[1] }
        }
        if (-not $expected) { throw 'Контрольная сумма архива не найдена.' }
        & $Publish @{ Kind='Log'; Text=('Доступна версия ' + $version + '. Скачиваем архив.'); Version=$version.ToString() }
        $id = [Guid]::NewGuid().ToString('N')
        $workName = 'LumaDrop-update-' + $id
        $work = Join-Path ([IO.Path]::GetTempPath()) $workName
        [void][IO.Directory]::CreateDirectory($work)
        $zipPath = Join-Path $work 'LumaDropV3.zip'
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
            $required = @('LumaDropV3/extension/manifest.json','LumaDropV3/LumaDropPatcher.exe','LumaDropV3/README.txt','LumaDropV3/version.txt')
            foreach ($name in $required) { if (-not $archive.GetEntry($name)) { throw ('В архиве отсутствует файл: ' + $name) } }
            if ($archive.Entries.Count -gt 20000) { throw 'Слишком много файлов в архиве.' }
            [long]$expandedBytes = 0
            $destinations = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($entry in $archive.Entries) {
                $name = $entry.FullName.Replace('\','/')
                if (-not $name.StartsWith('LumaDropV3/',[StringComparison]::Ordinal) -or
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
        $newRoot = Join-Path $stageRoot 'LumaDropV3'
        $newManifest = Get-Content -LiteralPath (Join-Path $newRoot 'extension\manifest.json') -Raw | ConvertFrom-Json
        $versionText = (Get-Content -LiteralPath (Join-Path $newRoot 'version.txt') -Raw).Trim()
        if ([version]([string]$newManifest.version) -ne $version -or [version]$versionText -ne $version) { throw 'Версия внутри архива не совпадает с версией релиза.' }
        $exe = [IO.File]::OpenRead((Join-Path $newRoot 'LumaDropPatcher.exe'))
        try { if ($exe.ReadByte() -ne 77 -or $exe.ReadByte() -ne 90) { throw 'В архиве некорректный EXE патчера.' } } finally { $exe.Dispose() }
        & $Publish @{ Kind='Log'; Text='Архив проверен. Готовим замену программы.' }
        & $Publish @{ Kind='Status'; Stage='УСТАНОВКА ОБНОВЛЕНИЯ'; Detail='Проверяем, завершена ли обработка видео'; Progress=88; Indeterminate=$true }
        $Token.ThrowIfCancellationRequested()
        Stop-LumaPatcher $target $Token
        $Token.ThrowIfCancellationRequested()
        $SharedState.Critical = $true
        Assert-LumaPlainDirectory $target
        # All moves remain within the checked parent, on the same volume.
        if ([IO.Path]::GetDirectoryName($backup) -ne $parent -or [IO.Path]::GetDirectoryName($stageRoot) -ne $parent) { throw 'Небезопасный путь установки.' }
        & $Publish @{ Kind='Status'; Stage='УСТАНОВКА ОБНОВЛЕНИЯ'; Detail='Заменяем файлы программы'; Progress=93; Indeterminate=$true }
        Move-LumaDirectory $target $backup
        $movedOld = $true
        try { Move-LumaDirectory $newRoot $target; $swapped = $true }
        catch {
            try { Move-LumaDirectory $backup $target; $movedOld = $false }
            catch { throw ('Не удалось восстановить папку. Старая версия сохранена здесь: ' + $backup) }
            throw 'Не удалось заменить файлы. Старая версия восстановлена.'
        }
        & $Publish @{ Kind='Log'; Text=('Установлена версия ' + $version + '.') }
        $launched = $true
        try { Start-LumaPatcher $target }
        catch { $launched = $false; & $Publish @{ Kind='Log'; Text='Открой LumaDropPatcher.exe вручную. Резервная копия сохранена.' } }
        if ($launched) {
            try { Remove-LumaWorkDirectory $backup $parent $backupName; $movedOld = $false }
            catch { & $Publish @{ Kind='Log'; Text=('Резервная копия осталась в папке: ' + $backup) } }
        }
        & $Publish @{ Kind='Log'; Text='В Chrome открой chrome://extensions и нажми «Обновить» у LumaDrop.' }
        & $Publish @{ Kind='Done'; Stage='ОБНОВЛЕНИЕ УСТАНОВЛЕНО'; Detail=('Версия ' + $version + ' · нажми ЗАПУСТИТЬ в патчере'); Progress=100; Target=$target; Version=$version.ToString(); Launched=$launched }
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
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml" Title="LumaDrop Updater" Width="635" Height="505" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen" Background="#0F0F0F" Foreground="White" FontFamily="Consolas" FontSize="12" UseLayoutRounding="True">
<Window.Icon><DrawingImage><DrawingImage.Drawing><DrawingGroup><GeometryDrawing Brush="#C6F432" Geometry="M0,0 H16 V16 H0 Z"/><GeometryDrawing Brush="#0F0F0F" Geometry="M4,3 H7 V10 H12 V13 H4 Z"/></DrawingGroup></DrawingImage.Drawing></DrawingImage></Window.Icon><Window.Resources><Style TargetType="Button"><Setter Property="Foreground" Value="#C6F432"/><Setter Property="Background" Value="#0F0F0F"/><Setter Property="BorderBrush" Value="#C6F432"/><Setter Property="Cursor" Value="Hand"/><Setter Property="FontSize" Value="14"/><Setter Property="FontWeight" Value="Bold"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="Button"><Border x:Name="bg" Background="{TemplateBinding Background}" BorderBrush="{TemplateBinding BorderBrush}" BorderThickness="1"><ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/></Border><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="bg" Property="Background" Value="#1E2610"/></Trigger><Trigger Property="IsKeyboardFocused" Value="True"><Setter TargetName="bg" Property="BorderThickness" Value="2"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Setter.Value></Setter></Style><Style TargetType="ScrollBar"><Setter Property="Width" Value="12"/><Setter Property="Background" Value="#0F0F0F"/><Setter Property="Template"><Setter.Value><ControlTemplate TargetType="ScrollBar"><Track x:Name="PART_Track" Orientation="Vertical" IsDirectionReversed="True" Minimum="{TemplateBinding Minimum}" Maximum="{TemplateBinding Maximum}" Value="{TemplateBinding Value}" ViewportSize="{TemplateBinding ViewportSize}"><Track.DecreaseRepeatButton><RepeatButton Command="ScrollBar.PageUpCommand" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.DecreaseRepeatButton><Track.Thumb><Thumb><Thumb.Template><ControlTemplate TargetType="Thumb"><Border x:Name="ThumbSurface" Background="#2A2A2A" Margin="2,0"/><ControlTemplate.Triggers><Trigger Property="IsMouseOver" Value="True"><Setter TargetName="ThumbSurface" Property="Background" Value="#454545"/></Trigger></ControlTemplate.Triggers></ControlTemplate></Thumb.Template></Thumb></Track.Thumb><Track.IncreaseRepeatButton><RepeatButton Command="ScrollBar.PageDownCommand" Focusable="False"><RepeatButton.Template><ControlTemplate TargetType="RepeatButton"><Border Background="Transparent"/></ControlTemplate></RepeatButton.Template></RepeatButton></Track.IncreaseRepeatButton></Track></ControlTemplate></Setter.Value></Setter></Style></Window.Resources>
<Grid x:Name="Root" Background="#0F0F0F">
<Border Width="430" Height="128" VerticalAlignment="Top" Margin="0,22,0,0" BorderBrush="#C6F432" BorderThickness="1"><Grid><Rectangle Margin="2" Stroke="#C6F432" StrokeThickness="0.5" StrokeDashArray="1,2"/><StackPanel HorizontalAlignment="Center" VerticalAlignment="Center"><TextBlock Foreground="#C6F432" FontSize="12" LineHeight="12" LineStackingStrategy="BlockLineHeight" xml:space="preserve">██╗     ██╗   ██╗███╗   ███╗ █████╗
██║     ██║   ██║████╗ ████║██╔══██╗
██║     ██║   ██║██╔████╔██║███████║
██║     ██║   ██║██║╚██╔╝██║██╔══██║
███████╗╚██████╔╝██║ ╚═╝ ██║██║  ██║
╚══════╝ ╚═════╝ ╚═╝     ╚═╝╚═╝  ╚═╝</TextBlock><TextBlock x:Name="BrandCaption" Text="U P D A T E R" Foreground="#C6F432" Margin="0,13,0,0"/></StackPanel></Grid></Border>
<Ellipse x:Name="Dot" Width="9" Height="9" Fill="#C6F432" HorizontalAlignment="Left" VerticalAlignment="Top" Margin="28,182,0,0"/>
<TextBlock x:Name="Status" Text="ПРОВЕРКА ОБНОВЛЕНИЯ" FontSize="14" FontWeight="Bold" Margin="55,177,20,0" VerticalAlignment="Top"/>
<TextBlock x:Name="Detail" Text="└─ Подключаемся к серверу обновлений" Foreground="#8A8A8A" Margin="62,203,20,0" VerticalAlignment="Top"/>
<Grid ClipToBounds="True" x:Name="Track" Margin="62,226,62,0" Height="5" VerticalAlignment="Top" Background="#2A2A2A"><Border x:Name="Fill" Width="0" Background="#C6F432" HorizontalAlignment="Left"/></Grid>
<Button x:Name="Action" Content="ОТМЕНА" Width="184" Height="42" VerticalAlignment="Top" Margin="0,241,0,0"/>
<Border BorderBrush="#2A2A2A" BorderThickness="1" Margin="16,296,16,37"><Grid Margin="9,8"><Grid.RowDefinitions><RowDefinition Height="22"/><RowDefinition Height="*"/></Grid.RowDefinitions><TextBlock Text="ЖУРНАЛ  /  В РЕАЛЬНОМ ВРЕМЕНИ" Foreground="#8A8A8A" FontSize="11"/><ScrollViewer x:Name="Scroll" Grid.Row="1" VerticalScrollBarVisibility="Auto"><TextBlock x:Name="Log" FontSize="11" TextWrapping="Wrap" LineHeight="18"/></ScrollViewer></Grid></Border>
<Grid VerticalAlignment="Bottom" Margin="28,0,28,10"><Grid.ColumnDefinitions><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/><ColumnDefinition Width="*"/></Grid.ColumnDefinitions><TextBlock x:Name="OpenFolder" Cursor="Hand" Text="Папка [Ctrl+O]" Foreground="#8A8A8A" FontSize="11"/><TextBlock Grid.Column="1" Text="Обновление LumaDrop" Foreground="#8A8A8A" FontSize="11" HorizontalAlignment="Center"/><TextBlock Grid.Column="2" Text="Выход [Ctrl+Q]" Foreground="#8A8A8A" FontSize="11" HorizontalAlignment="Right"/></Grid>
</Grid></Window>
'@
$window = [Windows.Markup.XamlReader]::Load([Xml.XmlNodeReader]::new($xaml))
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
    $stamp.Foreground='#8A8A8A'; $ui.Log.Inlines.Add($stamp)
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
        $script:cts.Cancel(); $ui.Action.Content='ОТМЕНА...'; $ui.Action.IsEnabled=$false
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
                $queue.Enqueue(@{Kind='Error'; Stage='НЕ УДАЛОСЬ ОБНОВИТЬ'; Detail='Подробности в журнале ниже'; Text=$message})
            }
        } finally { $shared.Finished=$true }
    }.ToString()).AddArgument($script:queue).AddArgument($script:shared).AddArgument($script:cts.Token).AddArgument($script:directory).AddArgument($LumaCoreSource)
    $script:running=$true
    $ui.Dot.Fill='#C6F432'; $ui.Dot.BeginAnimation([Windows.UIElement]::OpacityProperty,$pulse)
    $ui.Action.Content='ОТМЕНА'; $ui.Action.IsEnabled=$true
    $ui.Status.Text='ПРОВЕРКА ОБНОВЛЕНИЯ'; $ui.Detail.Text='└─ Подключаемся к серверу обновлений'
    Set-UiProgress 0 $true
    $script:async=$script:worker.BeginInvoke()
    $timer.Start()
}
$timer.Add_Tick({
    $event=$null; $latest=$null
    while ($script:queue.TryDequeue([ref]$event)) {
        if ($event.ContainsKey('Target')) { $script:target=$event.Target }
        if ($event.ContainsKey('Version')) { $ui.BrandCaption.Text='U P D A T E R  ·  v'+$event.Version }
        if ($event.Kind -eq 'Log') { Add-UiLog $event.Text }
        elseif ($event.Kind -eq 'Status') { $latest=$event }
        else { $script:terminal=$event }
    }
    if ($latest -and -not $script:terminal) {
        $ui.Status.Text=$latest.Stage; $ui.Detail.Text='└─ '+$latest.Detail
        Set-UiProgress $latest.Progress ([bool]$latest.Indeterminate)
    }
    if ($script:async -and $script:async.IsCompleted) {
        try { [void]$script:worker.EndInvoke($script:async) }
        catch { if (-not $script:terminal) { $script:terminal=@{Kind='Error'; Stage='НЕ УДАЛОСЬ ОБНОВИТЬ'; Detail='Повтори запуск обновлятора'; Text=$_.Exception.Message} } }
        # Drain terminal events once more after EndInvoke to avoid a completion race.
        while ($script:queue.TryDequeue([ref]$event)) {
            if ($event.ContainsKey('Target')) { $script:target=$event.Target }
            if ($event.ContainsKey('Version')) { $ui.BrandCaption.Text='U P D A T E R  ·  v'+$event.Version }
            if ($event.Kind -eq 'Log') { Add-UiLog $event.Text }
            elseif ($event.Kind -ne 'Status') { $script:terminal=$event }
        }
        $script:worker.Dispose(); $script:cts.Dispose(); $script:async=$null
        $script:running=$false; $timer.Stop()
        $ui.Dot.BeginAnimation([Windows.UIElement]::OpacityProperty,$null); $ui.Dot.Opacity=1
        $ui.Action.IsEnabled=$true
        if (-not $script:terminal) { $script:terminal=@{Kind='Error'; Stage='НЕ УДАЛОСЬ ОБНОВИТЬ'; Detail='Повтори запуск обновлятора'; Text='Операция завершилась без подтверждения установки.'} }
        $result=$script:terminal
        $ui.Status.Text=$result.Stage; $ui.Detail.Text='└─ '+$result.Detail
        if ($result.Kind -eq 'Done') {
            $ui.Action.Content='ЗАКРЫТЬ'; Set-UiProgress 100 $false
            if (-not $result.Launched) { $ui.Detail.Text='└─ Открой LumaDropPatcher.exe вручную' }
        } else {
            Add-UiLog $result.Text
            $ui.Dot.Fill=if ($result.Kind -eq 'Error') { '#EF5350' } else { '#8A8A8A' }
            $ui.Action.Content='ПОВТОРИТЬ'; Set-UiProgress $script:lastProgress $false
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
