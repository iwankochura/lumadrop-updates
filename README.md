# LumaDrop — обновления

[Телеграм Канал](https://t.me/lumadrop)

## Как обновить

1. Скачайте [update.bat](https://iwankochura.github.io/lumadrop-updates/update.bat).
2. Положите файл на рабочий стол рядом с папкой **LumaDropV3** и запустите.
3. В открывшемся окне **LumaDrop Patcher** нажмите **ЗАПУСТИТЬ**.
4. В Chrome откройте `chrome://extensions`, нажмите **Обновить** у LumaDrop, затем обновите TikTok Studio.

Python и FFmpeg устанавливать не нужно.

## Файлы этого репозитория

- `version.json` — версия и ссылки для расширения.
- `update.bat` — скачивание и установка опубликованного ZIP.
- `README.md` — инструкция.
- `.gitignore` — исключения Git.

Исходники патчера и расширения здесь не публикуются.

## Порядок выпуска

1. Собрать EXE и обфусцированное расширение, пройти тесты.
2. Упаковать одну папку `LumaDropV3` с `extension/`, `LumaDropPatcher.exe`, `README.txt`, `version.txt`.
3. В [lumadrop-bin](https://github.com/iwankochura/lumadrop-bin/releases) создать Release `vX.Y.Z`, прикрепить одинаковые архивы `LumaDropV3.zip` и `LumaDropV3-vX.Y.Z.zip`, а также `SHA256SUMS.txt`.
4. Проверить публичное скачивание и SHA-256.
5. Обновить `current_version`, `download_zip_url`, `changelog` в `version.json`. При смене структуры обновить `update.bat`.
6. Отправить файлы в `main`. GitHub Pages: `main` / корень.
7. Проверить публичный `version.json` и полный цикл обновления.

`update.bat` проверяет структуру архива перед заменой папки, сохраняет старую папку для восстановления и запускает новый EXE. Расширение обновляется вручную в Chrome.
