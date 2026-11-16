--[[--
Holt die Bilder einer Immich-Freigabe und legt sie bildschirmgroß zugeschnitten ab.

Ablauf (Immich v2 und v3): Anmeldung mit dem Passwort im Body, Liste über die Timeline des Albums,
je Bild die Vorschau. Jeder Aufruf prüft das Zertifikat samt Hostnamen, weil LuaSec von sich aus
weder das eine noch das andere tut.
]]

local Blitbuffer = require("ffi/blitbuffer")
local JSON = require("json")
local RenderImage = require("ui/renderimage")
local http = require("socket.http")
local https = require("ssl.https")
local lfs = require("libs/libkoreader-lfs")
local logger = require("logger")
local ltn12 = require("ltn12")
local socket = require("socket")
local socketutil = require("socketutil")
local url = require("socket.url")
local _ = require("immichgallery/i18n")
local T = _.T

-- Relativ zum Arbeitsverzeichnis von KOReader (/mnt/us/koreader auf dem Kindle).
local CAFILE = "data/ca-bundle.crt"

local M = {}

--- Zerlegt eine Freigabe-URL in Server, Art (slug oder key) und Wert.
function M.parseShareUrl(share_url)
    local base, kind, value = (share_url or ""):match("^(https?://[^/]+)/(s)/([^/?#]+)")
    if not base then
        base, kind, value = (share_url or ""):match("^(https?://[^/]+)/(share)/([^/?#]+)")
    end
    if not base then return nil end
    return base, kind == "s" and "slug" or "key", value
end

--- Passt ein Name aus dem Zertifikat (auch `*.domain`) auf den Host?
function M.hostMatches(pattern, host)
    pattern, host = pattern:lower(), host:lower()
    if pattern == host then return true end
    local suffix = pattern:match("^%*(%.[^*]+)$")
    if not suffix then return false end
    local rest = host:match("^[^.]+(%..+)$")
    return rest == suffix
end

--- „Längste Kante gewinnt“: Liegt die lange Seite des Bildes quer zur langen Seite des Bildschirms?
function M.needsRotation(w, h, W, H)
    return w ~= h and (w > h) ~= (W > H)
end

--- Faktor und Ausschnitt für „Zoom“: füllt W × H, Seitenverhältnis bleibt, mittig zugeschnitten.
function M.coverBox(w, h, W, H)
    local f = math.max(W / w, H / h)
    local sw = math.max(W, math.floor(w * f + 0.5))
    local sh = math.max(H, math.floor(h * f + 0.5))
    return sw, sh, math.floor((sw - W) / 2), math.floor((sh - H) / 2)
end

local function certNames(cert)
    local names = {}
    local ok, exts = pcall(cert.extensions, cert)
    if ok and type(exts) == "table" then
        for _, ext in pairs(exts) do
            if type(ext) == "table" and type(ext.dNSName) == "table" then
                for _, name in ipairs(ext.dNSName) do table.insert(names, name) end
            end
        end
    end
    return names
end

-- Verbindung wie bei LuaSec, aber mit Prüfung der Kette gegen das CA-Bundle und des Hostnamens.
local function checkedCreate()
    local base_create = https.tcp{
        protocol = "any",
        options = { "all", "no_sslv2", "no_sslv3", "no_tlsv1" },
        verify = "peer",
        cafile = CAFILE,
    }
    return function()
        local conn = base_create()
        local connect = conn.connect
        conn.connect = function(self, host, port)
            local ok = connect(self, host, port)
            local cert = self.sock:getpeercertificate()
            for _, name in ipairs(cert and certNames(cert) or {}) do
                if M.hostMatches(name, host) then return ok end
            end
            self.sock:close()
            socket.try(nil, T(_("Zertifikat passt nicht zu %1"), host))
        end
        return conn
    end
end

local Client = {}
Client.__index = Client

--- cfg: url, password, headers (Liste aus { name, value }).
function M.newClient(cfg)
    local base, kind, value = M.parseShareUrl(cfg.url)
    if not base then return nil, _("Freigabe-URL ungültig") end
    return setmetatable({
        api = base .. "/api",
        query = kind .. "=" .. url.escape(value),
        headers = cfg.headers or {},
        password = cfg.password,
    }, Client)
end

--- Ein HTTP-Aufruf, bei https mit Prüfung des Zertifikats. Gibt Status-Code (Zahl), Body und Header
--- zurück, bei Netzwerkfehlern nil und die Meldung. Mit `file` landet der Body in dieser Datei.
--- Weiterleitungen werden nicht verfolgt, damit Header und Passwort nie zu einem anderen Host gehen.
function M.fetch(method, full_url, headers, body, file)
    local chunks = {}
    local req = { url = full_url, method = method, headers = headers, redirect = false }
    if full_url:match("^https://") then req.create = checkedCreate() end
    if body then
        headers["Content-Type"] = "application/json"
        headers["Content-Length"] = tostring(#body)
        req.source = ltn12.source.string(body)
    end
    if file then
        local fh = io.open(file, "wb")
        if not fh then return nil, T(_("Datei nicht schreibbar: %1"), file) end
        req.sink = ltn12.sink.file(fh)
        socketutil:set_timeout(socketutil.FILE_BLOCK_TIMEOUT, socketutil.FILE_TOTAL_TIMEOUT)
    else
        req.sink = ltn12.sink.table(chunks)
        socketutil:set_timeout(socketutil.LARGE_BLOCK_TIMEOUT, socketutil.LARGE_TOTAL_TIMEOUT)
    end
    local code, resp_headers, status = socket.skip(1, http.request(req))
    socketutil:reset_timeout()
    if resp_headers == nil then return nil, tostring(status or code) end
    return code, table.concat(chunks), resp_headers
end

--- Ein Aufruf der API mit Extra-Headern und Cookie der Freigabe, Ergebnis wie bei M.fetch.
function Client:call(method, path, body, file)
    local headers = { ["Accept"] = "application/json" }
    for _, h in ipairs(self.headers) do
        if h.name and h.name ~= "" then headers[h.name] = h.value or "" end
    end
    if self.cookie then headers["Cookie"] = self.cookie end
    return M.fetch(method, self.api .. path .. (path:find("?", 1, true) and "&" or "?") .. self.query,
        headers, body, file)
end

function Client:login()
    local code, err, headers = self:call("POST", "/shared-links/login",
        JSON.encode({ password = self.password or "" }))
    if code ~= 200 and code ~= 201 then return nil, code or err end
    local token = (headers["set-cookie"] or ""):match("immich_shared_link_token=([^;,%s]+)")
    if not token then return nil, _("Anmeldung ohne Cookie") end
    self.cookie = "immich_shared_link_token=" .. token
    return true
end

local function getJSON(client, path)
    local code, body = client:call("GET", path)
    if code ~= 200 then return nil, code or body end
    local ok, data = pcall(JSON.decode, body)
    if not ok or type(data) ~= "table" then return nil, _("Antwort ist kein JSON") end
    return data
end

--- Liste der Bild-IDs in der Freigabe.
function Client:listImages()
    local me, err = getJSON(self, "/shared-links/me")
    if not me then return nil, err end
    local ids = {}
    if me.type == "INDIVIDUAL" then
        for _, asset in ipairs(me.assets or {}) do
            if asset.type == "IMAGE" then table.insert(ids, asset.id) end
        end
        return ids
    end
    local album = type(me.album) == "table" and me.album.id
    if not album then return nil, _("Freigabe ohne Album") end
    local buckets
    buckets, err = getJSON(self, "/timeline/buckets?albumId=" .. album)
    if not buckets then return nil, err end
    for _, bucket in ipairs(buckets) do
        local cols
        cols, err = getJSON(self, "/timeline/bucket?albumId=" .. album
            .. "&timeBucket=" .. url.escape(bucket.timeBucket))
        if not cols then return nil, err end
        for i, id in ipairs(cols.id or {}) do
            if cols.isImage and cols.isImage[i] then table.insert(ids, id) end
        end
    end
    return ids
end

--- Anmelden, wenn nötig, und die Liste holen. Ergebnis: Liste der IDs oder nil, Meldung, Status.
local function connect(cfg)
    local client, err = M.newClient(cfg)
    if not client then return nil, err end
    if cfg.password and cfg.password ~= "" then
        local ok, login_err = client:login()
        if not ok then return nil, M.describe(login_err), login_err end
    end
    local ids, list_err = client:listImages()
    if not ids then return nil, M.describe(list_err), list_err end
    return client, ids
end

--- Verbindungstest: Anzahl der Bilder in der Freigabe oder nil, Meldung, Status.
function M.count(cfg)
    local client, ids, code = connect(cfg)
    if not client then return nil, ids, code end
    return #ids
end

--- Lädt ein JPEG, dreht es bei Bedarf um `rotation` Grad (0 = nie), schneidet es auf W × H zu
--- und schreibt es als Graustufen-PNG.
function M.cropTo(src, dst, W, H, rotation)
    local bb = RenderImage:renderImageFile(src, false)
    if not bb then return nil, _("Bild nicht lesbar") end
    if rotation ~= 0 and M.needsRotation(bb:getWidth(), bb:getHeight(), W, H) then
        local rotated = bb:rotatedCopy(rotation)
        bb:free()
        bb = rotated
    end
    local sw, sh, ox, oy = M.coverBox(bb:getWidth(), bb:getHeight(), W, H)
    local scaled = RenderImage:scaleBlitBuffer(bb, sw, sh, true)
    local out = Blitbuffer.new(W, H, Blitbuffer.TYPE_BB8)
    -- Dithering auf die 16 Graustufen des E-Ink-Displays.
    out:ditherblitFrom(scaled, 0, 0, ox, oy, W, H)
    scaled:free()
    local ok, err = pcall(out.writePNG, out, dst)
    out:free()
    return ok, err
end

--- Klartext für einen Fehler aus call(): Zahl = HTTP-Status, sonst Meldung.
function M.describe(err)
    if err == 403 then return _("Zugriff verweigert (403)") end
    if err == 401 then return _("Passwort abgelehnt (401)") end
    if type(err) == "number" then return T(_("Antwort %1 vom Server"), err) end
    return tostring(err)
end

-- Merkt sich, wofür die Bilder im Ordner aufbereitet sind. Passt es nicht mehr (andere
-- Bildschirmgröße, andere Drehung), werden alle Bilder neu aufbereitet.
local function resetIfFormatChanged(dir, format)
    local marker = dir .. "/.format"
    local fh = io.open(marker, "r")
    local old = fh and fh:read("*l")
    if fh then fh:close() end
    if old == format then return end
    local files = {}
    for file in lfs.dir(dir) do
        if file:match("%.png$") then table.insert(files, file) end
    end
    for _, file in ipairs(files) do os.remove(dir .. "/" .. file) end
    fh = io.open(marker, "w")
    if fh then fh:write(format, "\n"); fh:close() end
    logger.info("Immich-Galerie: Format", format, "– Bilder werden neu aufbereitet")
end

--- Gleicht den Ordner `dir` mit der Freigabe ab.
--- Ergebnis: Tabelle mit total, added, removed, failed oder nil, Meldung, HTTP-Status.
function M.sync(cfg, dir, W, H)
    local client, ids, code = connect(cfg)
    if not client then return nil, ids, code end
    local rotation = tonumber(cfg.rotation) or 90
    -- Erst nach erfolgreicher Liste, damit ein Netzfehler nie den Bestand leert.
    resetIfFormatChanged(dir, string.format("%dx%d rot%d", W, H, rotation))

    local wanted, added, failed = {}, 0, 0
    for _, id in ipairs(ids) do
        local name = id .. ".png"
        wanted[name] = true
        local dst = dir .. "/" .. name
        if lfs.attributes(dst, "mode") ~= "file" then
            local part, tmp = dir .. "/" .. id .. ".part", dst .. ".tmp"
            local status = client:call("GET", "/assets/" .. id .. "/thumbnail?size=preview", nil, part)
            local ok = status == 200 and M.cropTo(part, tmp, W, H, rotation) and os.rename(tmp, dst)
            os.remove(part)
            os.remove(tmp)
            if ok then
                added = added + 1
            else
                failed = failed + 1
                logger.warn("Immich-Galerie: Bild", id, "nicht übernommen:", M.describe(status))
                if status == 403 then return nil, M.describe(status), status end
            end
        end
    end

    -- Nur nach vollständiger Liste aufräumen: Was nicht mehr in der Freigabe ist, kommt weg.
    local stale = {}
    for file in lfs.dir(dir) do
        if file:match("%.png$") and not wanted[file] then table.insert(stale, file) end
    end
    for _, file in ipairs(stale) do os.remove(dir .. "/" .. file) end

    return { total = #ids, added = added, removed = #stale, failed = failed }
end

return M
