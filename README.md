# TelegramDownloader plugin for KOReader

This plugin for [KOReader](https://github.com/koreader/koreader) allows you to send files to your e-reader using Telegram bot. 

## Installation

1) Obtain a Telegram bot API token by contacting [@BotFather](https://t.me/botfather) bot, sending the `/newbot` command and following the steps until you're given a new token. You can find a step-by-step guide [here](https://core.telegram.org/bots/features#creating-a-new-bot).
2) Download the plugin, unzip it in the `koreader/plugins` directory. The folder needs to be called `TelegramDownloader.koplugin` if the extracted folder ends with `-master` or a similar name. Rename it before copying it to your `koreader/plugins/` folder.
3) Open `main.lua` file and insert your API Token into the next line:
   
    `local TOKEN = "INSERT_YOUR_API_TOKEN_HERE"`
4) In `main.lua` file put your telegram user id on `local MY_TELEGRAM_USER_ID = YOUR_USER_ID_WITHOUT_QUOTES` without quotes, just the numbers. You can get your user ID with the [@userinfobot](https://t.me/UserInfoToBot) on telegram.

## Usage

1) You will find "TelegramDownloader" submenu item in the "tools" menu tab.
2) Chose choose download folder.
3) Send one or multiple files to your telegram bot.
4) Press "Download files" button in "TelegramDownloader" submenu.
5) Wait for your files to be downloaded.


## Установка

1) Для получения токена отправьте боту [@BotFather](https://t.me/botfather) сообщение `/newbot` и следуйте дальнейшим инструкциям. [Подробная иструкция.](https://core.telegram.org/bots/features#creating-a-new-bot)
2) Скачайте архив в плагином и разархивируйте его в папку `koreader/plugins`. 
3) Откройте файл `main.lua` и вставьте свой токен в следующую строку:
   
    `local TOKEN = "INSERT_YOUR_API_TOKEN_HERE"`

## Использование

1) В верхнем меню во вкладке появится подпункт "TelegramDownloader".
2) Укажите папку, в которую будут скачиваться файлы с помощью пункта "Choose folder".
3) Отправьте файлы своему боту.
4) После нажатия кнопки "Download files" файлы будут скачаны в указанную папку.

##
![screen1](https://github.com/user-attachments/assets/f03c7c82-3e69-4fcc-9ae8-210ccb7ae57b)
![screen2](https://github.com/user-attachments/assets/461d84f6-b8bd-482f-bd82-acabfb48e1ed)
