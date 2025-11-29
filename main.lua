local WidgetContainer = require("ui/widget/container/widgetcontainer")
local DataStorage = require("datastorage")
local InfoMessage = require("ui/widget/infomessage")
local ConfirmBox = require("ui/widget/confirmbox")
local NetworkMgr = require("ui/network/manager")
local LuaSettings = require("luasettings")
local UIManager = require("ui/uimanager")
local http = require("socket.http")
local json = require("json")
local _ = require("gettext")
local T = require("ffi/util").template

local TelegramDownloader = WidgetContainer:extend{
    name = "TelegramDownloader",
    settings_file = DataStorage:getSettingsDir() .. "/telegramdownloader.lua",
    is_doc_only = false,
}

function TelegramDownloader:init()
    self:loadSettings()
    self.ui.menu:registerToMainMenu(self)
end

function TelegramDownloader:loadSettings()
    self.settings = LuaSettings:open(self.settings_file)
    self.directory = self.settings:readSetting("directory", DataStorage:getFullDataDir())
    self.offset = self.settings:readSetting("offset", 0)
    self.token = self.settings:readSetting("token", "Insert your token here")
    self.user_id = self.settings:readSetting("user_id", 12345)
    self.settings:close()
end

function TelegramDownloader:getUpdates()
    local url = string.format("https://api.telegram.org/bot%s/getUpdates?offset=%d", self.token, self.offset)
    local response = http.request(url)
    if not response then
        return nil
    end
    return json.decode(response)
end

function TelegramDownloader:downloadFile(fileId)
    local url = string.format("https://api.telegram.org/bot%s/getFile?file_id=%s", self.token, fileId)
    local response = http.request(url)
    if not response then
        return nil
    end
    
    local result = json.decode(response)
    if not result.result or not result.result.file_path then
        return nil
    end
    
    local filePath = result.result.file_path
    local fileUrl = string.format("https://api.telegram.org/file/bot%s/%s", self.token, filePath)
    local fileResponse = http.request(fileUrl)
    return fileResponse
end

function TelegramDownloader:processUpdates(updates)
    local foundFiles = false
    
    for nouse, update in ipairs(updates.result) do
        if update.message and update.message.document and update.message.from.id == self.user_id then
            foundFiles = true
            local fileId = update.message.document.file_id
            local fileName = update.message.document.file_name
            local fileData = self:downloadFile(fileId)
            
            if fileData then
                local filePath = self.directory .. "/" .. fileName
                local file = io.open(filePath, "wb")
                if file then
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
                    }, "full")
                end
            end
        end
    end
    
    if not foundFiles then
        UIManager:show(InfoMessage:new{
            text = _("There are no new files"),
        })
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
            UIManager:forceRePaint()
            self:processUpdates(updates)
            self.offset = updates.result[#updates.result].update_id + 1
            self.settings:saveSetting("offset", self.offset)
            self.settings:close()
        else
            UIManager:show(InfoMessage:new{
                text = _("There are no new files"),
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
                    return string.format("Choose folder (%s)", self.directory)
                end,
                keep_menu_open = true,
                callback = function(touchmenu_instance)
                    require("ui/downloadmgr"):new{
                        onConfirm = function(path)
                            self.directory = path
                            self.settings:saveSetting("directory", path)
                            self.settings:close()
                            touchmenu_instance:updateItems()
                        end,
                    }:chooseDir()
                end,
            },
            {
                text = _("Download files"),
                callback = function()
                    self:loadSettings()
                    if self.token == "Insert your token here" or self.user_id == 12345 then
                        UIManager:show(InfoMessage:new{
                            text = T(_("Please set the token and user_id in settings file\n%1"), self.settings_file),
                        })
                    else
                    local connect_callback = function()
                        self:checkForNewFiles()
                    end
                    NetworkMgr:runWhenConnected(connect_callback)
                    end
                end
            },
        }
    }
end

return TelegramDownloader
