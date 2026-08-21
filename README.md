# TelegramDownloader plugin for KOReader

This plugin for [KOReader](https://github.com/koreader/koreader) allows you to send files to your e-reader using Telegram bot. 

## Installation

1) Download the plugin, unzip it in the `koreader/plugins` directory. This is the only step needed if you are updating plugin.
2) Obtain a Telegram bot API token by contacting [@BotFather](https://t.me/botfather) bot, sending the `/newbot` command and following the steps until you're given a new token. You can find a step-by-step guide [here](https://core.telegram.org/bots/features#creating-a-new-bot).
3) Get the Telegram user IDs you want to authorize with [@userinfobot](https://t.me/UserInfoToBot) telegram bot.
4) Set your token and comma-separated user IDs in the "Telegram Bot configuration" menu. Alternatively, you can set them in the file `telegramdownloader.lua` in the KOReader settings directory. This file is created automatically when the plugin is initialized. Insert the following text with your API token and authorized user IDs:
   
  ```lua
  return {
      ["token"] = "Insert your token here",
      ["user_ids"] = { 12345678, 87654321 },
  }
  ```

  Existing configurations containing a single `user_id` continue to work.

## Usage

1) You will find "TelegramDownloader" submenu item in the "tools" menu tab.
2) Choose download folder.
3) Send one or multiple files to your Telegram bot, either privately or from an authorized user in a private group containing the bot. Telegram allows files up to 20MB.
4) Press "Download files" button in "TelegramDownloader" submenu.
5) Wait for your files to be downloaded.


## Установка

1) Скачайте архив в плагином и разархивируйте его в папку `koreader/plugins`. При обновлении плагина все остальные шаги не требуются.
2) Для получения токена отправьте боту [@BotFather](https://t.me/botfather) сообщение `/newbot` и следуйте дальнейшим инструкциям. [Подробная иструкция.](https://core.telegram.org/bots/features#creating-a-new-bot)
3) Узнайте Telegram user_id всех пользователей, которым нужен доступ, с помощью бота [@userinfobot](https://t.me/UserInfoToBot).
4) Введите токен и разделённые запятыми user_id в меню "Telegram Bot configuration". Также их можно указать в файле `telegramdownloader.lua` в папке koreader/setting. Этот файл создаётся автоматически при инициализации плагина:

  ```lua
  return {
      ["token"] = "Insert your token here",
      ["user_ids"] = { 12345678, 87654321 },
  }
  ```

  Существующие конфигурации с одним параметром `user_id` продолжают работать.

## Использование

1) В верхнем меню во вкладке появится подпункт "TelegramDownloader".
2) Укажите папку, в которую будут скачиваться файлы с помощью пункта "Choose folder".
3) Отправьте файлы своему боту. В телеграме есть ограничение на размер каждого файла в 20МБ.
4) После нажатия кнопки "Download files" файлы будут скачаны в указанную папку.

##
![screen1](https://github.com/user-attachments/assets/f03c7c82-3e69-4fcc-9ae8-210ccb7ae57b)
![screen2](https://github.com/user-attachments/assets/461d84f6-b8bd-482f-bd82-acabfb48e1ed)
