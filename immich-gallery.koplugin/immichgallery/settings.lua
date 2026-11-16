--[[--
Einstellungsseite: Freigabe mit Extra-Headern und Verbindungstest, Abgleich, Bilderrahmen. Passt
nicht alles auf den Bildschirm, wird geblättert.
]]

local ButtonDialog = require("ui/widget/buttondialog")
local Device = require("device")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local InfoMessage = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local InputDialog = require("ui/widget/inputdialog")
local MultiInputDialog = require("ui/widget/multiinputdialog")
local NetworkMgr = require("ui/network/manager")
local SpinWidget = require("ui/widget/spinwidget")
local UIManager = require("ui/uimanager")
local VerticalGroup = require("ui/widget/verticalgroup")
local Sync = require("immichgallery/sync")
local UI = require("immichgallery/ui")
local _ = require("immichgallery/i18n")
local N_, T = _.ngettext, _.T

local Settings = InputContainer:extend{
    name = "immich_gallery_settings",
    plugin = nil,
    covers_fullscreen = true,
}

local ROW = 88

function Settings:init()
    self.dimen = Geom:new{ x = 0, y = 0, w = UI.width(), h = UI.height() }
    self.ges_events.Swipe = { GestureRange:new{ ges = "swipe", range = self.dimen } }
    if Device:hasKeys() then
        self.key_events.Close = { { Device.input.group.Back } }
        self.key_events.NextPage = { { Device.input.group.PgFwd } }
        self.key_events.PrevPage = { { Device.input.group.PgBack } }
    end
    self.page = 1
    self:refresh()
end

local function innerWidth() return UI.width() - 2 * UI.px(48) end

--- Zeile mit fester Höhe: links Beschriftung (und Zusatz), rechts Wert.
local function row(left, right, callback)
    local box = VerticalGroup:new{
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = UI.px(48), padding_right = UI.px(48),
            UI.LeftContainer:new{ dimen = Geom:new{ w = innerWidth(), h = UI.px(ROW) - 1 },
                UI.spread(left, right, innerWidth()) } },
        UI.line(UI.width(), 1, UI.LINE),
    }
    return callback and UI.tap(box, callback) or box
end

local function label(text, sub, w)
    local items = { align = "left", UI.text(text, 26, { bold = true, max_width = w }) }
    if sub then table.insert(items, UI.text(sub, 22, { color = UI.GRAY, max_width = w })) end
    return VerticalGroup:new(items)
end

local function chevron() return UI.icon("chevron.right", 32) end

--- Schalter: An/Aus als Text und ein Schiebeschalter.
local function switch(on)
    local knob = UI.box(UI.text("", 10), UI.px(34), UI.px(34), {
        border = 0, radius = 17, background = on and UI.WHITE or UI.BLACK })
    local track = FrameContainer:new{
        bordersize = UI.px(3), radius = UI.px(25), color = UI.BLACK, background = on and UI.BLACK or UI.WHITE,
        padding = 0, padding_left = UI.px(5), padding_right = UI.px(5),
        UI.LeftContainer:new{ dimen = Geom:new{ w = UI.px(76), h = UI.px(44) },
            HorizontalGroup:new{ on and UI.hspan(42) or UI.hspan(0), knob } },
    }
    return HorizontalGroup:new{ align = "center",
        UI.text(on and _("An") or _("Aus"), 24, { bold = true, color = on and UI.BLACK or UI.GRAY }), UI.hspan(20), track }
end

--- Sekunden als „45 s“ oder „5 Min.“.
local function duration(seconds)
    if seconds < 60 or seconds % 60 ~= 0 then return T(_("%1 s"), seconds) end
    return T(_("%1 Min."), seconds / 60)
end

local ROTATIONS = {
    { value = 90, label = _("nach links drehen") },
    { value = -90, label = _("nach rechts drehen") },
    { value = 0, label = _("nicht drehen, zuschneiden") },
}

function Settings:edit(title, key, opts)
    opts = opts or {}
    local p = self.plugin
    local dialog
    dialog = InputDialog:new{
        title = title,
        input = opts.password and "" or p:setting(key),
        input_hint = opts.hint,
        text_type = opts.password and "password" or nil,
        buttons = { {
            { text = _("Abbrechen"), id = "close", callback = function() UIManager:close(dialog) end },
            { text = _("Speichern"), is_enter_default = true, callback = function()
                local value = dialog:getInputText()
                if not opts.password then value = value:gsub("^%s+", ""):gsub("%s+$", "") end
                if opts.validate and not opts.validate(value) then
                    UIManager:show(InfoMessage:new{ text = opts.invalid })
                    return
                end
                UIManager:close(dialog)
                p:saveSetting(key, value)
                self.test_result = nil
                self:refresh()
            end },
        } },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Settings:editHeader(index)
    local p = self.plugin
    local headers = p:setting("headers")
    local h = headers[index] or {}
    local dialog
    local buttons = { { text = _("Abbrechen"), id = "close", callback = function() UIManager:close(dialog) end } }
    if headers[index] then
        table.insert(buttons, 1, { text = _("Entfernen"), callback = function()
            UIManager:close(dialog)
            table.remove(headers, index)
            p:saveSetting("headers", headers)
            self:refresh()
        end })
    end
    table.insert(buttons, { text = _("Speichern"), callback = function()
        local fields = dialog:getFields()
        UIManager:close(dialog)
        local name = (fields[1] or ""):gsub("%s", "")
        if name ~= "" then
            headers[index] = { name = name, value = fields[2] or "" }
            p:saveSetting("headers", headers)
        end
        self.test_result = nil
        self:refresh()
    end })
    dialog = MultiInputDialog:new{
        title = _("Extra-Header"),
        fields = {
            { description = _("Name"), text = h.name or "", hint = "X-Api-Key" },
            { description = _("Wert"), text = h.value or "", text_type = "password" },
        },
        buttons = { buttons },
    }
    UIManager:show(dialog)
    dialog:onShowKeyboard()
end

function Settings:number(title, key, unit, min, max, step)
    local p = self.plugin
    UIManager:show(SpinWidget:new{
        title_text = title,
        value = p:setting(key),
        value_min = min,
        value_max = max,
        value_step = step,
        value_hold_step = step * 6,
        unit = unit,
        callback = function(spin)
            p:saveSetting(key, spin.value)
            self:refresh()
        end,
    })
end

function Settings:chooseRotation()
    local dialog
    local rows = {}
    for _, r in ipairs(ROTATIONS) do
        table.insert(rows, { { text = r.label, callback = function()
            UIManager:close(dialog)
            self.plugin:saveSetting("landscape_rotation", r.value)
            self:refresh()
        end } })
    end
    dialog = ButtonDialog:new{ title = _("Bilder im Querformat"), buttons = rows }
    UIManager:show(dialog)
end

function Settings:testConnection()
    local p = self.plugin
    if not p:configured() then
        self.test_ok, self.test_result = false, _("Erst die Freigabe-URL eintragen")
        self:refresh()
        return
    end
    NetworkMgr:runWhenConnected(function()
        -- Anmeldung und Abfrage blockieren; das Popup vorher zeichnen, sonst sieht man nichts davon.
        local info = InfoMessage:new{ text = _("Verbindung zu Immich wird getestet …") }
        UIManager:show(info)
        UIManager:forceRePaint()
        local n, err = Sync.count(p:syncConfig())
        self.test_ok = n ~= nil
        self.test_result = n and T(N_("%1 Bild in der Freigabe", "%1 Bilder in der Freigabe", n), n) or err
        UIManager:close(info)
        self:refresh()
    end)
end

function Settings:rows()
    local p = self.plugin
    local w = innerWidth() - UI.px(360)
    local list = {}
    local function add(widget) table.insert(list, widget) end
    local function toggle(text, sub, on, callback)
        add(row(label(text, sub, w), switch(on), function()
            callback(not on)
            self:refresh()
        end))
    end
    local function value(text, shown, callback, sub)
        add(row(label(text, sub, w), HorizontalGroup:new{ align = "center",
            UI.text(shown, 24, { color = UI.DARK, max_width = innerWidth() - w - UI.px(60) }), UI.hspan(12),
            chevron() }, callback))
    end
    local function section(text)
        local widget = UI.section(text)
        widget.keep_with_next = true
        add(widget)
    end
    local function buttonRow(text, sub, button_label, callback, result, result_ok)
        local right = result and UI.text(result, 22, { bold = result_ok, color = result_ok and UI.BLACK or UI.DARK,
            max_width = innerWidth() - UI.px(420) })
        add(row(HorizontalGroup:new{ align = "center", label(text, sub, UI.px(220)), UI.hspan(20),
            UI.button(button_label, callback, { height = UI.px(64) }) }, right or nil))
    end

    local missing = _("nicht eingetragen")
    section(_("FREIGABE"))
    local url = p:setting("url")
    value(_("Freigabe-URL"), url ~= "" and url:gsub("^https?://", "") or missing, function()
        self:edit(_("Freigabe-URL aus Immich"), "url", {
            hint = "https://immich.example.com/s/name",
            validate = function(v) return Sync.parseShareUrl(v) ~= nil end,
            invalid = _("Keine Freigabe-URL. Erwartet wird https://<server>/s/<name> oder https://<server>/share/<schlüssel>."),
        })
    end)
    value(_("Passwort"), p:setting("password") ~= "" and "••••••••" or _("keins"), function()
        self:edit(_("Passwort der Freigabe"), "password", { password = true })
    end, _("leer, wenn die Freigabe keins hat"))
    local headers = p:setting("headers")
    for i, h in ipairs(headers) do
        value(i == 1 and _("Extra-Header") or "", (h.name or "") .. ": ••••", function() self:editHeader(i) end,
            i == 1 and _("gehen bei jeder Anfrage mit") or nil)
    end
    value(#headers == 0 and _("Extra-Header") or "", _("Header hinzufügen"), function() self:editHeader(#headers + 1) end,
        #headers == 0 and _("gehen bei jeder Anfrage mit") or nil)
    buttonRow(_("Verbindung"), nil, _("Testen"), function() self:testConnection() end, self.test_result, self.test_ok)

    section(_("ABGLEICH"))
    local minutes = p:setting("sync_minutes")
    toggle(_("Automatisch abgleichen"), T(N_("alle %1 Minute, wenn das WLAN an ist",
        "alle %1 Minuten, wenn das WLAN an ist", minutes), minutes), p:setting("auto_sync"),
        function(on) p:saveSetting("auto_sync", on) end)
    value(_("Abstand"), T(_("%1 Min."), minutes), function()
        self:number(_("Abgleich alle"), "sync_minutes", _("Min."), 10, 1440, 10)
    end)
    buttonRow(_("Jetzt"), nil, _("Abgleichen"), function() p:syncNow(function() self:refresh() end) end,
        p:statusText(), false)

    section(_("BILDERRAHMEN"))
    value(_("Start nach Leerlauf"), T(_("%1 Min."), p:setting("idle_minutes")), function()
        self:number(_("Start nach Leerlauf"), "idle_minutes", _("Min."), 1, 9, 1)
    end, _("Zeit ohne Bedienung, unter 10 Minuten"))
    value(_("Bildwechsel am Netzteil"), duration(p:setting("interval_charging_seconds")), function()
        self:number(_("Bildwechsel am Netzteil"), "interval_charging_seconds", _("s"), 10, 3600, 10)
    end)
    value(_("Bildwechsel im Akkubetrieb"), duration(p:setting("interval_battery_seconds")), function()
        self:number(_("Bildwechsel im Akkubetrieb"), "interval_battery_seconds", _("s"), 10, 3600, 10)
    end)
    local rotation = ROTATIONS[1].label
    for _, r in ipairs(ROTATIONS) do if r.value == p:setting("landscape_rotation") then rotation = r.label end end
    value(_("Bilder im Querformat"), rotation, function() self:chooseRotation() end,
        _("wirkt beim nächsten Abgleich"))
    if Device:supportsScreensaver() then
        toggle(_("Auch als Bildschirmschoner"), _("beim Ausschalten ein zufälliges Bild"), p:usedAsScreensaver(),
            function(on) p:setScreensaver(on) end)
    end
    buttonRow(_("Bilderrahmen"), nil, _("Jetzt zeigen"), function()
        self:close()
        p:startFrame(true)
    end)

    section(_("UPDATES"))
    value(_("GitHub-Repo"), p:setting("update_repo"), function()
        self:edit(_("GitHub-Repo für das Selbst-Update"), "update_repo", { hint = _("besitzer/repo") })
    end, _("für Updates ohne AppStore"))
    return list
end

function Settings:refresh()
    local H = UI.height()
    local header = UI.header(_("Einstellungen"), function() self:close() end)
    local avail = H - UI.headerHeight() - UI.px(104)
    local pages, current, used = { {} }, 1, 0
    local rows = self:rows()
    for i, widget in ipairs(rows) do
        local h = widget:getSize().h
        -- Ein Abschnittskopf kommt nur mit seiner ersten Zeile auf die Seite.
        local need = h + ((widget.keep_with_next and rows[i + 1]) and rows[i + 1]:getSize().h or 0)
        if used + need > avail and #pages[current] > 0 then
            current = current + 1
            pages[current] = {}
            used = 0
        end
        table.insert(pages[current], widget)
        used = used + h
    end
    self.pages = #pages
    self.page = math.min(self.page, self.pages)
    local body = { align = "left" }
    for _, widget in ipairs(pages[self.page]) do table.insert(body, widget) end
    local pager = UI.CenterContainer:new{ dimen = Geom:new{ w = UI.width(), h = UI.px(104) },
        UI.pager(self.page, self.pages, function() self:turn(-1) end, function() self:turn(1) end) }
    if self[1] then self[1]:free() end
    self[1] = FrameContainer:new{
        bordersize = 0, padding = 0, margin = 0, background = UI.WHITE, width = UI.width(), height = H,
        VerticalGroup:new{ align = "left", header,
            UI.fixed(VerticalGroup:new(body), UI.width(), avail),
            self.pages > 1 and pager or UI.vspan(0) },
    }
    UIManager:setDirty(self, "ui")
end

function Settings:turn(delta)
    local new = math.min(math.max(self.page + delta, 1), self.pages or 1)
    if new ~= self.page then
        self.page = new
        self:refresh()
    end
end

function Settings:onSwipe(_, ges)
    if ges.direction == "west" then self:turn(1); return true end
    if ges.direction == "east" then self:turn(-1); return true end
end

function Settings:onNextPage() self:turn(1); return true end
function Settings:onPrevPage() self:turn(-1); return true end

function Settings:close()
    UIManager:close(self, "flashui")
end

function Settings:onClose()
    self:close()
    return true
end

return Settings
