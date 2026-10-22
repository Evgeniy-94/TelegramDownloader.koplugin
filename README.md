# TelegramDownloader plugin for KOReader

This plugin for [KOReader](https://github.com/koreader/koreader) allows you to send files to your e-reader using Telegram bot. 

## Installation

1) Download the plugin, unzip it in the `koreader/plugins` directory. This is the only step needed if you are updating plugin.
2) Obtain a Telegram bot API token by contacting [@BotFather](https://t.me/botfather) bot, sending the `/newbot` command and following the steps until you're given a new token. You can find a step-by-step guide [here](https://core.telegram.org/bots/features#creating-a-new-bot).
3) Get your Telegram user_ID with [@userinfobot](https://t.me/UserInfoToBot) telegram bot. Files must be sent in your private chat with the bot, from the account whose ID you configure: files from other accounts or from groups are ignored, and the plugin tells you so.
4) Set your token and user_ID in the "Telegram Bot configuration" menu. Alternativly you can set them in the file `telegramdownloader.lua` in KOReader settings directory. This file is created automatically when plugin initialized. Insert following text with your API Token and user_id surrounded by quotes as shown it the example:
   
  ```lua
  return {
      ["token"] = "Insert your token here",
      ["user_id"] = "12345",
  }
  ```

## Usage

1) You will find "TelegramDownloader" submenu item in the "tools" menu tab.
2) Choose download folder (defaults to your KOReader home folder).
3) Send one or multiple files to your telegram bot. Telegram allows files up to 20MB.
4) Press "Download files" button in "TelegramDownloader" submenu.
5) Wait for your files to be downloaded.


## Security notes

- Only files you send from your own account, in your private chat with the bot, are downloaded. Messages from anyone else are ignored.
- Only file types KOReader can open are saved (EPUB, PDF, FB2, ...). Scripts and other executable files (e.g. `.lua`, `.so`, `.sh`) are always rejected.
- File names are sanitized, and the plugin never overwrites existing files: a duplicate is saved as `name (1).ext`. (This assumes no other app changes the download folder at the same moment.)
- The connection to Telegram is encrypted, and the server's certificate and hostname are checked using the CA bundle that ships with KOReader (`data/ca-bundle.crt`). If your build has no CA bundle, add the path to one in the settings file: `["ca_file"] = "/path/to/ca-bundle.crt"`.
- The bot token is stored in plain text in `telegramdownloader.lua`. Anyone who can read your device's storage can control the bot, so revoke the token with @BotFather if the device is lost.
- Downloads are written to a temporary file and only moved into place once complete. Syncing to storage is best-effort, for the download progress file too: after a sudden power loss the newest file may still be missing or incomplete, in which case simply send it again.
- Download progress is kept in `telegramdownloader_state.json` in KOReader's settings folder. If that file is damaged, the plugin stops and says so; deleting it starts over, but files still on Telegram's server (kept for up to 24 hours) may then be downloaded again.

## Testing on your device

`tools/device_selftest.lua` (not included in the release zip) checks, with KOReader's own runtime, that safe file creation works and that the connection to Telegram is verified, including rejection of wrong, self-signed, untrusted and expired certificates (using the public test hosts of badssl.com). It does not use your bot token. Copy it to the device and run it from KOReader's directory, e.g. in KOReader's terminal emulator or over SSH:

```sh
cd /mnt/us/koreader
./luajit /mnt/us/device_selftest.lua plugins/TelegramDownloader.koplugin /mnt/us/documents
```

Every line should read `[PASS]` (or `[SKIP]` with an explanation). Run it with Wi-Fi on: if badssl.com or Telegram cannot be reached, the TLS checks report `[FAIL]` (for badssl.com: "re-run when online") rather than `[SKIP]`. The only expected `[SKIP]` is the symlink check on storage that does not support symlinks (e.g. the Kindle's documents folder).

## Установка

1) Скачайте архив в плагином и разархивируйте его в папку `koreader/plugins`. При обновлении плагина все остальные шаги не требуются.
2) Для получения токена отправьте боту [@BotFather](https://t.me/botfather) сообщение `/newbot` и следуйте дальнейшим инструкциям. [Подробная иструкция.](https://core.telegram.org/bots/features#creating-a-new-bot)
3) Узнайте свой Telegram user_id с помощью бота [@userinfobot](https://t.me/UserInfoToBot). Файлы нужно отправлять в личном чате с ботом с того аккаунта, чей ID указан в настройках: файлы с других аккаунтов или из групп игнорируются, и плагин сообщает об этом.
4) Введите свой токен и user_id в меню "Telegram Bot configuration". Чтобы не вводить токен вручную, можно скопировать его в файл `telegramdownloader.lua` в папке koreader/setting. Этот файл создаётся автоматически при инициализации плагина. В файле укажите свой API токен и user_id в кавычках как показано в примере: 

  ```lua
  return {
      ["token"] = "Insert your token here",
      ["user_id"] = "12345",
  }
  ```

## Использование

1) В верхнем меню во вкладке появится подпункт "TelegramDownloader".
2) Укажите папку, в которую будут скачиваться файлы с помощью пункта "Choose folder".
3) Отправьте файлы своему боту. В телеграме есть ограничение на размер каждого файла в 20МБ.
4) После нажатия кнопки "Download files" файлы будут скачаны в указанную папку.

## Безопасность

- Скачиваются только файлы, которые вы отправили со своего аккаунта в личном чате с ботом. Сообщения от других пользователей игнорируются.
- Сохраняются только файлы, которые KOReader умеет открывать (EPUB, PDF, FB2, ...). Скрипты и исполняемые файлы (например `.lua`, `.so`, `.sh`) всегда отклоняются.
- Имена файлов очищаются от опасных символов, плагин не перезаписывает существующие файлы: дубликат сохраняется как `name (1).ext`. (Предполагается, что другие приложения не изменяют папку загрузки в тот же момент.)
- Соединение с Telegram шифруется, сертификат и имя сервера проверяются по набору корневых сертификатов KOReader (`data/ca-bundle.crt`). Если в вашей сборке его нет, укажите путь в файле настроек: `["ca_file"] = "/path/to/ca-bundle.crt"`.
- Токен бота хранится в открытом виде в `telegramdownloader.lua`. Любой, у кого есть доступ к памяти устройства, может управлять ботом, поэтому при утере устройства отзовите токен через @BotFather.
- Файлы сначала скачиваются во временный файл и переносятся на место только после завершения загрузки. Запись на накопитель (в том числе файла с прогрессом загрузки) выполняется по возможности: при внезапном отключении питания последний файл может пропасть или оказаться неполным — тогда просто отправьте его ещё раз.
- Ход загрузки хранится в файле `telegramdownloader_state.json` в папке настроек KOReader. Если этот файл повреждён, плагин останавливается и сообщает об этом; после удаления файла загрузка начинается заново, но файлы, ещё хранящиеся на сервере Telegram (до 24 часов), могут быть скачаны повторно.

## Проверка на устройстве

Скрипт `tools/device_selftest.lua` (не входит в архив релиза) проверяет средствами самого KOReader, что безопасное создание файлов работает и что соединение с Telegram проверяется, включая отклонение неверных, самоподписанных, недоверенных и просроченных сертификатов (с помощью тестовых серверов badssl.com). Токен бота не используется. Скопируйте скрипт на устройство и запустите из папки KOReader, например в терминале KOReader или по SSH:

```sh
cd /mnt/us/koreader
./luajit /mnt/us/device_selftest.lua plugins/TelegramDownloader.koplugin /mnt/us/documents
```

Все строки должны начинаться с `[PASS]` (или `[SKIP]` с пояснением). Запускайте с включённым Wi-Fi: если badssl.com или Telegram недоступны, проверки TLS выдают `[FAIL]` (для badssl.com — «re-run when online»), а не `[SKIP]`. Единственный ожидаемый `[SKIP]` — проверка символических ссылок на носителе, который их не поддерживает (например, папка documents на Kindle).

##
![screen1](https://github.com/user-attachments/assets/f03c7c82-3e69-4fcc-9ae8-210ccb7ae57b)
![screen2](https://github.com/user-attachments/assets/461d84f6-b8bd-482f-bd82-acabfb48e1ed)
