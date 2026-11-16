--[[--
Immich-Galerie: macht den E-Reader zum Bilderrahmen für eine Immich-Freigabe. Nach einer Zeit ohne
Bedienung zeigt er alle N Sekunden ein zufälliges Bild aus der Freigabe im Vollbild.

Einstellungen in koreader/settings/immich-gallery.lua, Bilder in <Datenordner>/immich-gallery/.
]]

local ConfirmBox = require("ui/widget/confirmbox")
local DataStorage = require("datastorage")
local Device = require("device")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings = require("luasettings")
local NetworkMgr = require("ui/network/manager")
local PluginShare = require("pluginshare")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local time = require("ui/time")

local Sync = require("immichgallery/sync")
local _ = require("immichgallery/i18n")
local N_, T = _.ngettext, _.T

local Screen = Device.screen
local PowerD = Device:getPowerDevice()

math.randomseed(os.time())

local NAME = "immich-gallery"

-- Pause nach einer 403, damit Sperren wie fail2ban vor dem Server nie greifen.
local FORBIDDEN_PAUSE = 15 * 60

local DEFAULTS = {
    url = "",
    password = "",
    headers = {},
    auto_sync = true,
    sync_minutes = 30,
    interval_charging_seconds = 60,
    interval_battery_seconds = 300,
    idle_minutes = 5,
    landscape_rotation = 90,
    update_repo = "rolschewsky/immich-gallery.koplugin",
}

-- Gilt über alle Instanzen des Plugins hinweg (Dateimanager und Reader erzeugen je eine).
local shared = {
    last_sync = nil,     -- Zeitpunkt seit Boot des letzten Sync-Versuchs
    forbidden_at = nil,  -- Zeitpunkt seit Boot der letzten 403
    queue = {},          -- noch nicht gezeigte Bilder dieser Runde
}

local function now()
    return UIManager:getElapsedTimeSinceBoot()
end

local function secondsSince(t)
    return t and time.to_number(now() - t) or math.huge
end

-- Gerät wach halten wie das KeepAlive-Plugin, und KOReaders AutoSuspend pausieren.
local function keepAwake(on)
    PluginShare.keepalive = on
    PluginShare.pause_auto_suspend = on
    if Device:isKindle() then
        os.execute("lipc-set-prop com.lab126.powerd preventScreenSaver " .. (on and "1" or "0"))
    end
end

--- Bildschirmgröße im Hochformat, auf die der Sync zuschneidet.
local function portraitSize()
    local w, h = Screen:getWidth(), Screen:getHeight()
    return math.min(w, h), math.max(w, h)
end

-- Vollbild mit einem Bild ------------------------------------------------------------------------

local Frame = InputContainer:extend{
    name = "immich_gallery_frame",
    covers_fullscreen = true,
    modal = true,
    file = nil,
    on_close = nil,
}

function Frame:init()
    if Screen:getRotationMode() % 2 == 1 then -- Querformat
        self.orig_rotation = Screen:getRotationMode()
        Screen:setRotationMode(Screen.DEVICE_ROTATED_UPRIGHT)
    end
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }
    if Device:isTouchDevice() then
        self.ges_events.Tap = { GestureRange:new{ ges = "tap", range = self.dimen } }
    end
    if Device:hasKeys() then
        self.key_events.AnyKeyPressed = { { Device.input.group.Any } }
    end
    self:setImage(self.file)
end

function Frame:setImage(file)
    if self[1] then self[1]:free() end
    self[1] = ImageWidget:new{
        file = file,
        file_do_cache = false,
        width = self.dimen.w,
        height = self.dimen.h,
        scale_factor = 0,
    }
end

function Frame:onShow()
    UIManager:setDirty(self, function() return "full", self.dimen end)
    return true
end

function Frame:onTap()
    UIManager:close(self)
    return true
end
Frame.onAnyKeyPressed = Frame.onTap

function Frame:onCloseWidget()
    if self[1] then self[1]:free() end
    if self.orig_rotation then Screen:setRotationMode(self.orig_rotation) end
    UIManager:setDirty(nil, "full")
    if self.on_close then self.on_close() end
end

-- Plugin -----------------------------------------------------------------------------------------

local Gallery = WidgetContainer:extend{
    name = NAME,
    is_doc_only = false,
}

function Gallery:init()
    local settings_file = DataStorage:getSettingsDir() .. "/" .. NAME .. ".lua"
    self.dir = DataStorage:getFullDataDir() .. "/" .. NAME
    self.settings = LuaSettings:open(settings_file)
    if lfs.attributes(self.dir, "mode") ~= "directory" then lfs.mkdir(self.dir) end

    -- Eigene Funktionsreferenzen je Instanz, damit unschedule nur diese Instanz trifft.
    self.idle_task = function() self:checkIdle() end
    self.next_task = function() self:nextImage() end
    self.sync_task = function() self:autoSync() end

    self.last_input = now()
    UIManager.event_hook:registerWidget("InputEvent", self)
    self.ui.menu:registerToMainMenu(self)
    self:schedule()
end

function Gallery:setting(key)
    local value = self.settings:readSetting(key)
    if value == nil then return DEFAULTS[key] end
    return value
end

function Gallery:saveSetting(key, value)
    self.settings:saveSetting(key, value)
    self.settings:flush()
    if key == "url" or key == "idle_minutes" or key == "auto_sync" or key == "sync_minutes" then
        self:schedule()
    end
end

function Gallery:configured()
    return Sync.parseShareUrl(self:setting("url")) ~= nil
end

function Gallery:syncConfig()
    return {
        url = self:setting("url"),
        password = self:setting("password"),
        headers = self:setting("headers"),
        rotation = self:setting("landscape_rotation"),
    }
end

--- Leerlauf-Prüfung und automatischen Sync (neu) einplanen, sobald eine Freigabe eingetragen ist.
function Gallery:schedule()
    UIManager:unschedule(self.idle_task)
    UIManager:unschedule(self.sync_task)
    if not self:configured() then return end
    if not self.frame then UIManager:scheduleIn(self:idleSeconds(), self.idle_task) end
    if self:setting("auto_sync") then
        -- Erster Sync kurz nach dem Start, danach im eingestellten Abstand.
        local due = self:setting("sync_minutes") * 60 - secondsSince(shared.last_sync)
        UIManager:scheduleIn(math.max(20, due), self.sync_task)
    end
end

function Gallery:idleSeconds()
    return self:setting("idle_minutes") * 60
end

--- Am Netzteil wechselt das Bild öfter als im Akkubetrieb. Ein voller Akku am Netzteil zählt als
--- Netzteil, auch wenn das Gerät dann nicht mehr lädt.
function Gallery:intervalSeconds()
    if PowerD:isCharging() or PowerD:isCharged() then
        return self:setting("interval_charging_seconds")
    end
    return self:setting("interval_battery_seconds")
end

function Gallery:onInputEvent()
    self.last_input = now()
end

function Gallery:onSuspend()
    UIManager:unschedule(self.idle_task)
end

function Gallery:onResume()
    self.last_input = now()
    if self:configured() and not self.frame then
        UIManager:scheduleIn(self:idleSeconds(), self.idle_task)
    end
end

function Gallery:onCloseWidget()
    self.closing = true
    UIManager:unschedule(self.idle_task)
    UIManager:unschedule(self.sync_task)
    if self.frame then UIManager:close(self.frame) end
end

function Gallery:checkIdle()
    if self.frame then return end
    local rest = self:idleSeconds() - secondsSince(self.last_input)
    if rest > 0 then
        UIManager:scheduleIn(rest, self.idle_task)
    else
        self:startFrame()
    end
end

function Gallery:images()
    local files = {}
    for file in lfs.dir(self.dir) do
        if file:match("%.png$") then table.insert(files, self.dir .. "/" .. file) end
    end
    return files
end

--- Zufällige Reihenfolge, jedes Bild einmal je Runde.
function Gallery:pick()
    local queue = shared.queue
    while #queue > 0 do
        local file = table.remove(queue)
        if lfs.attributes(file, "mode") == "file" then return file end
    end
    local files = self:images()
    for i = #files, 2, -1 do
        local j = math.random(i)
        files[i], files[j] = files[j], files[i]
    end
    shared.queue = files
    return table.remove(files)
end

--- Bilderrahmen starten. `manual`: aus dem Menü, dann gibt es ohne Bilder einen Hinweis.
function Gallery:startFrame(manual)
    if self.frame then return end
    local file = self:pick()
    if not file then
        logger.info("Immich-Galerie: keine Bilder, Bilderrahmen startet nicht")
        if manual then
            UIManager:show(InfoMessage:new{ text = _("Noch keine Bilder. Erst die Freigabe eintragen und abgleichen.") })
        elseif self:configured() then
            UIManager:scheduleIn(self:idleSeconds(), self.idle_task)
        end
        return
    end
    keepAwake(true)
    self.frontlight_was_on = PowerD:isFrontlightOn()
    if self.frontlight_was_on then PowerD:turnOffFrontlight() end
    self.frame = Frame:new{
        file = file,
        on_close = function() self:frameClosed() end,
    }
    UIManager:show(self.frame, "full")
    UIManager:scheduleIn(self:intervalSeconds(), self.next_task)
end

function Gallery:nextImage()
    if not self.frame then return end
    local file = self:pick()
    if file then
        self.frame:setImage(file)
        UIManager:setDirty(self.frame, "full")
    end
    UIManager:scheduleIn(self:intervalSeconds(), self.next_task)
end

function Gallery:frameClosed()
    UIManager:unschedule(self.next_task)
    self.frame = nil
    keepAwake(false)
    if self.frontlight_was_on then PowerD:turnOnFrontlight() end
    self.last_input = now()
    if self:configured() and not self.closing then
        UIManager:scheduleIn(self:idleSeconds(), self.idle_task)
    end
end

-- Abgleich ---------------------------------------------------------------------------------------

function Gallery:autoSync()
    UIManager:scheduleIn(self:setting("sync_minutes") * 60, self.sync_task)
    if not NetworkMgr:isConnected() then
        self:setStatus({ at = os.time(), skipped = true })
        return
    end
    self:doSync()
end

--- Ein Sync. Gibt den Status zurück, den auch statusText() zeigt.
function Gallery:doSync()
    if secondsSince(shared.forbidden_at) < FORBIDDEN_PAUSE then
        local status = { at = os.time(), paused = true }
        self:setStatus(status)
        return status
    end
    shared.last_sync = now()
    local W, H = portraitSize()
    local res, err, code = Sync.sync(self:syncConfig(), self.dir, W, H)
    local status
    if res then
        status = { at = os.time(), total = res.total, added = res.added, removed = res.removed, failed = res.failed }
        shared.queue = {}
    else
        if code == 403 then shared.forbidden_at = now() end
        status = { at = os.time(), error = err }
    end
    self:setStatus(status)
    return status
end

function Gallery:setStatus(status)
    logger.info("Immich-Galerie:", self:statusText(status))
    self.settings:saveSetting("status", status)
    self.settings:flush()
end

--- Ergebnis des letzten Syncs als Text.
function Gallery:statusText(status)
    status = status or self:setting("status")
    if type(status) ~= "table" then return _("noch nicht abgeglichen") end
    local when = os.date(_("%d.%m. %H:%M"), status.at or os.time())
    if status.skipped then return T(_("%1: übersprungen, kein WLAN"), when) end
    if status.paused then return T(_("%1: pausiert, der Server hat den Zugriff verweigert"), when) end
    if status.error then return T(_("%1: Fehler: %2"), when, status.error) end
    local text = T(N_("%1: %2 Bild, %3 neu, %4 entfernt", "%1: %2 Bilder, %3 neu, %4 entfernt", status.total),
        when, status.total, status.added, status.removed)
    if (status.failed or 0) > 0 then text = text .. ", " .. T(_("%1 fehlgeschlagen"), status.failed) end
    return text
end

function Gallery:syncNow(on_done)
    if not self:configured() then
        UIManager:show(InfoMessage:new{ text = _("Erst die Freigabe-URL in den Einstellungen eintragen.") })
        return
    end
    NetworkMgr:runWhenOnline(function()
        local info = InfoMessage:new{ text = _("Gleiche die Freigabe ab …") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local status = self:doSync()
        UIManager:close(info)
        UIManager:show(InfoMessage:new{ text = self:statusText(status), timeout = 5 })
        if on_done then on_done() end
    end)
end

-- Bildschirmschoner ------------------------------------------------------------------------------

function Gallery:usedAsScreensaver()
    return G_reader_settings:readSetting("screensaver_type") == "random_image"
        and G_reader_settings:readSetting("screensaver_dir") == self.dir
end

function Gallery:setScreensaver(on)
    if on then
        G_reader_settings:saveSetting("screensaver_type", "random_image")
        G_reader_settings:saveSetting("screensaver_dir", self.dir)
    elseif self:usedAsScreensaver() then
        G_reader_settings:saveSetting("screensaver_type", "disable")
    end
end

-- Selbst-Update ----------------------------------------------------------------------------------

function Gallery:checkUpdate()
    local updater = require("immichgallery/updater")
    local version = self.version or "?"
    NetworkMgr:runWhenOnline(function()
        local release, err = updater.check(self:setting("update_repo"), version)
        if not release then
            UIManager:show(InfoMessage:new{ text = err and T(_("Prüfung fehlgeschlagen: %1"), err)
                or T(_("Version %1 ist aktuell."), version) })
            return
        end
        UIManager:show(ConfirmBox:new{
            text = T(_("Version %1 ist verfügbar."), release.version) .. "\n\n" .. release.notes:sub(1, 600),
            ok_text = _("Installieren"),
            ok_callback = function()
                local info = InfoMessage:new{ text = _("Update wird geladen …") }
                UIManager:show(info)
                UIManager:forceRePaint()
                local ok, install_err = updater.install(release.url, self.path, self.dir)
                UIManager:close(info)
                if ok then
                    UIManager:askForRestart(_("Update installiert. KOReader jetzt neu starten?"))
                else
                    UIManager:show(InfoMessage:new{ text = T(_("Update fehlgeschlagen: %1"), install_err) })
                end
            end,
        })
    end)
end

-- Menü -------------------------------------------------------------------------------------------

function Gallery:showSettings()
    local Settings = require("immichgallery/settings")
    UIManager:show(Settings:new{ plugin = self })
end

function Gallery:addToMainMenu(menu_items)
    menu_items.immich_gallery = {
        text = _("Immich-Galerie"),
        sorting_hint = "tools",
        sub_item_table = {
            {
                text = _("Bilderrahmen jetzt zeigen"),
                callback = function() self:startFrame(true) end,
            },
            {
                text = _("Jetzt abgleichen"),
                callback = function() self:syncNow() end,
            },
            {
                text_func = function()
                    local n = #self:images()
                    return T(N_("%1 Bild", "%1 Bilder", n), n) .. " · " .. self:statusText()
                end,
                keep_menu_open = true,
                callback = function() end,
            },
            {
                text = _("Einstellungen"),
                callback = function() self:showSettings() end,
            },
            {
                text = _("Nach Updates suchen"),
                callback = function() self:checkUpdate() end,
            },
        },
    }
end

return Gallery
