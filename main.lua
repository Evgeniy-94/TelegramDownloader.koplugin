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
    self.token = self.settings:readSetting("token", "")
    self.user_id = self.settings:readSetting("user_id", "0")
    self.settings:close()
end

function TelegramDownloader:getUpdates()
    local url = string.format("https://api.telegram.org/bot%s/getUpdates?offset=%d", self.token, self.offset)
    local response = http.request(url)
    if not response then
        UIManager:show(InfoMessage:new{
            text = _("Failed to connect to Telegram API"),
        })
        return nil
    end

    local result = json.decode(response)
    if not result then
        UIManager:show(InfoMessage:new{
            text = _("Invalid response from Telegram API (not JSON)"),
        })
        return nil
    end

    if not result.ok then
        local desc = result.description or _("Unknown error")
        UIManager:show(InfoMessage:new{
            text = _("Telegram API error: %s"):format(desc),
        })
        return nil
    end

    return result
end

function TelegramDownloader:downloadFile(fileId)
    local url = string.format("https://api.telegram.org/bot%s/getFile?file_id=%s", self.token, fileId)
    local response = http.request(url)
    if not response then
        UIManager:show(InfoMessage:new{
            text = _("Failed to get file info from Telegram"),
        })
        return nil
    end
    
    local result = json.decode(response)
    if not result then
        UIManager:show(InfoMessage:new{
            text = _("Invalid response when fetching file info"),
        })
        return nil
    end

    if not result.ok then
        local desc = result.description or _("Unknown error")
        UIManager:show(InfoMessage:new{
            text = _("Telegram file request failed: %s"):format(desc),
        })
        return nil
    end

    if not result.result or not result.result.file_path then
        UIManager:show(InfoMessage:new{
            text = _("File path not found in Telegram response"),
        })
        return nil
    end
    
    local filePath = result.result.file_path
    local fileUrl = string.format("https://api.telegram.org/file/bot%s/%s", self.token, filePath)
    local fileResponse = http.request(fileUrl)
    if not fileResponse then
        UIManager:show(InfoMessage:new{
            text = _("Failed to download file from Telegram"),
        })
        return nil
    end

    return fileResponse
end

function TelegramDownloader:processUpdates(updates)
    local foundFiles = false
    
    for nouse, update in ipairs(updates.result) do
        if update.message and update.message.document and update.message.from.id == tonumber(self.user_id) then
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

            UIManager:scheduleIn(0.5, function()
                local FileManager = require("apps/filemanager/filemanager")
                if FileManager.instance then
                    FileManager.instance:onRefresh()
                    UIManager:setDirty(FileManager.instance, "ui")
                end
            end)

            self.offset = updates.result[#updates.result].update_id + 1
            self.settings:saveSetting("offset", self.offset)
            self.settings:close()
        else
            UIManager:show(InfoMessage:new{
                text = _("There are no new files"),
            })
        end
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
                text = _("Telegram Bot configuration"),
                keep_menu_open = true,
                callback = function()
                    self:loadSettings()
                    local configuration_window
                    configuration_window = require("ui/widget/multiinputdialog"):new{
                        title = _("Telegram Bot configuration"),
                        fields = {
                            {
                                description = _("Bot token"),
                                text = self.token,
                                hint = _("123456:ABC-DEF1234ghIkl-zyx57W2v1u123ew11"),
                            },
                            {
                                description = _("Your user ID"),
                                text = self.user_id,
                                hint = _("12345678"),
                            },
                        },
                        buttons = {
                            {
                                {
                                    text = _("Cancel"),
                                    id = "close",
                                    callback = function()
                                        UIManager:close(configuration_window)
                                    end
                                },
                                {
                                    text = _("Info"),
                                    callback = function()
                                        UIManager:show(InfoMessage:new{
                                            text = T(_("You can also change this settings in the file: %1"), self.settings_file),
                                        })
                                    end
                                },
                                {
                                    text = _("Save"),
                                    callback = function()
                                        local fields = configuration_window:getFields()

                                        if fields[1] ~= "" and tonumber(fields[2]) and tonumber(fields[2]) > 0 then
                                            self.settings:saveSetting("token", fields[1])
                                            self.settings:saveSetting("user_id", fields[2])
                                            self.settings:close()

                                            UIManager:show(InfoMessage:new{
                                                text = _("Settings saved successfully"),
                                            })
                                            UIManager:close(configuration_window)
                                        else
                                            UIManager:show(InfoMessage:new{
                                                text = T(_("Error. Invalid value.")),
                                            })
                                        end
                                    end
                                },
                            },
                        },
                    }
                    UIManager:show(configuration_window)
                    configuration_window:onShowKeyboard()
                end
            },
            {
                text = _("Download files"),
                callback = function()
                    self:loadSettings()
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
