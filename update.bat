@echo off
setlocal DisableDelayedExpansion
chcp 65001 >nul
title LumaDrop V3 - Update
echo ============================================================
echo                 LumaDrop V3 - Обновление
echo ============================================================
echo.

set "ZIP_URL=https://github.com/iwankochura/lumadrop-bin/releases/latest/download/LumaDropV3.zip"
set "WORK=%TEMP%\LumaDrop_update_%RANDOM%_%RANDOM%"
set "ZIP_FILE=%WORK%\LumaDropV3.zip"
set "EXTRACT_ROOT=%WORK%\extract"
set "TARGET="

if exist "%~dp0LumaDropV3\extension\manifest.json" set "TARGET=%~dp0LumaDropV3"
if not defined TARGET if exist "%USERPROFILE%\Desktop\LumaDropV3\extension\manifest.json" set "TARGET=%USERPROFILE%\Desktop\LumaDropV3"
if not defined TARGET if exist "%USERPROFILE%\Downloads\LumaDropV3\extension\manifest.json" set "TARGET=%USERPROFILE%\Downloads\LumaDropV3"
if not defined TARGET if exist "%USERPROFILE%\Documents\LumaDropV3\extension\manifest.json" set "TARGET=%USERPROFILE%\Documents\LumaDropV3"
if not defined TARGET if exist "%LOCALAPPDATA%\LumaDropV3\extension\manifest.json" set "TARGET=%LOCALAPPDATA%\LumaDropV3"

if not defined TARGET (
  echo [ОШИБКА] Не найдена папка LumaDropV3.
  echo Положите update.bat рядом с папкой LumaDropV3 и запустите снова.
  goto failed
)
if not exist "%TARGET%\stop_server.bat" (
  echo [ОШИБКА] В найденной папке нет stop_server.bat:
  echo "%TARGET%"
  goto failed
)

echo Папка программы: "%TARGET%"
echo Скачиваю обновление...
mkdir "%WORK%" >nul 2>&1
if errorlevel 1 (
  echo [ОШИБКА] Не удалось создать временную папку.
  goto failed
)

set "LUMA_ZIP=%ZIP_FILE%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12; Invoke-WebRequest -UseBasicParsing -Uri '%ZIP_URL%' -OutFile $env:LUMA_ZIP"
if errorlevel 1 (
  echo [ОШИБКА] Не удалось скачать ZIP. Старая версия сохранена.
  goto failed
)
if not exist "%ZIP_FILE%" (
  echo [ОШИБКА] ZIP-файл не появился после скачивания. Старая версия сохранена.
  goto failed
)

echo Проверяю архив и его состав...
set "LUMA_EXTRACT_ROOT=%EXTRACT_ROOT%"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Add-Type -AssemblyName System.IO.Compression.FileSystem; $archive=[IO.Compression.ZipFile]::OpenRead($env:LUMA_ZIP); try { $names=@($archive.Entries | ForEach-Object { $_.FullName }); $required=@('LumaDropV3/extension/manifest.json','LumaDropV3/server/LumaDropPatcher.exe','LumaDropV3/server/run_server.bat','LumaDropV3/server/stop_server.bat','LumaDropV3/run_server.bat','LumaDropV3/stop_server.bat'); foreach($name in $required){if($names -notcontains $name){throw ('Missing archive file: '+$name)}}; $root=[IO.Path]::GetFullPath($env:LUMA_EXTRACT_ROOT).TrimEnd([IO.Path]::DirectorySeparatorChar); foreach($entry in $archive.Entries){if(-not $entry.FullName.StartsWith('LumaDropV3/')){throw 'Unexpected item outside LumaDropV3 folder'}; $full=[IO.Path]::GetFullPath((Join-Path $root $entry.FullName)); if(-not $full.StartsWith($root+[IO.Path]::DirectorySeparatorChar,[StringComparison]::OrdinalIgnoreCase)){throw 'Unsafe path in ZIP'}}; $manifestEntry=$archive.GetEntry('LumaDropV3/extension/manifest.json'); $reader=[IO.StreamReader]::new($manifestEntry.Open()); try{$manifest=$reader.ReadToEnd()|ConvertFrom-Json}finally{$reader.Dispose()}; $parsedVersion=[version]::MinValue; if(-not [version]::TryParse([string]$manifest.version,[ref]$parsedVersion) -or $parsedVersion.Build -lt 0){throw 'Invalid extension version'}; Write-Output ('Archive version: '+$manifest.version) } finally {$archive.Dispose()}"
if errorlevel 1 (
  echo [ОШИБКА] Архив повреждён или в нём неверная структура. Старая версия сохранена.
  goto failed
)

set "NEW_ROOT=%TARGET%.lumadrop-staging"
set "BACKUP_ROOT=%TARGET%.lumadrop-previous-%RANDOM%"
if exist "%NEW_ROOT%" (
  echo [ОШИБКА] Уже существует временная папка обновления:
  echo "%NEW_ROOT%"
  goto failed
)
if exist "%BACKUP_ROOT%" (
  echo [ОШИБКА] Уже существует временная папка восстановления:
  echo "%BACKUP_ROOT%"
  goto failed
)
mkdir "%NEW_ROOT%" >nul 2>&1
if errorlevel 1 (
  echo [ОШИБКА] Не удалось подготовить новую версию. Старая версия сохранена.
  goto failed
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$ErrorActionPreference='Stop'; Expand-Archive -LiteralPath $env:LUMA_ZIP -DestinationPath '%NEW_ROOT%' -Force"
if errorlevel 1 goto invalid_extraction
if not exist "%NEW_ROOT%\LumaDropV3\run_server.bat" goto invalid_extraction
if not exist "%NEW_ROOT%\LumaDropV3\extension\manifest.json" goto invalid_extraction
if not exist "%NEW_ROOT%\LumaDropV3\server\LumaDropPatcher.exe" goto invalid_extraction

echo Останавливаю старый патчер...
set "LUMADROP_AUTOMATED=1"
call "%TARGET%\stop_server.bat"
if errorlevel 1 (
  echo [ОШИБКА] Не удалось остановить старый патчер. Старая версия сохранена.
  goto failed
)
powershell.exe -NoProfile -Command "$end=(Get-Date).AddSeconds(10); do { $listener=Get-NetTCPConnection -LocalPort 54789 -State Listen -ErrorAction SilentlyContinue; if(-not $listener){exit 0}; Start-Sleep -Milliseconds 250 } while((Get-Date)-lt $end); exit 1" >nul 2>&1
if errorlevel 1 (
  echo [ОШИБКА] Порт 54789 всё ещё занят. Старая версия сохранена.
  goto failed
)

echo Устанавливаю проверенную версию...
move "%TARGET%" "%BACKUP_ROOT%" >nul
if errorlevel 1 (
  echo [ОШИБКА] Не удалось подготовить замену. Старая версия сохранена.
  goto failed
)
move "%NEW_ROOT%\LumaDropV3" "%TARGET%" >nul
if errorlevel 1 (
  move "%BACKUP_ROOT%" "%TARGET%" >nul
  echo [ОШИБКА] Установка не удалась. Старая версия восстановлена.
  goto failed
)

rd /s /q "%BACKUP_ROOT%" >nul 2>&1
rd /s /q "%NEW_ROOT%" >nul 2>&1
rd /s /q "%WORK%" >nul 2>&1
echo.
echo Запускаю новый патчер...
call "%TARGET%\run_server.bat"
if errorlevel 1 echo [ПРЕДУПРЕЖДЕНИЕ] Папка обновлена, но сервер не запустился. Проверьте журнал в локальном профиле Windows.
echo.
echo [ГОТОВО] Обновление установлено.
echo Откройте chrome://extensions и нажмите «Обновить» у LumaDrop.
echo.
if not defined LUMADROP_AUTOMATED pause
exit /b 0

:invalid_extraction
rd /s /q "%NEW_ROOT%" >nul 2>&1
echo [ОШИБКА] ZIP распакован не полностью. Старая версия сохранена.
goto failed

:failed
if defined WORK rd /s /q "%WORK%" >nul 2>&1
echo.
if not defined LUMADROP_AUTOMATED pause
exit /b 1
