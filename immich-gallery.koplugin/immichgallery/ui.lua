--[[--
Bausteine der Einstellungsseite: Kopfzeile, Abschnitte, Knöpfe, Blättern.

Alle Maße sind Pixel bei 300 ppi (Kindle Paperwhite). `UI.px` rechnet sie auf die Pixeldichte des
Geräts um, damit Schrift und Tippflächen überall physisch gleich groß sind.
]]

local Blitbuffer = require("ffi/blitbuffer")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Font = require("ui/font")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan = require("ui/widget/horizontalspan")
local IconWidget = require("ui/widget/iconwidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local LeftContainer = require("ui/widget/container/leftcontainer")
local LineWidget = require("ui/widget/linewidget")
local OverlapGroup = require("ui/widget/overlapgroup")
local TextBoxWidget = require("ui/widget/textboxwidget")
local TextWidget = require("ui/widget/textwidget")
local VerticalGroup = require("ui/widget/verticalgroup")
local VerticalSpan = require("ui/widget/verticalspan")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local _ = require("immichgallery/i18n")

local Screen = Device.screen

local UI = {}

UI.BLACK = Blitbuffer.COLOR_BLACK
UI.WHITE = Blitbuffer.COLOR_WHITE
UI.GRAY = Blitbuffer.COLOR_GRAY_5        -- Zweitinformation, #555
UI.DARK = Blitbuffer.COLOR_GRAY_3        -- #333
UI.LINE = Blitbuffer.COLOR_GRAY_B        -- Trennlinien
UI.SECTION = Blitbuffer.COLOR_GRAY_E     -- Abschnittsköpfe

local factor = (Screen:getDPI() or 300) / 300
local font_unit = Screen:scaleBySize(1000) / 1000

--- Entwurfs-Pixel (300 ppi) in Geräte-Pixel.
function UI.px(v)
    return math.max(1, math.floor(v * factor + 0.5))
end

function UI.width() return Screen:getWidth() end
function UI.height() return Screen:getHeight() end

local FONTS = {
    sans = "NotoSans-Regular.ttf", sansb = "NotoSans-Bold.ttf",
    serif = "NotoSerif-Regular.ttf", serifb = "NotoSerif-Bold.ttf",
}

--- Schrift in Entwurfs-Pixeln. Font:getFace skaliert selbst noch einmal, das wird hier ausgeglichen.
function UI.face(size, bold, serif)
    local key = (serif and "serif" or "sans") .. (bold and "b" or "")
    return Font:getFace(FONTS[key], math.max(6, math.floor(size * factor / font_unit + 0.5)))
end

function UI.vspan(h) return VerticalSpan:new{ width = UI.px(h) } end
function UI.hspan(w) return HorizontalSpan:new{ width = UI.px(w) } end
function UI.rawhspan(w) return HorizontalSpan:new{ width = math.max(0, w) } end

function UI.line(w, h, color)
    return LineWidget:new{ background = color or UI.BLACK, dimen = Geom:new{ w = w, h = h } }
end

--- Einzeiliger Text, bei Überlänge mit „…“.
function UI.text(str, size, o)
    o = o or {}
    return TextWidget:new{
        text = str or "",
        face = UI.face(size, o.bold, o.serif),
        fgcolor = o.color or UI.BLACK,
        max_width = o.max_width,
    }
end

--- Mehrzeiliger Text.
function UI.textbox(str, size, width, o)
    o = o or {}
    return TextBoxWidget:new{
        text = str or "",
        face = UI.face(size, o.bold, o.serif),
        width = width,
        fgcolor = o.color or UI.BLACK,
        alignment = o.align or "left",
        line_height = 0.25,
    }
end

function UI.icon(name, size, o)
    o = o or {}
    return IconWidget:new{ icon = name, width = UI.px(size), height = UI.px(size), dim = o.dim }
end

-- Antippbarer Bereich ------------------------------------------------------------------------

local Tap = InputContainer:extend{ callback = nil }

function Tap:init()
    local range = function() return self.dimen end
    self.ges_events = { ImmichGalleryTap = { GestureRange:new{ ges = "tap", range = range } } }
end

--- Nur, wenn der Finger wirklich auf dieser Fläche liegt. Eine äußere Fläche reicht ihr Ereignis
--- erst an die inneren weiter, sonst löste ein Tippen daneben die erste innere aus.
function Tap:onImmichGalleryTap(_, ges)
    if self.callback and (not (ges and ges.pos and self.dimen) or self.dimen:contains(ges.pos)) then
        self.callback()
        return true
    end
end

function UI.tap(widget, callback)
    return Tap:new{ callback = callback, widget }
end

-- Rahmen und Knöpfe --------------------------------------------------------------------------

--- Rahmen mit fester Außengröße w × h, Inhalt mittig.
function UI.box(child, w, h, o)
    o = o or {}
    local b = o.border == 0 and 0 or UI.px(o.border or 2)
    return FrameContainer:new{
        bordersize = b, padding = 0, margin = 0,
        radius = o.radius and UI.px(o.radius) or nil,
        color = o.color or UI.BLACK,
        background = o.background or UI.WHITE,
        CenterContainer:new{ dimen = Geom:new{ w = w - 2 * b, h = h - 2 * b }, child },
    }
end

--- Knopf mit Text. o: primary (schwarz), width, height, size.
function UI.button(label, callback, o)
    o = o or {}
    local text = UI.text(label, o.size or 26, { bold = true, color = o.primary and UI.WHITE or UI.BLACK })
    local w = o.width or (text:getSize().w + UI.px(48))
    local h = o.height or UI.px(72)
    return UI.tap(UI.box(text, w, h, {
        border = 2, radius = 12, background = o.primary and UI.BLACK or UI.WHITE,
    }), callback)
end

--- Blättern: ‹ Seite x von y ›.
function UI.pager(page, pages, on_prev, on_next)
    local function arrow(icon, enabled, cb)
        local box = UI.box(UI.icon(icon, 40, { dim = not enabled }), UI.px(96), UI.px(72), {
            radius = 12, color = enabled and UI.BLACK or UI.LINE,
        })
        return UI.tap(box, enabled and cb or nil)
    end
    -- Mindestens 190 px, breiter, wenn die Übersetzung länger ist (etwa „Halaman 1 dari 2“).
    local label = UI.text(_.T(_("Seite %1 von %2"), page, pages), 24)
    return HorizontalGroup:new{
        align = "center",
        arrow("chevron.left", page > 1, on_prev),
        CenterContainer:new{
            dimen = Geom:new{ w = math.max(UI.px(190), label:getSize().w + UI.px(32)), h = UI.px(72) },
            label,
        },
        arrow("chevron.right", page < pages, on_next),
    }
end

--- Zeile mit linkem und rechtem Teil, auf `w` verteilt.
function UI.spread(left, right, w)
    local lw = left and left:getSize().w or 0
    local rw = right and right:getSize().w or 0
    local row = { align = "center" }
    if left then table.insert(row, left) end
    table.insert(row, UI.rawhspan(w - lw - rw))
    if right then table.insert(row, right) end
    return HorizontalGroup:new(row)
end

--- Feste Größe, Inhalt oben links. FrameContainer.width/height wirken nur beim Malen, nicht auf
--- getSize().
function UI.fixed(child, w, h)
    return WidgetContainer:new{ dimen = Geom:new{ w = w, h = h }, child }
end

-- Kopfzeile und Abschnitte -------------------------------------------------------------------

--- Kopfzeile mit „‹ Zurück-Text“ links.
function UI.header(back, on_back)
    local W, H = UI.width(), UI.px(112)
    local content = HorizontalGroup:new{
        align = "center",
        UI.icon("chevron.left", 44), UI.hspan(8),
        UI.text(back or "", 30, { bold = true, max_width = W - UI.px(320) }),
    }
    local left = UI.tap(FrameContainer:new{
        bordersize = 0, padding = 0, padding_left = UI.px(16), padding_right = UI.px(24),
        CenterContainer:new{ dimen = Geom:new{ w = content:getSize().w, h = H }, content },
    }, on_back)
    return VerticalGroup:new{
        OverlapGroup:new{ dimen = Geom:new{ w = W, h = H }, LeftContainer:new{ dimen = Geom:new{ w = W, h = H }, left } },
        UI.line(W, UI.px(3)),
    }
end

function UI.headerHeight() return UI.px(112) + UI.px(3) end

--- Graue Abschnittsleiste wie „FREIGABE“.
function UI.section(label)
    local W = UI.width()
    return VerticalGroup:new{
        UI.line(W, UI.px(2)),
        FrameContainer:new{ bordersize = 0, padding = 0, padding_left = UI.px(48), padding_right = UI.px(48),
            background = UI.SECTION,
            LeftContainer:new{ dimen = Geom:new{ w = W - 2 * UI.px(48), h = UI.px(56) },
                UI.text(label, 22, { bold = true }) } },
        UI.line(W, 1, UI.LINE),
    }
end

UI.VerticalGroup = VerticalGroup
UI.HorizontalGroup = HorizontalGroup
UI.FrameContainer = FrameContainer
UI.CenterContainer = CenterContainer
UI.LeftContainer = LeftContainer
UI.Geom = Geom

return UI
