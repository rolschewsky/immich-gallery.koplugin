-- Selbsttest der reinen Logik ohne KOReader. Aufruf aus dem Repo-Ordner:
--   luajit tests/test_logic.lua   (auf dem Kindle: /mnt/us/koreader/luajit …)
package.path = "immich-gallery.koplugin/?.lua;" .. package.path
for _, name in ipairs{ "ffi/blitbuffer", "json", "ui/renderimage", "socket.http", "ssl.https",
        "libs/libkoreader-lfs", "logger", "ltn12", "socket", "socketutil" } do
    package.preload[name] = function() return {} end
end
package.preload["socket.url"] = function()
    return { escape = function(s) return (s:gsub("[^%w%-_.~]", function(c)
        return string.format("%%%02X", c:byte()) end)) end }
end

local M = require("immichgallery/sync")

-- Freigabe-URL
local base, kind, value = M.parseShareUrl("https://immich.example.com/s/frame")
assert(base == "https://immich.example.com" and kind == "slug" and value == "frame")
base, kind, value = M.parseShareUrl("https://photos.example.org:2283/share/AbC-123_x?foo=1")
assert(base == "https://photos.example.org:2283" and kind == "key" and value == "AbC-123_x")
assert(M.parseShareUrl("https://immich.example.com/photos/123") == nil)
assert(M.parseShareUrl(nil) == nil)

-- Hostnamen im Zertifikat
assert(M.hostMatches("immich.example.com", "IMMICH.example.com"))
assert(M.hostMatches("*.example.com", "immich.example.com"))
assert(not M.hostMatches("*.example.com", "immich.home.example.com"))
assert(not M.hostMatches("*.example.com", "example.com"))
assert(not M.hostMatches("*.badssl.com", "immich.example.com"))
assert(not M.hostMatches("home.example.com", "immich.home.example.com"))

-- Zoom: füllt immer, schneidet mittig, Seitenverhältnis bleibt
local function check(w, h, W, H)
    local sw, sh, ox, oy = M.coverBox(w, h, W, H)
    assert(sw >= W and sh >= H, "füllt nicht")
    assert(sw == W or sh == H, "zu groß skaliert")
    assert(math.abs(sw / sh - w / h) < 0.01, "verzerrt")
    assert(ox == math.floor((sw - W) / 2) and oy == math.floor((sh - H) / 2), "nicht mittig")
    return sw, sh, ox, oy
end
local sw, sh, ox, oy = check(1440, 1920, 1072, 1448)   -- Hochformat 3:4 auf dem Paperwhite
assert(sw == 1086 and sh == 1448 and ox == 7 and oy == 0)
sw, sh, ox, oy = check(1920, 1440, 1072, 1448)          -- Querformat 4:3
assert(sh == 1448 and ox == math.floor((sw - 1072) / 2) and oy == 0)
check(1440, 1440, 600, 800)                             -- quadratisch auf einem kleinen Kindle
check(720, 1188, 1072, 1448)                            -- schmaler als der Bildschirm

-- Längste Kante gewinnt: nur Bilder quer zum Bildschirm drehen
assert(M.needsRotation(1920, 1440, 1072, 1448))       -- Querformat auf Hochformat
assert(not M.needsRotation(1440, 1920, 1072, 1448))   -- Hochformat bleibt
assert(not M.needsRotation(1440, 1440, 1072, 1448))   -- quadratisch bleibt
assert(M.needsRotation(1440, 1920, 1448, 1072))       -- Hochformat auf Querformat-Bildschirm
sw, sh, ox, oy = check(1440, 1920, 1072, 1448)
assert(ox <= 7 and oy == 0)

-- Fehlertexte
assert(M.describe(403):find("403") and M.describe(401):find("401") and M.describe(500):find("500"))
assert(M.describe("timeout") == "timeout")

-- Client: Extra-Header gehen mit, ungültige URL wird abgelehnt
local client = M.newClient({ url = "https://immich.example.com/s/frame",
    headers = { { name = "X-Api-Key", value = "geheim" } } })
assert(client.api == "https://immich.example.com/api" and client.query == "slug=frame")
assert(client.headers[1].name == "X-Api-Key")
assert(M.newClient({ url = "https://immich.example.com/" }) == nil)

-- Selbst-Update: Versionen vergleichen, das richtige Zip aus dem Release wählen
local version = require("immichgallery/version")
assert(version.newer("v0.2.0", "0.1.0"))
assert(version.newer("1.0.0", "1.0.0-beta1"))
assert(not version.newer("v0.1.0", "0.1.0"))
assert(not version.newer("0.1.0-rc1", "0.1.0"))
assert(not version.newer("kaputt", "0.1.0"))
local updater = require("immichgallery/updater")
assert(updater.pickAsset({ assets = { { name = "notes.txt" }, { name = "immich-gallery.koplugin-v0.2.0.zip" } } }).name
    == "immich-gallery.koplugin-v0.2.0.zip")
assert(updater.pickAsset({ assets = { { name = "grimmory-ui.koplugin-v1.2.0.zip" } } }) == nil)
assert(updater.pickAsset(nil) == nil)

print("ok")
