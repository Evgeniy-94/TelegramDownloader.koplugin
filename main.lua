local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local json = require("json")
local _ = require("gettext")
local T = require("ffi/util").template

local TOKEN = "INSERT_YOUR_API_TOKEN_HERE"
local MY_TELEGRAM_USER_ID = YOUR_TELEGRAM_USER_ID_AS_WITHOUT_QUOTES

local TelegramDownloader = WidgetContainer:extend{
    name = "TelegramDownloader",
    is_doc_only = false,
}

function TelegramDownloader:init()
    self.tg_offset = G_reader_settings:readSetting("tg_offset") or "0"
    self.tg_dir = G_reader_settings:readSetting("tg_dir") or DataStorage:getFullDataDir()
    self.ui.menu:registerToMainMenu(self)
end

function TelegramDownloader:getUpdates()
    local url = string.format("https://api.telegram.org/bot%s/getUpdates?offset=%d", TOKEN, self.tg_offset or 0)
    local response = http.request(url)
    return json.decode(response)
end

function TelegramDownloader:downloadFile(fileId)
    local url = string.format("https://api.telegram.org/bot%s/getFile?file_id=%s", TOKEN, fileId)
    local response = http.request(url)
    local filePath = json.decode(response).result.file_path
    local fileUrl = string.format("https://api.telegram.org/file/bot%s/%s", TOKEN, filePath)
    local fileResponse = http.request(fileUrl)
    return fileResponse
end

function TelegramDownloader:processUpdates(updates)
    for nouse, update in ipairs(updates.result) do
 		if update.message and update.message.document and update.message.from.id == MY_TELEGRAM_USER_ID then

            local fileId = update.message.document.file_id
            local fileName = update.message.document.file_name
            local fileData = self:downloadFile(fileId)
            local filePath = self.tg_dir .. "/" .. fileName
            local file = io.open(filePath, "wb")
            file:write(fileData)
            file:close()
            UIManager:show(ConfirmBox:new{
                text = T(_("File saved to:\n%1\nWould you like to read the downloaded book now?"), filePath),
                ok_text = _("Read now"),
                ok_callback = function()
                    if self.ui.document then
                        self.ui:switchDocument(filePath)
                    else
                        self.ui:openFile(filePath)
                    end
                end,
            })
        else
            UIManager:show(InfoMessage:new{
            text = _("There is no new files") ,
            })
        end
    end
end

function TelegramDownloader:checkForNewFiles()
    local updates = self:getUpdates()
    if updates and updates.result then
        if #updates.result > 0 then
            UIManager:show(InfoMessage:new{
            text = _("Downloading. This might take a moment."),
            timeout = 1,
            })
            UIManager:forceRePaint ()
            self:processUpdates(updates)
            self.tg_offset = updates.result[#updates.result].update_id + 1
            G_reader_settings:saveSetting("tg_offset", self.tg_offset)
        else
            UIManager:show(InfoMessage:new{
            text = _("There is no new files"),
            })
        end
    else
        UIManager:show(InfoMessage:new{
        text = _("Connection failed"),
        })
    end
end

function TelegramDownloader:addToMainMenu(menu_items)
    menu_items.telegram_downloader = {
        text = _("TelegramDownloader"),
        keep_menu_open = true,
        sorting_hint = "tools", 
        sub_item_table = {
          {
              text_func = function()
                  return string.format("Choose folder (%s)", self.tg_dir)
              end,
              keep_menu_open = true,
              callback = function(touchmenu_instance)
                  require("ui/downloadmgr"):new{
                      onConfirm = function(path)
                          self.tg_dir = path
                          G_reader_settings:saveSetting("tg_dir", path)
                          touchmenu_instance:updateItems()
                      end,
                  }:chooseDir()
              end,
          },
          {
              text = _("Download files"),
              callback = function()
                  local connect_callback = function()
                  self:checkForNewFiles()
                  end
                  NetworkMgr:runWhenConnected(connect_callback)
              end
          },
		   }
    }
end

return TelegramDownloader
