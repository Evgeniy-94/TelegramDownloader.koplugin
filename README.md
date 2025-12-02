# TelegramDownloader plugin for KOReader

This plugin for [KOReader](https://github.com/koreader/koreader) allows you to send files to your e-reader using Telegram bot. 

## Installation

1) Download the plugin, unzip it in the `koreader/plugins` directory. This is the only step needed if you are updating plugin.
2) Obtain a Telegram bot API token by contacting [@BotFather](https://t.me/botfather) bot, sending the `/newbot` command and following the steps until you're given a new token. You can find a step-by-step guide [here](https://core.telegram.org/bots/features#creating-a-new-bot).
3) Get your Telegram user_ID with [@userinfobot](https://t.me/UserInfoToBot) telegram bot.
4) Set your token and user_ID in the "Telegram Bot configuration" menu. Alternativly you can set them in the file `telegramdownloader.lua` in KOReader settings directory. This file is created automatically when plugin initialized. Insert following text with your API Token and user_id surrounded by quotes as shown it the example:
   
  ```lua
  return {
      ["token"] = "Insert your token here",
      ["user_id"] = "12345",
  }
  ```

## Usage

1) You will find "TelegramDownloader" submenu item in the "tools" menu tab.
2) Choose download folder.
3) Send one or multiple files to your telegram bot. Telegram allows files up to 20MB.
4) Press "Download files" button in "TelegramDownloader" submenu.
5) Wait for your files to be downloaded.


## Установка

1) Скачайте архив в плагином и разархивируйте его в папку `koreader/plugins`. При обновлении плагина все остальные шаги не требуются.
2) Для получения токена отправьте боту [@BotFather](https://t.me/botfather) сообщение `/newbot` и следуйте дальнейшим инструкциям. [Подробная иструкция.](https://core.telegram.org/bots/features#creating-a-new-bot)
3) Узнайте свой Telegram user_id с помощью бота [@userinfobot](https://t.me/UserInfoToBot).
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

##
![screen1](https://github.com/user-attachments/assets/f03c7c82-3e69-4fcc-9ae8-210ccb7ae57b)
![screen2](https://github.com/user-attachments/assets/461d84f6-b8bd-482f-bd82-acabfb48e1ed)
