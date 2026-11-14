local ADDON = ...
local K = {}   -- constants (kept in one table: the main chunk is near Lua's 200-local limit)

K.PREFIX = "|cff33ff99FriendsSync|r: "
K.COMM = "FriendsSync"
K.BUILD = "4"
K.PROTO = 1
K.SEP = "~"
K.MAX_MSG = 250
K.BURST, K.RATE = 8, 1            -- send throttle: burst size, messages regained per second
K.HEARTBEAT = 30                 -- always resend status at least this often
K.STATUS_MIN_INTERVAL = 5
K.MOVE_INTERVAL, K.MOVE_YARDS = 10, 25
K.PEER_TIMEOUT = 100
K.HELLO_BASE, K.HELLO_MAX = 60, 600
K.TARGET_REFRESH = 15
K.NEARBY_YARDS, K.NEARBY_COOLDOWN = 150, 300
K.LEVEL_GAP_WARN = 3
K.STEP_SYNC_RANGE = 3
K.NAME_MAX = 90

local DB, peers
local myKey
local targets, targetsShort = {}, {}
local helloNext, helloTries = {}, {}
local sendQueue = {}
local tokens, lastRefill = K.BURST, 0
local recentWhisper = {}
local myQuests, myQuestById = {}, {}
local questSig, questDirtyAt
local guideSig
local statusAt, statusCore, statusX, statusY, statusInst = 0, nil, nil, nil, nil
local lastTargetRefresh = 0
local UI, selectedKey
local RefreshUI
local lastError
local reportedErrors = {}
local UpdateMinimapButton, UpdateFriendsButton, RefreshTracker, ShowPeerMenu
K.MEET_MIN_VERSION = 10300       -- 1.3.0: first version that understands meet-up pins
local newerVersionSeen

-- Settings and their defaults; DB only stores what the player changed.
local DEFAULTS = {
    notify = true, alertOnline = true, alertLevel = true, alertNearby = true, alertGuide = true,
    screenAlerts = false, sound = true, nearbyYards = K.NEARBY_YARDS, acceptMeet = true, versionWarn = true,
    mapDots = true, friendsButton = true, tracker = false, trackerLock = false, levelGap = true, alpha = 1,
    showOffline = true, sort = "name", autoHideDays = 0, hideGreyQuests = true, scale = 1,
}

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(K.PREFIX .. tostring(msg))
end

local function Debug(msg)
    if DB and DB.debug then Print("|cff888888" .. tostring(msg) .. "|r") end
end

local function Opt(key)
    local v = DB and DB[key]
    if v == nil then return DEFAULTS[key] end
    return v
end

local function NearbyYards()
    return tonumber(Opt("nearbyYards")) or K.NEARBY_YARDS
end

local SOUND = {
    Online = SOUNDKIT and SOUNDKIT.UI_BNET_TOAST or 18019,
    Level = SOUNDKIT and SOUNDKIT.UI_PLAYER_LEVEL_UP or 888,
    Nearby = SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081,
    Guide = SOUNDKIT and SOUNDKIT.TELL_MESSAGE or 3081,
    Meet = SOUNDKIT and SOUNDKIT.READY_CHECK or 8960,
}

-- Chat alert of one kind (Online, Level, Nearby, Guide, Meet), optionally on screen and with a sound.
-- force skips the on/off settings, for things a friend sent on purpose.
local function Alert(kind, msg, force)
    if not force and not (Opt("notify") and Opt("alert" .. kind) ~= false) then return end
    Print(msg)
    if Opt("screenAlerts") then
        local text = msg:gsub("|H.-|h(.-)|h", "%1")
        local info = ChatTypeInfo and ChatTypeInfo.RAID_WARNING
        if RaidNotice_AddMessage and RaidWarningFrame and info then
            pcall(RaidNotice_AddMessage, RaidWarningFrame, text, info)
        elseif UIErrorsFrame and UIErrorsFrame.AddMessage then
            UIErrorsFrame:AddMessage(text, 1, 0.82, 0)
        end
    end
    if Opt("sound") and PlaySound and SOUND[kind] then pcall(PlaySound, SOUND[kind], "Master") end
end

-- Clients with secret values (WoW Forever) can hand back values that error on use.
local function Plain(v)
    if issecretvalue and issecretvalue(v) then return nil end
    return v
end

local function SafeCall(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, v = pcall(fn, ...)
    if not ok then return nil end
    return Plain(v)
end

local function XY(v)
    if type(v) ~= "table" then return nil end
    local x, y
    if v.GetXY then
        local ok, a, b = pcall(v.GetXY, v)
        if ok then x, y = a, b end
    else
        x, y = v.x, v.y
    end
    x, y = Plain(x), Plain(y)
    if type(x) ~= "number" or type(y) ~= "number" then return nil end
    return x, y
end

-- Runs fn; an error is reported once (BugSack) instead of stopping the addon.
local function Try(fn, ...)
    local ok, err = pcall(fn, ...)
    if not ok then
        err = tostring(err)
        lastError = err
        if not reportedErrors[err] then
            reportedErrors[err] = true
            local handler = geterrorhandler and geterrorhandler()
            if handler then handler(err) end
        end
    end
    return ok
end

local function Realm()
    local r = SafeCall(GetNormalizedRealmName)
    if type(r) == "string" and r ~= "" then return r end
    return ((SafeCall(GetRealmName) or ""):gsub("[%s%-]", ""))
end

local function FullName(name, realm)
    if not name or name == "" then return nil end
    if name:find("-", 1, true) then return name end
    return name .. "-" .. (realm or Realm())
end

-- Name with a trailing realm/shard removed. On Forever the part after a hyphen can also
-- be a surname ("Jane-Doe"), so only known realms and "...Realm<n>..." shards count.
local function ShortName(name)
    if type(name) ~= "string" then return name end
    local base, suffix = name:match("^(.+)%-([^%-]+)$")
    if base then
        local s, mine = suffix:lower(), Realm():lower()
        if s == mine or s:find("realm%d") then return base end
    end
    return name
end

-- Comparable character identity: "Jane Doe-Realm", "Jane-Doe" and "jane doe" match.
local function CharId(name)
    return (tostring(ShortName(name) or ""):lower():gsub("[%s%-]", ""))
end

-- Forever characters have a first name and a surname (UnitName's second return).
local function PlayerName()
    local name, surname = UnitName("player")
    name, surname = Plain(name), Plain(surname)
    if type(name) ~= "string" or name == "" then return nil end
    if type(surname) == "string" and surname ~= "" then return name .. " " .. surname end
    return name
end

local function Clean(s, maxLen)
    s = (tostring(s or ""):gsub(K.SEP, "-"):gsub("|", "/"))
    if maxLen and #s > maxLen then s = s:sub(1, maxLen) end
    return s
end

local function Split(text)
    local t = {}
    for field in (text .. K.SEP):gmatch("(.-)" .. K.SEP) do
        t[#t + 1] = field
    end
    return t
end

local function Num(v, mult)
    if not v then return "" end
    return tostring(math.floor(v * (mult or 1) + 0.5))
end

local function Ago(seconds)
    if not seconds or seconds < 0 then return "?" end
    if seconds < 60 then return "just now" end
    if seconds < 3600 then return math.floor(seconds / 60) .. "m ago" end
    if seconds < 86400 then return math.floor(seconds / 3600) .. "h ago" end
    return math.floor(seconds / 86400) .. "d ago"
end

local function DisplayName(p)
    return ShortName(p.key)
end

-- Name for whispers, invites and chat links: as the character is called, space included ("Hr Stig").
local function TargetName(p)
    return DisplayName(p)
end

-- Class-colored, clickable [Name] for chat (click to whisper, right-click for menu).
local function ChatName(p)
    local c = p.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[p.class]
    local hex = c and (c.colorStr or ("ff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)) or "ffffffff"
    return ("|Hplayer:%s|h|c%s[%s]|r|h"):format(TargetName(p), hex, DisplayName(p))
end

local function ClassHex(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if not c then return "ffffffff" end
    return c.colorStr or ("ff%02x%02x%02x"):format(c.r * 255, c.g * 255, c.b * 255)
end

local function XPPercent(xp, xpMax)
    if not xp or not xpMax or xpMax <= 0 then return nil end
    return math.floor(xp / xpMax * 100)
end

local function IsActive(p)
    return (p.online and p.lastSeen and GetTime() - p.lastSeen < K.PEER_TIMEOUT) and true or false
end

local function IsHidden(p)
    return (DB and DB.hidden and DB.hidden[p.key]) and true or false
end

local function MyVersion()
    local get = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    local v = SafeCall(get, ADDON, "Version")
    return type(v) == "string" and v ~= "" and v or "?"
end

-- "1.3.0" -> 10300; nil when unknown (friends before 1.3.0 don't send a version).
local function VersionNum(v)
    local a, b, c = tostring(v or ""):match("^v?(%d+)%.(%d+)%.?(%d*)")
    if not a then return nil end
    return tonumber(a) * 10000 + tonumber(b) * 100 + (tonumber(c) or 0)
end

local function CanMeet(p)
    return (VersionNum(p.version) or 0) >= K.MEET_MIN_VERSION
end

local function GetPeer(key)
    local p = peers[key]
    if not p then
        p = { key = key, quests = {} }
        peers[key] = p
    end
    return p
end

local function SetOffline(p)
    p.online, p.announced, p.nearby, p.qbuf = false, nil, nil, nil
end

------------------------------------------------------------------------
-- Friend discovery (WoW friends + Battle.net friends on this game version)
------------------------------------------------------------------------

local function FindTarget(key)
    if not key then return nil end
    local t = targets[key:lower()]
    if t then return t end
    return targetsShort[CharId(key)] or nil
end

local function PeerFor(t)
    if peers[t.key] then return peers[t.key] end
    local short = CharId(t.key)
    for key, p in pairs(peers) do
        if CharId(key) == short then return p end
    end
end

local function RefreshTargets()
    lastTargetRefresh = GetTime()
    local new, short = {}, {}
    local function add(full, route)
        if not full or full == myKey then return end
        local k = full:lower()
        if new[k] then return end
        new[k] = { key = full, route = route }
        local s = CharId(full)
        if short[s] == nil then short[s] = new[k] else short[s] = false end
    end

    -- Battle.net first: it reaches every realm shard, a whisper does not.
    if BNGetNumFriends and C_BattleNet and C_BattleNet.GetFriendAccountInfo and BNSendGameData then
        for i = 1, tonumber(SafeCall(BNGetNumFriends)) or 0 do
            local acc = C_BattleNet.GetFriendAccountInfo(i)
            local gi = type(acc) == "table" and acc.gameAccountInfo
            if type(gi) == "table" and Plain(gi.isOnline) and Plain(gi.gameAccountID)
                and gi.clientProgram == (BNET_CLIENT_WOW or "WoW")
                and (not WOW_PROJECT_ID or gi.wowProjectID == WOW_PROJECT_ID) then
                local char, realm = Plain(gi.characterName), Plain(gi.realmName)
                realm = type(realm) == "string" and (realm:gsub("[%s%-]", "")) or nil
                if realm == "" then realm = nil end
                if type(char) == "string" and char ~= "" then
                    add(FullName(char, realm), { t = "B", id = gi.gameAccountID })
                end
            end
        end
    end

    if C_FriendList and C_FriendList.GetNumFriends then
        for i = 1, tonumber(SafeCall(C_FriendList.GetNumFriends)) or 0 do
            local info = C_FriendList.GetFriendInfoByIndex(i)
            local name = type(info) == "table" and Plain(info.connected) and Plain(info.name)
            if type(name) == "string" and name ~= "" then
                add(FullName(name), { t = "W", n = name })
            end
        end
    end

    -- Friends that just came online get an immediate hello.
    for k in pairs(new) do
        if not targets[k] then helloNext[k], helloTries[k] = nil, nil end
    end
    targets, targetsShort = new, short

    for key, p in pairs(peers) do
        if p.online and not FindTarget(key) then SetOffline(p) end
    end
end

------------------------------------------------------------------------
-- Sending (throttled queue)
------------------------------------------------------------------------

local function RouteId(route)
    return route.t .. ":" .. tostring(route.n or route.id)
end

local function Enqueue(route, tag, text)
    local id = RouteId(route)
    for _, item in ipairs(sendQueue) do
        if item.id == id and item.tag == tag then
            item.text, item.route = text, route
            return
        end
    end
    sendQueue[#sendQueue + 1] = { id = id, tag = tag, route = route, text = text }
end

local function DropQueued(id, tagPrefix)
    for i = #sendQueue, 1, -1 do
        local item = sendQueue[i]
        if item.id == id and (not tagPrefix or item.tag:sub(1, #tagPrefix) == tagPrefix) then
            table.remove(sendQueue, i)
        end
    end
end

local function RouteLabel(route)
    local id = RouteId(route)
    for _, t in pairs(targets) do
        if RouteId(t.route) == id then return id .. " (" .. t.key .. ")" end
    end
    return id
end

local function RawSend(route, text)
    Debug("> " .. RouteLabel(route) .. " " .. text)
    local ok, err
    if route.t == "B" then
        ok, err = pcall(BNSendGameData, route.id, K.COMM, text)
    else
        recentWhisper[route.n:lower()] = GetTime()
        ok, err = pcall(C_ChatInfo.SendAddonMessage, K.COMM, text, "WHISPER", route.n)
    end
    if not ok then
        lastError = tostring(err)
        Debug("send failed: " .. lastError)
    end
end

local function Flush()
    local now = GetTime()
    tokens = math.min(K.BURST, tokens + (now - lastRefill) * K.RATE)
    lastRefill = now
    while tokens >= 1 and #sendQueue > 0 do
        local item = table.remove(sendQueue, 1)
        RawSend(item.route, item.text)
        tokens = tokens - 1
    end
end

------------------------------------------------------------------------
-- Local state (what we share)
------------------------------------------------------------------------

-- Map position plus world coordinates (yards) for distances. World coords come from
-- the map API; UnitPosition is only a fallback since some clients restrict it.
-- wx/wy follow UnitPosition's return order so both sources agree.
local function GetPosition()
    local mapID = C_Map and SafeCall(C_Map.GetBestMapForUnit, "player")
    local mx, my, wx, wy, inst
    if type(mapID) == "number" then
        local pos = SafeCall(C_Map.GetPlayerMapPosition, mapID, "player")
        mx, my = XY(pos)
        if mx and mx <= 0 and my <= 0 then mx, my = nil, nil end
        if mx and C_Map.GetWorldPosFromMapPos then
            local ok, cont, world = pcall(C_Map.GetWorldPosFromMapPos, mapID, pos)
            cont = ok and Plain(cont)
            local a, b = XY(ok and world)
            if type(cont) == "number" and a then wx, wy, inst = a, b, cont end
        end
    else
        mapID = nil
    end
    if not wx and UnitPosition then
        local ok, a, b, _, i = pcall(UnitPosition, "player")
        if ok then
            a, b, i = Plain(a), Plain(b), Plain(i)
            if type(a) == "number" and type(b) == "number" then wx, wy, inst = a, b, i or -1 end
        end
    end
    return mapID, mx, my, wx, wy, inst
end

local function BuildStatus()
    local level = tonumber(Plain(UnitLevel("player"))) or 0
    local xp, xpMax = tonumber(Plain(UnitXP("player"))) or 0, tonumber(Plain(UnitXPMax("player"))) or 0
    local rested = tonumber(SafeCall(GetXPExhaustion)) or 0
    local _, class = UnitClass("player")
    class = Plain(class)
    local mapID, mx, my, wx, wy, inst = GetPosition()
    local zone, sub = Clean(SafeCall(GetRealZoneText), 40), Clean(SafeCall(GetSubZoneText), 40)
    local text = table.concat({ "S", myKey, level, xp, xpMax, rested, type(class) == "string" and class or "", mapID or 0,
        Num(mx, 10000), Num(my, 10000), Num(wx), Num(wy), inst or -1, zone, sub }, K.SEP)
    local core = table.concat({ level, xp, rested, zone, sub }, K.SEP)
    return text, core, wx, wy, inst
end

local function GetGuideInfo()
    local data = _G.RXPCData
    if type(data) ~= "table" then return nil end
    local rxp = _G.RXP
    local guide = type(rxp) == "table" and type(rxp.currentGuide) == "table" and rxp.currentGuide or nil
    local name = guide and guide.name or data.currentGuideName
    if type(name) ~= "string" or name == "" then return nil end
    local group = guide and guide.group or data.currentGuideGroup or ""
    local steps = guide and type(guide.steps) == "table" and #guide.steps or 0
    return group, name, tonumber(data.currentStep) or 0, steps
end

local function GuideKey(group, name)
    return Clean(group, K.NAME_MAX) .. "\n" .. Clean(name, K.NAME_MAX)
end

local function BuildGuide()
    local group, name, step, steps = GetGuideInfo()
    return table.concat({ "G", myKey, Clean(group, K.NAME_MAX), Clean(name, K.NAME_MAX), step or 0, steps or 0 }, K.SEP)
end

local function EncodeQuest(q)
    return ("%d:%d:%d:%d"):format(q.id, q.done, q.total, q.complete and 1 or 0)
end

-- Quest log access: modern C_QuestLog (WoW Forever) with a legacy fallback.
local function NumQuestLogEntries()
    if C_QuestLog and C_QuestLog.GetNumQuestLogEntries then
        return tonumber(SafeCall(C_QuestLog.GetNumQuestLogEntries)) or 0
    end
    return tonumber(SafeCall(GetNumQuestLogEntries)) or 0
end

-- Returns title, questID, isComplete for a quest row (nil for headers/hidden rows).
local function QuestLogEntry(i)
    if C_QuestLog and C_QuestLog.GetInfo then
        local info = C_QuestLog.GetInfo(i)
        if type(info) ~= "table" or Plain(info.isHeader) or Plain(info.isHidden) then return nil end
        local id = Plain(info.questID)
        if type(id) ~= "number" or id <= 0 then return nil end
        local complete = C_QuestLog.IsComplete and SafeCall(C_QuestLog.IsComplete, id)
        return Plain(info.title), id, complete and true or false, tonumber(Plain(info.level))
    end
    if GetQuestLogTitle then
        local title, level, _, isHeader, _, isComplete, _, id = GetQuestLogTitle(i)
        if isHeader or type(id) ~= "number" or id <= 0 then return nil end
        return title, id, isComplete == 1 or isComplete == true, tonumber(Plain(level))
    end
end

-- Returns finished objectives, total objectives.
local function QuestObjectives(i, id)
    local done, total = 0, 0
    if C_QuestLog and C_QuestLog.GetQuestObjectives then
        local list = SafeCall(C_QuestLog.GetQuestObjectives, id)
        if type(list) == "table" then
            for _, o in ipairs(list) do
                total = total + 1
                if type(o) == "table" and Plain(o.finished) then done = done + 1 end
            end
        end
    elseif GetNumQuestLeaderBoards and GetQuestLogLeaderBoard then
        total = tonumber(GetNumQuestLeaderBoards(i)) or 0
        for j = 1, total do
            local _, _, finished = GetQuestLogLeaderBoard(j, i)
            if finished then done = done + 1 end
        end
    end
    return done, total
end

-- Returns true when the quest log changed since the last scan.
local function ScanQuests()
    local list, byId = {}, {}
    for i = 1, NumQuestLogEntries() do
        local title, questID, complete, level = QuestLogEntry(i)
        if questID and not byId[questID] then
            local done, total = QuestObjectives(i, questID)
            local q = { id = questID, title = type(title) == "string" and title or ("Quest #" .. questID),
                done = done, total = total, complete = complete, level = level and level > 0 and math.floor(level) or nil }
            list[#list + 1] = q
            byId[questID] = q
        end
    end
    table.sort(list, function(a, b) return a.id < b.id end)
    local parts = {}
    for i, q in ipairs(list) do parts[i] = EncodeQuest(q) end
    myQuests, myQuestById = list, byId
    local sig = table.concat(parts, ",")
    if sig ~= questSig then
        questSig = sig
        return true
    end
    return false
end

local function QuestMessages()
    local budget = K.MAX_MSG - #table.concat({ "Q", myKey, "99", "99", "" }, K.SEP)
    local chunks, cur = {}, ""
    for _, q in ipairs(myQuests) do
        -- The quest level rides along as a separate "id/level" entry: older versions skip entries they can't parse.
        local e = EncodeQuest(q) .. (q.level and ("," .. q.id .. "/" .. q.level) or "")
        if cur == "" then
            cur = e
        elseif #cur + 1 + #e > budget then
            chunks[#chunks + 1] = cur
            cur = e
        else
            cur = cur .. "," .. e
        end
    end
    chunks[#chunks + 1] = cur
    local msgs = {}
    for i, c in ipairs(chunks) do
        msgs[i] = table.concat({ "Q", myKey, i, #chunks, c }, K.SEP)
    end
    return msgs
end

local function SendQuestsTo(route)
    DropQueued(RouteId(route), "Q")
    for i, msg in ipairs(QuestMessages()) do
        Enqueue(route, "Q" .. i, msg)
    end
end

local function BuildHello(isReply)
    return table.concat({ "H", myKey, K.PROTO, isReply and 1 or 0, Clean(MyVersion(), 20) }, K.SEP)
end

local function SendFullState(route)
    Enqueue(route, "S", (BuildStatus()))
    Enqueue(route, "G", BuildGuide())
    SendQuestsTo(route)
end

local function ForEachActiveRoute(fn)
    for key, p in pairs(peers) do
        if IsActive(p) then
            local t = FindTarget(key)
            if t then fn(t.route) end
        end
    end
end

local function Broadcast(tag, text)
    ForEachActiveRoute(function(route) Enqueue(route, tag, text) end)
end

local function MaybeSendStatus(now, force)
    local text, core, x, y, inst = BuildStatus()
    local moved = x and statusX and (inst ~= statusInst or (x - statusX) ^ 2 + (y - statusY) ^ 2 > K.MOVE_YARDS ^ 2)
    local due = force
        or (core ~= statusCore and now - statusAt >= K.STATUS_MIN_INTERVAL)
        or (moved and now - statusAt >= K.MOVE_INTERVAL)
        or now - statusAt >= K.HEARTBEAT
    if not due then return end
    statusAt, statusCore, statusX, statusY, statusInst = now, core, x, y, inst
    Broadcast("S", text)
end

------------------------------------------------------------------------
-- Comparing with a friend
------------------------------------------------------------------------

local function Distance(p)
    if not p.wx or not p.wy then return nil end
    local _, _, _, x, y, inst = GetPosition()
    if not x or inst ~= p.inst then return nil end
    return math.floor(math.sqrt((x - p.wx) ^ 2 + (y - p.wy) ^ 2) + 0.5)
end

local function CompareQuests(p)
    local shared, theirs, mine, together = {}, {}, {}, 0
    local theirById = {}
    for _, q in ipairs(p.quests or {}) do
        theirById[q.id] = q
        local m = myQuestById[q.id]
        if m then
            shared[#shared + 1] = { id = q.id, me = m, them = q }
            if not m.complete and not q.complete then together = together + 1 end
        else
            theirs[#theirs + 1] = q
        end
    end
    for _, m in ipairs(myQuests) do
        if not theirById[m.id] then mine[#mine + 1] = m end
    end
    return shared, theirs, mine, together
end

local function QuestTitle(id)
    local m = myQuestById[id]
    if m then return m.title end
    if C_QuestLog then
        local t = SafeCall(C_QuestLog.GetTitleForQuestID, id) or SafeCall(C_QuestLog.GetQuestInfo, id)
        if type(t) == "string" and t ~= "" then return t end
    end
    return "Quest #" .. id
end

local function CompletedByMe(id)
    if C_QuestLog and C_QuestLog.IsQuestFlaggedCompleted then
        return SafeCall(C_QuestLog.IsQuestFlaggedCompleted, id) and true or false
    end
    return SafeCall(IsQuestFlaggedCompleted, id) and true or false
end

local function QuestProgress(q)
    if q.complete then return "|cff20ff20done|r" end
    if q.total > 0 then return q.done .. "/" .. q.total end
    return "in progress"
end

-- Returns step difference (their step - mine) when on the same guide, or nil + reason.
local function StepDiff(p)
    if not p.guideName then return nil, "none" end
    local group, name, step = GetGuideInfo()
    if not name then return nil, "nomine" end
    if GuideKey(group, name) ~= GuideKey(p.guideGroup, p.guideName) then return nil, "other" end
    return (p.step or 0) - step
end

local function CheckNearby(p)
    local d = Distance(p)
    if not d then
        p.nearby = nil
        return
    end
    if d <= NearbyYards() then
        if not p.nearby then
            p.nearby = true
            local now = GetTime()
            if not IsHidden(p) and now - (p.nearbyAt or 0) > K.NEARBY_COOLDOWN then
                p.nearbyAt = now
                local _, _, _, together = CompareQuests(p)
                local extra = together > 0 and (" - %s in progress"):format(together == 1 and "1 shared quest" or (together .. " shared quests")) or ""
                Alert("Nearby", ("%s is nearby (%d yd)%s."):format(ChatName(p), d, extra))
            end
        end
    elseif d > NearbyYards() * 1.5 then
        p.nearby = nil
    end
end

------------------------------------------------------------------------
-- Waypoints
------------------------------------------------------------------------

-- TomTom arrow if installed, else the game's map pin. Returns "TomTom", "pin" or nil.
local function SetWaypoint(mapID, x, y, title)
    local tomtom = _G.TomTom
    if type(tomtom) == "table" and tomtom.AddWaypoint then
        tomtom:AddWaypoint(mapID, x, y, { title = title, from = ADDON, persistent = false, crazy = true })
        return "TomTom"
    end
    if C_Map and C_Map.SetUserWaypoint and UiMapPoint and C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(mapID) then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(mapID, x, y))
        if C_SuperTrack and C_SuperTrack.SetSuperTrackedUserWaypoint then pcall(C_SuperTrack.SetSuperTrackedUserWaypoint, true) end
        return "pin"
    end
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

local OnMessage
do
    local function HandleStatus(p, f)
        local oldLevel = p.level
        p.level = tonumber(f[3]) or p.level
        p.xp, p.xpMax, p.rested = tonumber(f[4]), tonumber(f[5]), tonumber(f[6])
        if f[7] and f[7] ~= "" then p.class = f[7] end
        p.mapID = tonumber(f[8])
        if p.mapID == 0 then p.mapID = nil end
        p.mx, p.my = tonumber(f[9]), tonumber(f[10])
        p.wx, p.wy, p.inst = tonumber(f[11]), tonumber(f[12]), tonumber(f[13])
        p.zone, p.subzone = f[14] or "", f[15] or ""

        if not p.announced then
            p.announced = true
            if not IsHidden(p) then
                Alert("Online", ("%s is online - level %s, %s."):format(ChatName(p), p.level or "?",
                    p.zone ~= "" and p.zone or "unknown zone"))
            end
        elseif oldLevel and p.level and p.level > oldLevel and not IsHidden(p) then
            Alert("Level", ("%s |cffffd100reached level %d!|r"):format(ChatName(p), p.level))
        end
        CheckNearby(p)
    end

    local function HandleGuide(p, f)
        local old = p.guideSeen and p.guideName
        if not f[4] or f[4] == "" then
            p.guideGroup, p.guideName, p.step, p.steps = nil, nil, nil, nil
            return
        end
        p.guideGroup, p.guideName = f[3] or "", f[4]
        p.step, p.steps = tonumber(f[5]) or 0, tonumber(f[6]) or 0
        p.guideSeen = true
        if old and old ~= p.guideName and not IsHidden(p) then
            Alert("Guide", ("%s moved on to the guide section |cffffd100%s|r."):format(ChatName(p), p.guideName))
        end
    end

    -- Warns once per session when a friend's FriendsSync is older (some features need both updated) or newer.
    local function CheckVersion(p)
        if p.versionWarned or not Opt("versionWarn") then return end
        local mine, theirs = VersionNum(MyVersion()), VersionNum(p.version)
        if not mine then return end
        p.versionWarned = true
        if theirs and theirs > mine then
            if not newerVersionSeen then
                newerVersionSeen = true
                Print(("%s has FriendsSync %s and you have %s. Update through CurseForge to get the latest features.")
                    :format(ChatName(p), p.version, MyVersion()))
            end
        elseif (theirs or 0) < K.MEET_MIN_VERSION then
            Print(("%s has an older FriendsSync (%s). Ask them to update so you can send each other meet-up pins.")
                :format(ChatName(p), p.version or "before 1.3.0"))
        end
    end

    -- A friend clicked "Meet here": put a waypoint on the spot they sent.
    local function HandleMeet(p, f)
        local mapID, mx, my = tonumber(f[3]), tonumber(f[4]), tonumber(f[5])
        if not (mapID and mx and my) or IsHidden(p) then return end
        local zone = (f[6] and f[6] ~= "") and f[6] or "?"
        if not Opt("acceptMeet") then
            Debug("meet-up pin from " .. p.key .. " ignored (turned off in settings)")
            return
        end
        p.meet = { mapID = mapID, x = mx / 10000, y = my / 10000, zone = zone, at = GetTime() }
        local how = SetWaypoint(mapID, mx / 10000, my / 10000, DisplayName(p) .. "'s meet-up spot")
        Alert("Meet", ("%s wants to meet up at %s (%.1f, %.1f).%s"):format(ChatName(p), zone, mx / 100, my / 100,
            how and " Waypoint set." or ""), true)
    end

    local function HandleQuests(p, f)
        local seq, total = tonumber(f[3]), tonumber(f[4])
        if not seq or not total or seq < 1 or seq > total then return end
        if seq == 1 then p.qbuf = {} end
        if not p.qbuf then return end
        p.qbuf[seq] = f[5] or ""
        if seq < total then return end

        local list, levels = {}, {}
        for i = 1, total do
            local chunk = p.qbuf[i]
            if not chunk then
                p.qbuf = nil
                return
            end
            for entry in chunk:gmatch("[^,]+") do
                local id, d, t, c = entry:match("^(%d+):(%d+):(%d+):(%d)$")
                if id then
                    list[#list + 1] = { id = tonumber(id), done = tonumber(d), total = tonumber(t), complete = c == "1" }
                else
                    local qid, lvl = entry:match("^(%d+)/(%d+)$")
                    if qid then levels[tonumber(qid)] = tonumber(lvl) end
                end
            end
        end
        for _, q in ipairs(list) do q.level = levels[q.id] end
        p.quests, p.qbuf = list, nil
    end

    function OnMessage(text, route)
        Debug("< " .. RouteId(route) .. " " .. text)
        local f = Split(text)
        local kind, key = f[1], f[2]
        if not key or key == "" or key == myKey then return end

        local p = GetPeer(key)
        p.online, p.lastSeen, p.seenAt = true, GetTime(), time()

        if kind == "H" then
            p.proto = tonumber(f[3])
            p.version = (f[5] and f[5] ~= "") and f[5] or nil
            if f[4] ~= "1" then Enqueue(route, "H", BuildHello(true)) end
            SendFullState(route)
            CheckVersion(p)
        elseif kind == "S" then
            HandleStatus(p, f)
        elseif kind == "G" then
            HandleGuide(p, f)
        elseif kind == "Q" then
            HandleQuests(p, f)
        elseif kind == "M" then
            HandleMeet(p, f)
        end
        if RefreshUI then RefreshUI() end
        if RefreshTracker then RefreshTracker() end
    end
end

local function MessageKey(text)
    return text:match("^%a" .. K.SEP .. "([^" .. K.SEP .. "]+)")
end

local function OnWhisperAddon(text, sender)
    local key = MessageKey(text)
    if not key or CharId(key) ~= CharId(sender) then
        Debug("ignored: sender " .. sender .. " does not match " .. tostring(key))
        return
    end
    if not FindTarget(key) and not FindTarget(FullName(sender)) then
        RefreshTargets()
        if not FindTarget(key) and not FindTarget(FullName(sender)) then
            Debug("ignored non-friend " .. sender)
            return
        end
    end
    OnMessage(text, { t = "W", n = sender })
end

local function OnBNetAddon(text, senderID)
    local key = MessageKey(text)
    if not key then
        Debug("ignored: bad message from B:" .. tostring(senderID))
        return
    end
    if C_BattleNet and C_BattleNet.GetGameAccountInfoByID then
        local gi = SafeCall(C_BattleNet.GetGameAccountInfoByID, senderID)
        local char = type(gi) == "table" and Plain(gi.characterName)
        if type(char) == "string" and char ~= "" and CharId(char) ~= CharId(key) then
            Debug("ignored: B:" .. tostring(senderID) .. " is " .. char .. ", message says " .. key)
            return
        end
    end
    local route = { t = "B", id = senderID }
    local t = FindTarget(key)
    if not t then
        targets[key:lower()] = { key = key, route = route }
    elseif t.route.t == "B" then
        t.route = route
    end
    OnMessage(text, route)
end

------------------------------------------------------------------------
-- Periodic work
------------------------------------------------------------------------

local function SendHellos(now)
    for k, t in pairs(targets) do
        local p = PeerFor(t)
        if not (p and IsActive(p)) and now >= (helloNext[k] or 0) then
            local tries = (helloTries[k] or 0) + 1
            helloTries[k] = tries
            helloNext[k] = now + math.min(K.HELLO_BASE * 2 ^ (tries - 1), K.HELLO_MAX)
            Enqueue(t.route, "H", BuildHello(false))
        end
    end
end

local function Tick()
    local now = GetTime()
    if now - lastTargetRefresh >= K.TARGET_REFRESH then RefreshTargets() end
    SendHellos(now)

    for _, p in pairs(peers) do
        if p.online and not IsActive(p) then SetOffline(p) end
    end

    if questDirtyAt and now - questDirtyAt >= 1 then
        questDirtyAt = nil
        if ScanQuests() then ForEachActiveRoute(SendQuestsTo) end
    end

    local g = BuildGuide()
    if g ~= guideSig then
        guideSig = g
        Broadcast("G", g)
    end

    MaybeSendStatus(now)

    for _, p in pairs(peers) do
        if IsActive(p) then CheckNearby(p) end
    end
    if RefreshUI then RefreshUI() end
    if RefreshTracker then RefreshTracker() end
    if UpdateFriendsButton then UpdateFriendsButton() end
end

------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------

local function InvitePeer(p)
    local name = TargetName(p)
    local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    if invite then invite(name) end
end

-- Sets the whisper target on the chat box directly: "/w Hr Stig " would whisper "Hr" the text "Stig".
local function OpenWhisper(name)
    local U = ChatFrameUtil or {}
    local choose = U.ChooseBoxForSend or ChatEdit_ChooseBoxForSend
    local activate = U.ActivateChat or ChatEdit_ActivateChat
    local box = choose and choose()
    if not (box and activate and box.SetAttribute) then return false end
    activate(box)
    box:SetAttribute("chatType", "WHISPER")
    box:SetAttribute("tellTarget", name)
    if box.SetText then box:SetText("") end
    local header = U.UpdateHeader or ChatEdit_UpdateHeader
    if box.UpdateHeader then box:UpdateHeader() elseif header then header(box) end
    return true
end

local function WhisperPeer(p)
    local name = TargetName(p)
    local ok, done = pcall(OpenWhisper, name)
    if ok and done then return end
    local text = "/w " .. name .. " "
    if ChatFrame_OpenChat then
        ChatFrame_OpenChat(text)
    elseif ChatFrameUtil and ChatFrameUtil.OpenChat then
        ChatFrameUtil.OpenChat(text)
    elseif ChatFrameUtil and ChatFrameUtil.ChooseBoxForSend and ChatFrameUtil.ActivateChat then
        local box = ChatFrameUtil.ChooseBoxForSend()
        ChatFrameUtil.ActivateChat(box)
        box:SetText(text)
    end
end

-- Clicking a quest in the window: link it in chat (party chat when grouped with that friend), or share it.
local QuestClick, QuestEnter
do
    local function QuestLink(id, level)
        local title = QuestTitle(id):gsub("[%[%]|]", "")
        return ("|cffffff00|Hquest:%d:%d|h[%s]|h|r"):format(id, tonumber(level) or -1, title)
    end

    local function GroupedWith(p)
        if not (IsInGroup and IsInGroup()) or not UnitInParty then return false end
        return (UnitInParty(TargetName(p)) or UnitInParty(p.key)) and true or false
    end

    local function GroupChat() return (IsInRaid and IsInRaid()) and "RAID" or "PARTY" end

    local function ActiveChatBox()
        local get = (ChatFrameUtil and ChatFrameUtil.GetActiveWindow) or ChatEdit_GetActiveWindow
        return get and get()
    end

    -- Opens the chat box on a channel with text ready to send; returns false if the box can't be reached.
    local function OpenChatWith(chatType, text)
        local U = ChatFrameUtil or {}
        local choose = U.ChooseBoxForSend or ChatEdit_ChooseBoxForSend
        local activate = U.ActivateChat or ChatEdit_ActivateChat
        local box = choose and choose()
        if not (box and activate and box.SetAttribute) then return false end
        activate(box)
        if chatType then box:SetAttribute("chatType", chatType) end
        if box.SetText then box:SetText(text) end
        local header = U.UpdateHeader or ChatEdit_UpdateHeader
        if box.UpdateHeader then box:UpdateHeader() elseif header then header(box) end
        return true
    end

    local function LogIndex(id)
        for i = 1, NumQuestLogEntries() do
            local _, qid = QuestLogEntry(i)
            if qid == id then return i end
        end
    end

    local function ShareQuest(q)
        if not (IsInGroup and IsInGroup()) then
            Print("Join a group to share quests.")
            return
        end
        local i = LogIndex(q.id)
        if not (i and QuestLogPushQuest) then
            Print("You can only share quests that are in your quest log.")
            return
        end
        if C_QuestLog and C_QuestLog.SetSelectedQuest then
            C_QuestLog.SetSelectedQuest(q.id)
        elseif SelectQuestLogEntry then
            SelectQuestLogEntry(i)
        end
        QuestLogPushQuest()
    end

    function QuestClick(p, q, button)
        if button == "RightButton" then return ShareQuest(q) end
        local link = QuestLink(q.id, q.level)
        local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
        if ActiveChatBox() and insert and insert(link) then return end
        local grouped = GroupedWith(p)
        local ok, done = pcall(OpenChatWith, grouped and GroupChat() or nil, link .. " ")
        if ok and done then return end
        local text = (grouped and "/p " or "") .. link .. " "
        if ChatFrame_OpenChat then ChatFrame_OpenChat(text) elseif ChatFrameUtil and ChatFrameUtil.OpenChat then ChatFrameUtil.OpenChat(text) end
    end

    function QuestEnter(owner, p, q)
        if not GameTooltip then return end
        GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
        if not pcall(GameTooltip.SetHyperlink, GameTooltip, QuestLink(q.id, q.level)) then
            GameTooltip:AddLine(QuestTitle(q.id), 1, 0.82, 0)
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(GroupedWith(p) and "Click: link it in party chat" or "Click: link it in chat", 0.5, 0.5, 0.5)
        if q.mine then GameTooltip:AddLine("Right-click: share the quest with your group", 0.5, 0.5, 0.5) end
        GameTooltip:Show()
    end
end

local function WaypointPeer(p)
    if not (p.mapID and p.mx and p.my) then
        Print("No map position known for " .. DisplayName(p) .. ".")
        return
    end
    local x, y = p.mx / 10000, p.my / 10000
    local how = SetWaypoint(p.mapID, x, y, DisplayName(p))
    if how == "TomTom" then
        Print(("Waypoint set to %s (%.1f, %.1f)."):format(DisplayName(p), x * 100, y * 100))
    elseif how then
        Print(("Map pin set to %s (%.1f, %.1f)."):format(DisplayName(p), x * 100, y * 100))
    else
        Print(("%s is at %.1f, %.1f in %s."):format(DisplayName(p), x * 100, y * 100, p.zone or "?"))
    end
end

-- Sends your current spot to a friend; their FriendsSync puts a waypoint on it.
local function SendMeet(p)
    local t = FindTarget(p.key)
    if not (t and IsActive(p)) then
        Print(DisplayName(p) .. " is not online.")
        return
    end
    if not CanMeet(p) then
        Print(("%s needs FriendsSync 1.3.0 or newer for meet-up pins."):format(DisplayName(p)))
        return
    end
    local mapID, mx, my = GetPosition()
    if not (mapID and mx) then
        Print("Your position isn't available here.")
        return
    end
    local zone = Clean(SafeCall(GetRealZoneText), 40)
    Enqueue(t.route, "M", table.concat({ "M", myKey, mapID, Num(mx, 10000), Num(my, 10000), zone }, K.SEP))
    Print(("Sent %s a meet-up pin at your position (%.1f, %.1f)."):format(ChatName(p), mx * 100, my * 100))
end

local function SetHidden(p, hidden)
    DB.hidden = DB.hidden or {}
    DB.hidden[p.key] = hidden and true or nil
    if hidden and selectedKey == p.key then selectedKey = nil end
    Print(("%s is %s."):format(DisplayName(p), hidden and "hidden from FriendsSync. Unhide in Settings" or "shown again"))
    if RefreshUI then RefreshUI() end
    if RefreshTracker then RefreshTracker() end
end

local function MatchStep(p)
    local rxp = _G.RXP
    if type(rxp) ~= "table" or type(rxp.SetStep) ~= "function" then
        Print("RestedXP is not loaded.")
        return
    end
    if not p or not p.guideName then return end
    local ok, err = pcall(function()
        local group, name = GetGuideInfo()
        if not name or GuideKey(group, name) ~= GuideKey(p.guideGroup, p.guideName) then
            local guide = rxp.GetGuideTable and rxp.GetGuideTable(p.guideGroup, p.guideName)
            if not guide then error("you don't have the guide \"" .. p.guideName .. "\"", 0) end
            rxp:LoadGuide(guide)
        end
        local cur = rxp.currentGuide
        local maxStep = cur and type(cur.steps) == "table" and #cur.steps or 1
        rxp.SetStep(math.max(1, math.min(p.step or 1, maxStep)))
    end)
    if ok then
        Print(("Matched %s: %s, step %d."):format(DisplayName(p), p.guideName, p.step or 1))
    else
        Print("Could not match step: " .. tostring(err))
    end
end

StaticPopupDialogs["FRIENDSSYNC_MATCH"] = {
    text = "Switch your RestedXP guide to %s's current step?\n\n%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(_, key) MatchStep(peers[key]) end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function PingFriends()
    wipe(helloNext)
    wipe(helloTries)
    RefreshTargets()
    local n = 0
    for _ in pairs(targets) do n = n + 1 end
    SendHellos(GetTime())
    ForEachActiveRoute(SendFullState)
    Print(("Pinging %d online friend%s."):format(n, n == 1 and "" or "s"))
end

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------

K.WIN_W, K.WIN_H = 660, 540
K.LIST_W = 230
K.CARD_H, K.CARDS = 46, 9
K.BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"
K.ICON = "Interface\\AddOns\\FriendsSync\\Icon"
local GOLD, GREY, GREEN, WHITE = "|cffffd100", "|cff888888", "|cff40ff40", "|cffffffff"

local function Plural(n, word)
    return n .. " " .. word .. (n == 1 and "" or "s")
end

local function ClassName(class)
    return class and (LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[class] or class) or nil
end

local function SetClassIcon(tex, class, dim)
    local c = class and type(CLASS_ICON_TCOORDS) == "table" and CLASS_ICON_TCOORDS[class]
    if c then
        tex:SetTexture("Interface\\TargetingFrame\\UI-Classes-Circles")
        tex:SetTexCoord(c[1], c[2], c[3], c[4])
    else
        tex:SetTexture("Interface\\Icons\\INV_Misc_QuestionMark")
        tex:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    end
    tex:SetDesaturated(dim and true or false)
    tex:SetAlpha(dim and 0.6 or 1)
end

local function ColoredName(p)
    if not IsActive(p) then return GREY .. DisplayName(p) .. "|r" end
    return "|c" .. ClassHex(p.class) .. DisplayName(p) .. "|r"
end

-- Plain-language guide position compared with yours ("In sync", "10 steps ahead").
local function StepLabel(p, short)
    local diff, why = StepDiff(p)
    if diff then
        local n = math.abs(diff)
        if n <= K.STEP_SYNC_RANGE then return GREEN .. "In sync|r" end
        local what = short and tostring(n) or Plural(n, "step")
        if diff > 0 then return "|cffff9933" .. what .. " ahead|r" end
        return "|cff66bbff" .. what .. " behind|r"
    end
    if why == "other" then return GREY .. "Other guide|r" end
    return ""
end

-- Who's ahead at a glance: "+2" levels, or "+12%" XP on the same level ("=" when even).
-- Returns the short coloured badge and a sentence for tooltips.
local function LevelGap(p)
    local myLevel = tonumber(Plain(UnitLevel("player")))
    if not (p.level and myLevel) then return "", nil end
    local gap = p.level - myLevel
    if gap ~= 0 then
        return (gap > 0 and "|cffff9933+" or "|cff66bbff") .. gap .. "|r",
            ("%s %s you"):format(Plural(math.abs(gap), "level"), gap > 0 and "ahead of" or "behind")
    end
    local mine = XPPercent(tonumber(Plain(UnitXP("player"))), tonumber(Plain(UnitXPMax("player"))))
    local theirs = XPPercent(p.xp, p.xpMax)
    if not (mine and theirs) then return "", nil end
    local d = theirs - mine
    if math.abs(d) < 5 then return GREEN .. "=|r", "Same level and about the same XP as you" end
    return (d > 0 and "|cffff9933+" or "|cff66bbff") .. d .. "%|r",
        ("Same level, %d%% XP %s you"):format(math.abs(d), d > 0 and "ahead of" or "behind")
end

-- "CAMWOWEU5Realm8PvP" -> "EU5 Realm 8 PvP"; nil on your own realm.
local function RealmLabel(p)
    local realm = p.key:match("%-([^%-]+)$")
    if not realm or realm == Realm() then return nil end
    local region, n, kind = realm:match("(%a%a%d+)Realm(%d+)(%a*)$")
    if region then return ("%s Realm %s%s"):format(region, n, kind ~= "" and (" " .. kind) or "") end
    return realm
end

local function LevelText(level, xp, xpMax, rested)
    if not level then return "?" end
    local s = tostring(level)
    local pct = XPPercent(xp, xpMax)
    if pct then s = s .. " (" .. pct .. "%)" end
    if rested and rested > 0 then s = s .. " rested" end
    return s
end

local function WhereText(p)
    local zone = p.zone and p.zone ~= "" and p.zone or nil
    local sub = p.subzone and p.subzone ~= "" and p.subzone ~= p.zone and p.subzone or nil
    if zone and sub then return sub .. ", " .. zone end
    return zone or sub or "Unknown zone"
end

local function PickupCount(theirs)
    local n = 0
    for _, q in ipairs(theirs) do
        if not CompletedByMe(q.id) then n = n + 1 end
    end
    return n
end

-- The single most useful thing to do with this friend right now.
local function BestTip(p)
    if not IsActive(p) then
        return ("%s is offline. Last seen %s in %s."):format(DisplayName(p), Ago(p.seenAt and time() - p.seenAt), WhereText(p))
    end
    local _, theirs, _, together = CompareQuests(p)
    local d = Distance(p)
    local diff, why = StepDiff(p)
    local myLevel = tonumber(Plain(UnitLevel("player"))) or 0
    local gap = p.level and (p.level - myLevel)
    if p.meet and GetTime() - p.meet.at < 600 then
        return ("They asked to meet at %s (%.1f, %.1f). Follow the waypoint to find them."):format(p.meet.zone, p.meet.x * 100, p.meet.y * 100)
    end
    if together > 0 and d and d <= NearbyYards() then
        return ("You're close and share %s. Invite them and quest together!"):format(Plural(together, "quest"))
    end
    if diff and diff > K.STEP_SYNC_RANGE then
        return ("They're %s ahead in the guide. Click Match step to jump there, or ask them to wait."):format(Plural(diff, "step"))
    end
    if diff and diff < -K.STEP_SYNC_RANGE then
        return ("You're %s ahead in the guide. Wait for them, or they can match your step."):format(Plural(-diff, "step"))
    end
    if gap and gap >= K.LEVEL_GAP_WARN then
        return ("They're %s ahead of you. Their quests and mobs will be tough for you."):format(Plural(gap, "level"))
    end
    if gap and gap <= -K.LEVEL_GAP_WARN then
        return ("You're %s ahead of them. They may need to catch up first."):format(Plural(-gap, "level"))
    end
    if together > 0 then
        return ("You share %s in progress. Meet up in %s to do them together."):format(Plural(together, "quest"), WhereText(p))
    end
    local pickup = PickupCount(theirs)
    if pickup > 0 then
        return ("They have %s you haven't done. Pick %s up to line up your quest logs."):format(
            Plural(pickup, "quest"), pickup == 1 and "it" or "them")
    end
    if diff then return "You're in sync: same guide step and a similar level." end
    if why == "other" then return "You're on different guide sections. Click Match step to load theirs." end
    return "Your levels are close. Good for questing together."
end

local function QuestSummary(p)
    local shared, theirs, mine = CompareQuests(p)
    if #shared + #theirs + #mine == 0 then return GREY .. "No quests to compare yet.|r" end
    local parts = {}
    if #shared > 0 then parts[#parts + 1] = GREEN .. #shared .. " shared|r" end
    local pickup = PickupCount(theirs)
    if pickup > 0 then parts[#parts + 1] = GOLD .. pickup .. " you could pick up|r" end
    if #mine > 0 then parts[#parts + 1] = WHITE .. #mine .. " only you|r" end
    if #parts == 0 then return GREY .. "Nothing to share right now.|r" end
    return table.concat(parts, GREY .. "  ·  |r")
end

-- Quest list in sections: { id, title, lines = { text, ... }, note }. Quests are coloured by difficulty for you.
local QuestSections
do
    -- Same rule as the game's quest log: how far below you a quest can be before it turns grey.
    local function GreenRange(level)
        local r = SafeCall(GetQuestGreenRange)
        if type(r) == "number" then return r end
        if level <= 5 then return 5 elseif level <= 39 then return math.floor(level / 10) + 5 end
        return math.floor(level / 5) + 1
    end

    local function IsGrey(qlevel)
        local me = tonumber(Plain(UnitLevel("player")))
        return qlevel and me and qlevel < me - GreenRange(me) or false
    end

    local function Colour(qlevel)
        local me = tonumber(Plain(UnitLevel("player")))
        if not (qlevel and me) then return WHITE end
        local d = qlevel - me
        if d >= 5 then return "|cffff2020" elseif d >= 3 then return "|cffff8040" elseif d >= -2 then return "|cffffff00" end
        if IsGrey(qlevel) then return GREY end
        return "|cff40c040"
    end

    local function Title(title, qlevel)
        return Colour(qlevel) .. (qlevel and ("[" .. qlevel .. "] ") or "") .. title .. "|r"
    end

    function QuestSections(p)
        local shared, theirs, mine = CompareQuests(p)
        local out = {}
        local function both(s) return not s.me.complete and not s.them.complete end
        if #shared > 0 then
            table.sort(shared, function(a, b)
                if both(a) ~= both(b) then return both(a) end
                return a.id < b.id
            end)
            local L = {}
            for _, s in ipairs(shared) do
                local lvl = s.me.level or s.them.level
                L[#L + 1] = { id = s.id, level = lvl, mine = true,
                    text = ("%s%s\n    %syou|r %s   %sthem|r %s"):format(Title(QuestTitle(s.id), lvl),
                        both(s) and (GREEN .. "  - do it together|r") or "", GREY, QuestProgress(s.me), GREY, QuestProgress(s.them)) }
            end
            out[#out + 1] = { id = "both", title = "You both have", lines = L }
        end
        local can, done, grey = {}, {}, 0
        for _, q in ipairs(theirs) do
            if CompletedByMe(q.id) then
                done[#done + 1] = { id = q.id, level = q.level, text = GREY .. QuestTitle(q.id) .. "|r" }
            elseif Opt("hideGreyQuests") and IsGrey(q.level) then
                grey = grey + 1
            else
                can[#can + 1] = { id = q.id, level = q.level, text = ("%s  %s"):format(Title(QuestTitle(q.id), q.level), QuestProgress(q)) }
            end
        end
        if #can + grey > 0 then
            out[#out + 1] = { id = "pickup", title = "You could pick up", lines = can, n = #can + grey,
                note = grey > 0 and (GREY .. Plural(grey, "grey quest") .. " hidden (too low for you)|r") or nil }
        end
        if #mine > 0 then
            local L = {}
            for _, q in ipairs(mine) do
                L[#L + 1] = { id = q.id, level = q.level, mine = true, text = ("%s  %s"):format(Title(q.title, q.level), QuestProgress(q)) }
            end
            out[#out + 1] = { id = "mine", title = "Only you have", lines = L }
        end
        if #done > 0 then out[#out + 1] = { id = "done", title = "They have, you already did", lines = done } end
        return out
    end
end

local function MakeButton(parent, text, w, h, tip)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(w, h or 22)
    b:SetText(text)
    if tip then
        b:SetMotionScriptsWhileDisabled(true)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(text, 1, 1, 1)
            GameTooltip:AddLine(type(tip) == "function" and tip() or tip, nil, nil, nil, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
    end
    return b
end

local function SetTitle(frame, text)
    if frame.TitleText then
        frame.TitleText:SetText(text)
    else
        local t = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        t:SetPoint("TOP", 0, -5)
        t:SetText(text)
    end
end

local panels = {}

local function MakePanel(parent)
    local f = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0, 0, 0, 0.45 * ((DB and DB.alpha) or 1))
        f:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
        panels[#panels + 1] = f
    end
    return f
end

-- Fades only the window's backgrounds (frame, inset, title bar and panels); text, borders and buttons stay solid.
local function SetBackgroundAlpha(f, v)
    local function fade(t) if type(t) == "table" and t.SetAlpha then t:SetAlpha(v) end end
    for _, key in ipairs({ "Bg", "TitleBg", "InsetBg" }) do fade(rawget(f, key)) end
    local inset = rawget(f, "Inset")
    for _, frame in ipairs({ f, type(inset) == "table" and inset or nil }) do
        for _, r in ipairs({ frame:GetRegions() }) do
            if type(r) == "table" and r.GetDrawLayer and r.IsObjectType and r:IsObjectType("Texture")
                and r:GetDrawLayer() == "BACKGROUND" then fade(r) end
        end
    end
    for _, p in ipairs(panels) do p:SetBackdropColor(0, 0, 0, 0.45 * v) end
end

local function MakeHeading(parent, text)
    local fs = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    fs:SetText(text)
    local line = parent:CreateTexture(nil, "ARTWORK")
    line:SetHeight(1)
    line:SetColorTexture(1, 0.82, 0, 0.25)
    line:SetPoint("LEFT", fs, "RIGHT", 6, 0)
    line:SetPoint("RIGHT", parent, "RIGHT", -10, 0)
    return fs
end

K.SORTS = { "name", "level", "distance", "seen" }
K.SORT_LABEL = { name = "Name", level = "Level", distance = "Distance", seen = "Last seen" }

local function SortedPeers()
    local list = {}
    local days = tonumber(Opt("autoHideDays")) or 0
    local now = time()
    for _, p in pairs(peers) do
        local stale = days > 0 and not IsActive(p) and p.seenAt and now - p.seenAt > days * 86400
        if not IsHidden(p) and not stale then list[#list + 1] = p end
    end
    local by = K.SORT_LABEL[Opt("sort")] and Opt("sort") or "name"
    local function key(p)
        if by == "level" then return -(p.level or 0) end
        if by == "seen" then return -(p.seenAt or 0) end
        if by == "distance" then return IsActive(p) and Distance(p) or math.huge end
    end
    local keys = {}
    for _, p in ipairs(list) do keys[p] = key(p) or false end
    table.sort(list, function(a, b)
        local ao, bo = IsActive(a), IsActive(b)
        if ao ~= bo then return ao end
        local ka, kb = keys[a], keys[b]
        if ka and kb and ka ~= kb then return ka < kb end
        return DisplayName(a):lower() < DisplayName(b):lower()
    end)
    return list
end

-- Steps the friend list order forward (or back with dir = -1).
local function CycleSort(dir)
    local cur = 1
    for i, s in ipairs(K.SORTS) do if s == Opt("sort") then cur = i end end
    DB.sort = K.SORTS[(cur - 1 + (dir or 1)) % #K.SORTS + 1]
    if RefreshUI then RefreshUI() end
    if RefreshTracker then RefreshTracker() end
end

local function CardTooltip(card)
    local p = card.key and peers[card.key]
    if not p then return end
    GameTooltip:SetOwner(card, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ColoredName(p))
    GameTooltip:AddLine(("Level %s %s"):format(LevelText(p.level, p.xp, p.xpMax, p.rested), ClassName(p.class) or ""), 1, 1, 1)
    local realm = RealmLabel(p)
    if realm then GameTooltip:AddLine(realm, 0.6, 0.6, 0.6) end
    if IsActive(p) then
        local _, gapText = LevelGap(p)
        if gapText then GameTooltip:AddLine(gapText, 1, 0.82, 0) end
        local d = Distance(p)
        GameTooltip:AddLine(WhereText(p) .. (d and ("  (%d yd)"):format(d) or ""), 0.8, 0.8, 0.8)
        if p.guideName then
            GameTooltip:AddLine(("Guide: %s, step %d"):format(p.guideName, p.step or 0), 0.8, 0.8, 0.8)
        end
        local _, _, _, together = CompareQuests(p)
        if together > 0 then GameTooltip:AddLine(Plural(together, "shared quest") .. " in progress", 0.25, 1, 0.25) end
    else
        GameTooltip:AddLine("Offline - last seen " .. Ago(p.seenAt and time() - p.seenAt), 0.6, 0.6, 0.6)
    end
    GameTooltip:AddLine("FriendsSync " .. (p.version or "older than 1.3.0"), 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Click for details, right-click for actions", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function CreateCard(parent, i)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(K.CARD_H - 2)
    c:SetPoint("TOPLEFT", 4, -4 - (i - 1) * K.CARD_H)
    c:SetPoint("RIGHT", parent, "RIGHT", -26, 0)
    c:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    c.sel = c:CreateTexture(nil, "BACKGROUND")
    c.sel:SetAllPoints()
    c.sel:SetColorTexture(0.2, 0.6, 1, 0.25)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(30, 30)
    c.icon:SetPoint("LEFT", 4, 1)
    c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.gap = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.gap:SetPoint("TOPRIGHT", -4, -7)
    c.gap:SetJustifyH("RIGHT")
    c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 6, 0)
    c.name:SetPoint("RIGHT", c.gap, "LEFT", -4, 0)
    c.name:SetJustifyH("LEFT")
    c.name:SetWordWrap(false)
    c.badge = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.badge:SetPoint("TOPRIGHT", -4, -22)
    c.badge:SetJustifyH("RIGHT")
    c.info = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.info:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
    c.info:SetPoint("RIGHT", c.badge, "LEFT", -4, 0)
    c.info:SetJustifyH("LEFT")
    c.info:SetWordWrap(false)
    c.xp = CreateFrame("StatusBar", nil, c)
    c.xp:SetHeight(3)
    c.xp:SetPoint("BOTTOMLEFT", 40, 3)
    c.xp:SetPoint("BOTTOMRIGHT", -4, 3)
    c.xp:SetStatusBarTexture(K.BAR_TEX)
    c.xp:SetStatusBarColor(0.58, 0.0, 0.55)
    local bg = c.xp:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)
    c:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    c.header = false
    c:SetScript("OnClick", function(self, button)
        if self.header then
            DB.offlineCollapsed = not DB.offlineCollapsed or nil
            RefreshUI()
            return
        end
        selectedKey = self.key
        RefreshUI()
        if button == "RightButton" and self.key and peers[self.key] then ShowPeerMenu(self, peers[self.key]) end
    end)
    c:SetScript("OnEnter", CardTooltip)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

local function FillCard(c, p)
    local active = IsActive(p)
    c.key = p.key
    c.header = false
    c.sel:SetShown(p.key == selectedKey)
    c.icon:SetSize(30, 30)
    SetClassIcon(c.icon, p.class, not active)
    c.name:SetText(ColoredName(p))
    if active then
        c.gap:SetText(Opt("levelGap") and LevelGap(p) or "")
        c.info:SetText(("Lv %s  %s%s|r"):format(p.level or "?", GREY, p.zone ~= "" and p.zone or "?"))
        local d = Distance(p)
        if d and d <= NearbyYards() then
            c.badge:SetText(GREEN .. "Nearby|r")
        else
            c.badge:SetText(StepLabel(p, true))
        end
    else
        c.gap:SetText("")
        local bits = {}
        if p.level then bits[#bits + 1] = "Lv " .. p.level end
        if p.zone and p.zone ~= "" then bits[#bits + 1] = p.zone end
        bits[#bits + 1] = Ago(p.seenAt and time() - p.seenAt)
        c.info:SetText(GREY .. table.concat(bits, " · ") .. "|r")
        c.badge:SetText("")
    end
    c.xp:SetMinMaxValues(0, (p.xpMax and p.xpMax > 0) and p.xpMax or 1)
    c.xp:SetValue(p.xp or 0)
    c.xp:SetShown(active)
    c:Show()
end

-- The "Offline (7)" row that folds the offline friends away.
local function FillGroupCard(c, n)
    c.key, c.header = nil, true
    c.sel:Hide()
    c.xp:Hide()
    c.icon:SetSize(14, 14)
    c.icon:SetTexture(DB.offlineCollapsed and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
    c.icon:SetTexCoord(0, 1, 0, 1)
    c.icon:SetDesaturated(false)
    c.icon:SetAlpha(1)
    c.name:SetText(GOLD .. "Offline (" .. n .. ")|r")
    c.info:SetText(GREY .. (DB.offlineCollapsed and "Click to show" or "Click to hide") .. "|r")
    c.gap:SetText("")
    c.badge:SetText("")
    c:Show()
end

local MakeGuideTrack, FillGuideTrack, FillLevelTrack
do
    -- Guide track: one bar for the guide with a "You" marker above and a "Them" marker below.
    -- On different guides it shows two small progress bars instead.
    K.TRACK_W = K.WIN_W - K.LIST_W - 30 - 28

    local function ClassRGB(class)
        local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
        if c then return c.r, c.g, c.b end
        return 1, 1, 1
    end

    local function TrackTexture(t, layer)
        local tex = t:CreateTexture(nil, layer)
        tex:SetTexture(K.BAR_TEX)
        return tex
    end

    function MakeGuideTrack(parent)
        local t = CreateFrame("Frame", nil, parent)
        t:SetSize(K.TRACK_W, 46)
        t.barA = TrackTexture(t, "BACKGROUND")
        t.barB = TrackTexture(t, "BACKGROUND")
        t.fillA = TrackTexture(t, "BORDER")
        t.fillB = TrackTexture(t, "BORDER")
        t.gap = TrackTexture(t, "ARTWORK")
        t.textA = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t.textB = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        t.textA:SetPoint("TOPLEFT", 0, 0)
        t.textB:SetPoint("TOPLEFT", 0, -24)
        for _, k in ipairs({ "me", "them" }) do
            local m = t:CreateTexture(nil, "OVERLAY")
            m:SetSize(3, 16)
            m.label = t:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            t[k] = m
        end
        t.me.up = true
        t.ticks = {}
        return t
    end

    local function Bar(t, tex, y, h, from, width, r, g, b, a)
        tex:ClearAllPoints()
        if width < 0.5 then tex:Hide() return end
        tex:SetPoint("TOPLEFT", from, y)
        tex:SetSize(width, h)
        tex:SetVertexColor(r, g, b, a or 1)
        tex:Show()
    end

    local function Marker(t, m, frac, y, text, r, g, b)
        m:ClearAllPoints()
        m:SetPoint("CENTER", t, "TOPLEFT", frac * t.W, y)
        m:SetColorTexture(r, g, b, 1)
        -- Keep labels inside the track near either end.
        local side = frac < 0.15 and "LEFT" or (frac > 0.85 and "RIGHT" or "")
        m.label:ClearAllPoints()
        if m.up then
            m.label:SetPoint("BOTTOM" .. side, m, "TOP" .. side, 0, 1)
        else
            m.label:SetPoint("TOP" .. side, m, "BOTTOM" .. side, 0, -1)
        end
        m.label:SetText(text)
        m:Show()
        m.label:Show()
    end

    function FillGuideTrack(t, p)
        if not p.guideName then t:Hide() return end
        t:Show()
        local W = tonumber((t:GetWidth())) or 0
        if W < 50 then W = K.TRACK_W end
        t.W = W
        local _, myGuide, myStep, mySteps = GetGuideInfo()
        local diff = StepDiff(p)
        local mine, theirs = myStep or 0, p.step or 0
        local r, g, b = ClassRGB(p.class)
        local who = "|c" .. ClassHex(p.class) .. DisplayName(p) .. "|r"

        if diff then
            local total = math.max(mySteps or 0, p.steps or 0, mine, theirs, 1)
            local a, z = mine / total, theirs / total
            local lo, hi = math.min(a, z), math.max(a, z)
            t.textA:Hide(); t.textB:Hide(); t.barB:Hide(); t.fillB:Hide()
            Bar(t, t.barA, -19, 8, 0, W, 0.15, 0.15, 0.15, 0.9)
            Bar(t, t.fillA, -19, 8, 0, lo * W, 0.45, 0.45, 0.45)
            local gr, gg, gb = 0.25, 0.9, 0.25
            if math.abs(diff) > K.STEP_SYNC_RANGE then
                if diff > 0 then gr, gg, gb = 1, 0.6, 0.2 else gr, gg, gb = 0.4, 0.73, 1 end
            end
            Bar(t, t.gap, -19, 8, lo * W, (hi - lo) * W, gr, gg, gb)
            Marker(t, t.me, a, -23, GOLD .. "You|r " .. GREY .. mine .. "|r", 1, 0.82, 0)
            Marker(t, t.them, z, -23, who .. " " .. GREY .. theirs .. "|r", r, g, b)
        else
            t.gap:Hide(); t.me:Hide(); t.me.label:Hide(); t.them:Hide(); t.them.label:Hide()
            t.textA:SetText(GOLD .. "You:|r " .. (myGuide and (myGuide .. GREY .. "  step " .. mine .. "|r")
                or (GREY .. "no guide loaded|r")))
            t.textB:SetText(who .. ": " .. p.guideName .. GREY .. "  step " .. theirs .. "|r")
            t.textA:Show(); t.textB:Show()
            local myFrac = myGuide and mine / math.max(mySteps or 0, mine, 1) or 0
            local theirFrac = theirs / math.max(p.steps or 0, theirs, 1)
            Bar(t, t.barA, -13, 5, 0, W, 0.15, 0.15, 0.15, 0.9)
            Bar(t, t.fillA, -13, 5, 0, myFrac * W, 1, 0.82, 0)
            Bar(t, t.barB, -37, 5, 0, W, 0.15, 0.15, 0.15, 0.9)
            Bar(t, t.fillB, -37, 5, 0, theirFrac * W, r, g, b)
        end
    end

    -- Level ruler: both of you on one scale from the lower level to the higher one, a tick per level,
    -- the stretch between you coloured like the gap badge and rested XP as a faint blue tail.
    function FillLevelTrack(t, p)
        local myLevel = tonumber(Plain(UnitLevel("player")))
        if not (myLevel and p.level) then t:Hide() return end
        t:Show()
        local W = tonumber((t:GetWidth())) or 0
        if W < 50 then W = K.TRACK_W end
        t.W = W
        local myXP, myMax = tonumber(Plain(UnitXP("player"))) or 0, tonumber(Plain(UnitXPMax("player"))) or 0
        local myRested = tonumber(SafeCall(GetXPExhaustion)) or 0
        local function pos(level, xp, max) return level + ((max or 0) > 0 and math.min(1, (xp or 0) / max) or 0) end
        local a, z = pos(myLevel, myXP, myMax), pos(p.level, p.xp, p.xpMax)
        local from = math.floor(math.min(a, z))
        local to = math.max(from + 1, math.floor(math.max(a, z)) + 1)
        local function frac(v) return (v - from) / (to - from) end
        t.textA:Hide(); t.textB:Hide(); t.barB:Hide()
        Bar(t, t.barA, -19, 8, 0, W, 0.15, 0.15, 0.15, 0.9)
        local lo, hi = math.min(frac(a), frac(z)), math.max(frac(a), frac(z))
        local gr, gg, gb = 0.25, 0.9, 0.25
        if p.level ~= myLevel then
            if z > a then gr, gg, gb = 1, 0.6, 0.2 else gr, gg, gb = 0.4, 0.73, 1 end
        end
        Bar(t, t.gap, -19, 8, lo * W, (hi - lo) * W, gr, gg, gb)
        local rest = myMax > 0 and math.min(frac(a + myRested / myMax), 1) - frac(a) or 0
        Bar(t, t.fillA, -19, 8, frac(a) * W, rest * W, 0.0, 0.39, 0.88, 0.5)
        local theirRest = (p.xpMax or 0) > 0 and math.min(frac(z + (p.rested or 0) / p.xpMax), 1) - frac(z) or 0
        Bar(t, t.fillB, -19, 8, frac(z) * W, theirRest * W, 0.0, 0.39, 0.88, 0.5)
        t.ticks = t.ticks or {}
        local n = (to - from <= 30) and (to - from - 1) or 0
        for i = 1, math.max(n, #t.ticks) do
            local tick = t.ticks[i]
            if i <= n then
                if not tick then
                    tick = t:CreateTexture(nil, "ARTWORK", nil, 1)
                    tick:SetColorTexture(0, 0, 0, 0.7)
                    t.ticks[i] = tick
                end
                tick:ClearAllPoints()
                tick:SetPoint("TOPLEFT", frac(from + i) * W, -19)
                tick:SetSize(1, 8)
                tick:Show()
            elseif tick then
                tick:Hide()
            end
        end
        local function label(name, level, xp, max)
            local pct = XPPercent(xp, max)
            return name .. " " .. WHITE .. level .. "|r" .. (pct and (GREY .. " " .. pct .. "%|r") or "")
        end
        local r, g, b = ClassRGB(p.class)
        Marker(t, t.me, frac(a), -23, label(GOLD .. "You|r", myLevel, myXP, myMax), 1, 0.82, 0)
        Marker(t, t.them, frac(z), -23, label("|c" .. ClassHex(p.class) .. DisplayName(p) .. "|r", p.level, p.xp, p.xpMax), r, g, b)
    end
end

local function CreateDetail(f)
    local d = MakePanel(f)
    d:SetPoint("TOPLEFT", K.LIST_W + 18, -30)
    d:SetPoint("BOTTOMRIGHT", -12, 44)

    d.empty = d:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    d.empty:SetPoint("LEFT", 24, 0)
    d.empty:SetPoint("RIGHT", -24, 0)
    d.empty:SetJustifyH("CENTER")
    d.empty:SetText(GOLD .. "No friends synced yet|r\n\n"
        .. "Friends need FriendsSync installed and must be online on your Battle.net or WoW friends list.\n\n"
        .. GREY .. "Click Refresh to look for them again.|r")

    local c = CreateFrame("Frame", nil, d)
    c:SetAllPoints()
    d.content = c

    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(40, 40)
    c.icon:SetPoint("TOPLEFT", 10, -10)
    c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 8, -2)
    c.name:SetPoint("RIGHT", -10, 0)
    c.name:SetJustifyH("LEFT")
    c.sub = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.sub:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -4)
    c.sub:SetPoint("RIGHT", -10, 0)
    c.sub:SetJustifyH("LEFT")
    c.sub:SetWordWrap(false)
    c.where = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.where:SetPoint("TOPLEFT", c.sub, "BOTTOMLEFT", 0, -3)
    c.where:SetPoint("RIGHT", -10, 0)
    c.where:SetJustifyH("LEFT")
    c.where:SetWordWrap(false)

    local tipBox = CreateFrame("Frame", nil, c, BackdropTemplateMixin and "BackdropTemplate" or nil)
    tipBox:SetPoint("TOPLEFT", 8, -66)
    tipBox:SetPoint("TOPRIGHT", -8, -66)
    tipBox:SetHeight(40)
    if tipBox.SetBackdrop then
        tipBox:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 },
        })
        tipBox:SetBackdropColor(0.35, 0.28, 0.05, 0.35)
        tipBox:SetBackdropBorderColor(1, 0.82, 0, 0.6)
    end
    c.tip = tipBox:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.tip:SetPoint("LEFT", 10, 0)
    c.tip:SetPoint("RIGHT", -10, 0)
    c.tip:SetJustifyH("LEFT")

    local h1 = MakeHeading(c, "Level")
    h1:SetPoint("TOPLEFT", 10, -114)
    c.levelTrack = MakeGuideTrack(c)
    c.levelTrack:SetPoint("TOPLEFT", 14, -130)
    c.levelTrack:SetPoint("RIGHT", -14, 0)

    local h2 = MakeHeading(c, "Guide")
    h2:SetPoint("TOPLEFT", 10, -182)
    c.guide = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.guide:SetPoint("TOPLEFT", 14, -202)
    c.guide:SetPoint("RIGHT", -110, 0)
    c.guide:SetJustifyH("LEFT")
    c.guide:SetWordWrap(false)
    c.track = MakeGuideTrack(c)
    c.track:SetPoint("TOPLEFT", 14, -222)
    c.track:SetPoint("RIGHT", -14, 0)

    -- Quests move up when the guide section is just one line.
    local h3 = MakeHeading(c, "Quests")
    function c.PlaceQuests(withTrack)
        h3:ClearAllPoints()
        h3:SetPoint("TOPLEFT", 10, withTrack and -274 or -224)
    end
    c.PlaceQuests(true)
    c.questSummary = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.questSummary:SetPoint("TOPLEFT", h3, "BOTTOMLEFT", 4, -6)
    c.questSummary:SetPoint("RIGHT", -10, 0)
    c.questSummary:SetJustifyH("LEFT")

    local sf = CreateFrame("ScrollFrame", "FriendsSyncQuestScroll", c, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", c.questSummary, "BOTTOMLEFT", 0, -6)
    sf:SetPoint("BOTTOMRIGHT", -30, 38)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(340, 10)
    sf:SetScrollChild(child)
    c.questChild = child
    c.questScroll = sf
    c.questRows = {}

    return d
end

K.MAX_CARDS = 20
K.MAX_W, K.MAX_H = 1200, 1000
local tracker, PlaceTracker
local settingsViews = {}

local function AskMatch(p)
    if not (p and p.guideName) then return end
    StaticPopup_Show("FRIENDSSYNC_MATCH", DisplayName(p), p.guideName .. " - step " .. (p.step or 1), p.key)
end

local function SetTip(frame, title, text)
    frame:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(type(title) == "function" and title() or title, 1, 1, 1)
        local t = type(text) == "function" and text() or text
        if t then GameTooltip:AddLine(t, nil, nil, nil, true) end
        GameTooltip:Show()
    end)
    frame:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- Rounds to the slider step without float drift (0.05 steps stay exact hundredths).
local function StepRound(v, step)
    if step < 1 then
        local inv = math.floor(1 / step + 0.5)
        return math.floor(v * inv + 0.5) / inv
    end
    return math.floor(v / step + 0.5) * step
end

local function MakeSlider(parent, w, minV, maxV, step, get, set, title, tip)
    local s = CreateFrame("Slider", nil, parent)
    s:SetOrientation("HORIZONTAL")
    s:SetSize(w, 12)
    local track = s:CreateTexture(nil, "BACKGROUND")
    track:SetPoint("LEFT", 0, 0)
    track:SetPoint("RIGHT", 0, 0)
    track:SetHeight(4)
    track:SetColorTexture(0.6, 0.6, 0.6, 0.6)
    s:SetThumbTexture("Interface\\Buttons\\UI-SliderBar-Button-Horizontal")
    local thumb = s:GetThumbTexture()
    if thumb then thumb:SetSize(16, 16) end
    s:SetMinMaxValues(minV, maxV)
    s:SetValueStep(step)
    if s.SetObeyStepOnDrag then s:SetObeyStepOnDrag(true) end
    s.syncing = false
    SetTip(s, title, tip)
    local showTip = s:GetScript("OnEnter")
    s:SetScript("OnValueChanged", function(self, v)
        if self.syncing then return end
        v = math.max(minV, math.min(maxV, StepRound(tonumber(v) or get(), step)))
        set(v)
        if GameTooltip and GameTooltip.IsOwned and GameTooltip:IsOwned(self) and showTip then showTip(self) end
    end)
    s:EnableMouseWheel(true)
    s:SetScript("OnMouseWheel", function(self, delta)
        self:SetValue(math.max(minV, math.min(maxV, StepRound(get() + delta * step, step))))
    end)
    function s.Sync()
        s.syncing = true
        s:SetValue(get())
        s.syncing = false
    end
    s.Sync()
    return s
end

local function RefreshSettings()
    for _, update in ipairs(settingsViews) do update() end
end

local function ApplyAlpha(v)
    DB.alpha = v
    if UI then SetBackgroundAlpha(UI, v) end
    RefreshSettings()
end

local function PlaceWindow(f)
    f:ClearAllPoints()
    local pos, size = DB.winPos, DB.winSize
    if type(pos) == "table" and pos[1] then
        f:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
    else
        f:SetPoint("CENTER")
    end
    if type(size) == "table" and tonumber(size[1]) and tonumber(size[2]) then
        f:SetSize(math.max(K.WIN_W, math.min(K.MAX_W, size[1])), math.max(K.WIN_H, math.min(K.MAX_H, size[2])))
    else
        f:SetSize(K.WIN_W, K.WIN_H)
    end
end

local function SaveWindow(f)
    local point, _, rel, x, y = f:GetPoint(1)
    if type(point) == "string" then DB.winPos = { point, rel or point, tonumber(x) or 0, tonumber(y) or 0 } end
    local w, h = tonumber((f:GetWidth())), tonumber((f:GetHeight()))
    if w and h then DB.winSize = { math.floor(w + 0.5), math.floor(h + 0.5) } end
end

local function HiddenCount()
    local n = 0
    for key in pairs(DB.hidden or {}) do
        if peers[key] then n = n + 1 end
    end
    return n
end

local function ResetPositions()
    DB.winPos, DB.winSize, DB.trackerPos = nil, nil, nil
    if UI then PlaceWindow(UI) end
    if tracker and PlaceTracker then PlaceTracker() end
    if RefreshUI then RefreshUI() end
    Print("Window and tracker positions reset.")
end

-- Everything on the Settings tab (and in the game's AddOns options). col starts a new column.
local function SettingsSpec()
    return {
        { col = 1, head = "Alerts" },
        { key = "notify", label = "Alerts", tip = "Tell me about synced friends: online, level ups, nearby and new guide sections. Turn off to silence them all." },
        { key = "alertOnline", parent = "notify", label = "Friend comes online" },
        { key = "alertLevel", parent = "notify", label = "Friend levels up" },
        { key = "alertNearby", parent = "notify", label = "Friend is nearby" },
        { key = "alertGuide", parent = "notify", label = "Friend starts a new guide section" },
        { key = "screenAlerts", parent = "notify", label = "Also show alerts on screen", tip = "Show alerts in the middle of the screen like a raid warning, not only in chat." },
        { key = "sound", parent = "notify", label = "Play a sound", tip = "Play a short sound with each alert." },
        { slider = "nearbyYards", min = 50, max = 500, step = 25,
          label = function() return ("Nearby distance: %d yd"):format(NearbyYards()) end,
          tip = "How close a friend must be to count as nearby, for the alert, the green Nearby badge and tips." },
        { head = "Meeting up" },
        { key = "acceptMeet", label = "Accept meet-up pins", tip = "When a friend clicks Meet here, put a waypoint on the spot they sent." },
        { key = "versionWarn", label = "Version notices", tip = "Tell me when a friend has a newer or older FriendsSync than me." },
        { head = "Friends list" },
        { key = "showOffline", label = "Show offline friends", tip = "List friends who are offline (under a foldable Offline header), with their last level and zone." },
        { button = function() return "Sort by: " .. (K.SORT_LABEL[Opt("sort")] or "Name") end, title = "Sort by",
          tip = "Click to change the order: name, level, distance or last seen. Online friends always come first.",
          click = function() CycleSort(1) end },
        { slider = "autoHideDays", min = 0, max = 60, step = 5,
          label = function()
              local d = tonumber(Opt("autoHideDays")) or 0
              return d > 0 and ("Hide friends offline over %d days"):format(d) or "Hide long-offline friends: never"
          end,
          tip = "Leave friends out of the list once they haven't been online for this many days. They come back when they log in." },

        { col = 2, head = "Display" },
        { key = "mapDots", label = "Friends on the world map", tip = "Show synced friends as class-coloured dots on the world map." },
        { label = "Minimap button", tip = "Show the FriendsSync button on the minimap.",
          get = function() return not DB.minimapHide end,
          set = function(v) DB.minimapHide = (not v) or nil; Try(UpdateMinimapButton) end },
        { key = "friendsButton", label = "Button above friends button", tip = "A small FriendsSync button above the game's social button, by the chat window. The number is how many synced friends are online.",
          onChange = function() if UpdateFriendsButton then UpdateFriendsButton() end end },
        { key = "tracker", label = "Mini tracker", tip = "A small always-on list of online synced friends: level, gap and distance or guide step.",
          onChange = function() if RefreshTracker then RefreshTracker() end end },
        { key = "trackerLock", parent = "tracker", label = "Lock tracker position" },
        { key = "levelGap", label = "Level gap badge", tip = "Show +2 / -1 next to friends' levels: how far ahead (orange) or behind (blue) they are." },
        { slider = "alpha", min = 0, max = 1, step = 0.05,
          label = function() return ("Background opacity: %d%%"):format(math.floor(Opt("alpha") * 100 + 0.5)) end,
          tip = "Make the window background see-through. Text and buttons stay solid.",
          get = function() return tonumber(Opt("alpha")) or 1 end, set = ApplyAlpha },
        { slider = "scale", min = 0.8, max = 1.3, step = 0.05,
          label = function() return ("Window size: %d%%"):format(math.floor((tonumber(Opt("scale")) or 1) * 100 + 0.5)) end,
          tip = "Make the whole FriendsSync window (and its text) smaller or bigger.",
          apply = function() if UI then UI:SetScale(tonumber(Opt("scale")) or 1) end end },
        { head = "Quests" },
        { key = "hideGreyQuests", label = "Hide grey quests I could pick up", tip = "Leave out quests from their log that are too low level for you to get XP from." },
        { head = "Friends" },
        { button = function() return "Reset positions" end, title = "Reset positions",
          tip = "Move the window and the mini tracker back to the default place and size.", click = ResetPositions },
        { button = function() return ("Unhide friends (%d)"):format(HiddenCount()) end, title = "Unhide friends",
          tip = "Show every friend you hid with the right-click menu again.",
          shown = function() return HiddenCount() > 0 end,
          click = function()
              DB.hidden = {}
              Print("All friends are shown again.")
              if RefreshTracker then RefreshTracker() end
          end },
    }
end

local function OptGet(item)
    if item.get then return item.get() end
    return Opt(item.key or item.slider)
end

local function OptSet(item, v)
    if item.set then item.set(v) else DB[item.key or item.slider] = v end
    if item.onChange then Try(item.onChange) end
    RefreshSettings()
    if RefreshUI then RefreshUI() end
end

local function BuildSettings(parent, x0, y0, colW)
    local ys, col, updaters = { y0, y0 }, 1, {}
    for _, item in ipairs(SettingsSpec()) do
        if item.col then col = item.col end
        local x, y = x0 + (col - 1) * colW, ys[col]
        if item.head then
            if y ~= y0 then y = y - 10 end
            local h = parent:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            h:SetPoint("TOPLEFT", x, y)
            h:SetText(item.head)
            local line = parent:CreateTexture(nil, "ARTWORK")
            line:SetPoint("TOPLEFT", x, y - 16)
            line:SetSize(colW - 24, 1)
            line:SetColorTexture(1, 0.82, 0, 0.25)
            ys[col] = y - 22
        elseif item.slider then
            local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            label:SetPoint("TOPLEFT", x + 4, y - 2)
            local s
            s = MakeSlider(parent, colW - 60, item.min, item.max, item.step,
                function() return tonumber(OptGet(item)) or item.min end,
                function(v)
                    OptSet(item, v)
                    -- Settings that move the window apply once the thumb is let go, so it doesn't run from the mouse.
                    if item.apply and not (s and s.IsDraggingThumb and s:IsDraggingThumb()) then item.apply() end
                end, item.label, item.tip)
            if item.apply then s:SetScript("OnMouseUp", function() item.apply() end) end
            s:SetPoint("TOPLEFT", x + 8, y - 22)
            updaters[#updaters + 1] = function()
                label:SetText(item.label())
                s.Sync()
            end
            ys[col] = y - 42
        elseif item.button then
            local b = MakeButton(parent, item.title, 170, 22, item.tip)
            b:SetPoint("TOPLEFT", x + 4, y - 2)
            b:SetScript("OnClick", function()
                item.click()
                RefreshSettings()
                if RefreshUI then RefreshUI() end
            end)
            updaters[#updaters + 1] = function()
                b:SetText(item.button())
                b:SetEnabled((not item.enabled or item.enabled()) and true or false)
                b:SetShown((not item.shown or item.shown()) and true or false)
            end
            ys[col] = y - 28
        else
            local indent = item.parent and 18 or 0
            local cb = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
            cb:SetSize(24, 24)
            cb:SetPoint("TOPLEFT", x + indent, y)
            local label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            label:SetPoint("LEFT", cb, "RIGHT", 2, 1)
            label:SetText(item.label)
            cb:SetScript("OnClick", function(self) OptSet(item, self:GetChecked() and true or false) end)
            if item.tip then
                cb:SetMotionScriptsWhileDisabled(true)
                SetTip(cb, item.label, item.tip)
            end
            updaters[#updaters + 1] = function()
                cb:SetChecked(OptGet(item) and true or false)
                local on = (not item.parent) or (Opt(item.parent) and true or false)
                cb:SetEnabled(on)
                local c = on and 1 or 0.5
                label:SetTextColor(c, c, c)
            end
            ys[col] = y - 24
        end
    end
    local function update() for _, u in ipairs(updaters) do u() end end
    settingsViews[#settingsViews + 1] = update
    update()
    return math.min(ys[1], ys[2])
end

local function CreateUI()
    local f = CreateFrame("Frame", "FriendsSyncFrame", UIParent, "BasicFrameTemplateWithInset")
    PlaceWindow(f)
    f:SetMovable(true)
    f:SetResizable(true)
    if f.SetResizeBounds then
        f:SetResizeBounds(K.WIN_W, K.WIN_H, K.MAX_W, K.MAX_H)
    elseif f.SetMinResize then
        f:SetMinResize(K.WIN_W, K.WIN_H)
        f:SetMaxResize(K.MAX_W, K.MAX_H)
    end
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SaveWindow(self)
    end)
    f:SetFrameStrata("MEDIUM")
    f:Hide()
    tinsert(UISpecialFrames, f:GetName())
    SetTitle(f, "FriendsSync")

    -- Background opacity: an eye in the title bar, left of the close button; hover it for the slider.
    local eye = CreateFrame("Button", nil, f)
    eye:SetSize(18, 18)
    if type(f.CloseButton) == "table" then
        eye:SetPoint("RIGHT", f.CloseButton, "LEFT", -2, 0)
    else
        eye:SetPoint("TOPRIGHT", -30, -3)
    end
    eye:SetNormalTexture("Interface\\Icons\\INV_Misc_Eye_01")
    local eyeTex = eye:GetNormalTexture()
    if eyeTex then eyeTex:SetTexCoord(0.1, 0.9, 0.1, 0.9) end
    eye:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
    local pop = CreateFrame("Frame", nil, f, BackdropTemplateMixin and "BackdropTemplate" or nil)
    pop:SetSize(150, 46)
    pop:SetPoint("TOPRIGHT", eye, "BOTTOMRIGHT", 4, -2)
    pop:SetFrameStrata("DIALOG")
    pop:EnableMouse(true)
    if pop.SetBackdrop then
        pop:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        pop:SetBackdropColor(0, 0, 0, 0.9)
        pop:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
    end
    local popLabel = pop:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    popLabel:SetPoint("TOPLEFT", 10, -8)
    local alpha = MakeSlider(pop, 126, 0, 1, 0.05, function() return tonumber(Opt("alpha")) or 1 end, ApplyAlpha,
        function() return ("Background opacity: %d%%"):format(math.floor(Opt("alpha") * 100 + 0.5)) end,
        "Drag or scroll to make the window background see-through. Text and buttons stay solid.")
    alpha:SetPoint("TOPLEFT", 12, -26)
    pop:Hide()
    local function syncAlpha()
        alpha.Sync()
        popLabel:SetText(("Background: %d%%"):format(math.floor(Opt("alpha") * 100 + 0.5)))
    end
    syncAlpha()
    settingsViews[#settingsViews + 1] = syncAlpha
    f.alpha, f.alphaPop = alpha, pop
    eye:SetScript("OnEnter", function() pop:Show() end)
    eye:SetScript("OnClick", function() pop:SetShown(not pop:IsShown()) end)
    eye:EnableMouseWheel(true)
    eye:SetScript("OnMouseWheel", function(_, delta) alpha:GetScript("OnMouseWheel")(alpha, delta) end)
    local away = 0
    pop:SetScript("OnUpdate", function(self, elapsed)
        local over = MouseIsOver and (MouseIsOver(self) or MouseIsOver(eye))
        if over or (alpha.IsDraggingThumb and alpha:IsDraggingThumb()) then
            away = 0
        else
            away = away + (elapsed or 0)
            if away > 0.4 then away = 0; self:Hide() end
        end
    end)
    f:SetScale(tonumber(Opt("scale")) or 1)

    local grip = CreateFrame("Button", nil, f)
    grip:SetSize(16, 16)
    grip:SetPoint("BOTTOMRIGHT", -4, 4)
    grip:SetFrameLevel((tonumber((f:GetFrameLevel())) or 1) + 10)
    grip:SetNormalTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    grip:SetHighlightTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Highlight")
    grip:SetPushedTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Down")
    grip:SetScript("OnMouseDown", function() f:StartSizing("BOTTOMRIGHT") end)
    grip:SetScript("OnMouseUp", function()
        f:StopMovingOrSizing()
        SaveWindow(f)
        RefreshUI()
    end)
    f:SetScript("OnSizeChanged", function() if RefreshUI then RefreshUI() end end)

    -- Pages and tabs
    local page = CreateFrame("Frame", nil, f)
    page:SetAllPoints()
    f.friendsPage = page
    local settingsPage = CreateFrame("Frame", nil, f)
    settingsPage:SetAllPoints()
    f.settingsPage = settingsPage

    f.Tabs, f.numTabs, f.tab = {}, 2, 1
    local function SelectTab(id)
        f.tab = id
        page:SetShown(id == 1)
        settingsPage:SetShown(id == 2)
        if PanelTemplates_SetTab then
            pcall(PanelTemplates_SetTab, f, id)
        else
            for i, t in ipairs(f.Tabs) do t:SetEnabled(i ~= id) end
        end
        if id == 2 then RefreshSettings() else RefreshUI() end
    end
    f.SelectTab = SelectTab
    for i, text in ipairs({ "Friends", "Settings" }) do
        local ok, tab = pcall(CreateFrame, "Button", "FriendsSyncFrameTab" .. i, f, "PanelTabButtonTemplate")
        if not (ok and tab) then
            tab = CreateFrame("Button", "FriendsSyncFrameTab" .. i, f, "UIPanelButtonTemplate")
            tab:SetSize(90, 22)
        end
        tab:SetID(i)
        tab:SetText(text)
        if PanelTemplates_TabResize then pcall(PanelTemplates_TabResize, tab, 0) end
        if i == 1 then
            tab:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 12, 2)
        else
            tab:SetPoint("TOPLEFT", f.Tabs[i - 1], "TOPRIGHT", 3, 0)
        end
        tab:SetScript("OnClick", function() SelectTab(i) end)
        f.Tabs[i] = tab
    end

    -- Friends page, left: friend cards
    local listHead = page:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listHead:SetPoint("TOPLEFT", 16, -32)
    listHead:SetText("Friends")
    f.onlineCount = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.onlineCount:SetPoint("TOPRIGHT", page, "TOPLEFT", K.LIST_W + 10, -34)

    local sort = CreateFrame("Button", nil, page)
    sort:SetSize(96, 16)
    sort:SetPoint("LEFT", listHead, "RIGHT", 10, 0)
    sort.text = sort:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sort.text:SetPoint("LEFT")
    sort:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    sort:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    sort:SetScript("OnClick", function(self, button)
        CycleSort(button == "RightButton" and -1 or 1)
        RefreshSettings()
    end)
    SetTip(sort, "Sort friends", "Click to change the order: name, level, distance or last seen. Right-click goes back. Online friends always come first.")
    f.sort = sort

    local list = MakePanel(page)
    list:SetPoint("TOPLEFT", 12, -50)
    list:SetPoint("BOTTOMLEFT", 12, 44)
    list:SetWidth(K.LIST_W)
    f.list = list

    local scroll = CreateFrame("ScrollFrame", "FriendsSyncListScroll", list, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -26, 4)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, K.CARD_H, RefreshUI)
    end)
    f.scroll = scroll
    f.cards = {}
    for i = 1, K.CARDS do f.cards[i] = CreateCard(list, i) end

    -- Friends page, right: details for the selected friend
    f.detail = CreateDetail(page)
    local c = f.detail.content
    local function selected() return selectedKey and peers[selectedKey] end

    local function offline()
        local p = selected()
        return p and not IsActive(p) and "They're offline right now." or nil
    end

    f.invite = MakeButton(c, "Invite", 88, 22, function() return offline() or "Invite them to a group." end)
    f.invite:SetPoint("BOTTOMLEFT", 10, 10)
    f.invite:SetScript("OnClick", function() local p = selected(); if p then InvitePeer(p) end end)

    f.whisper = MakeButton(c, "Whisper", 88, 22, function() return offline() or "Start a whisper to them in chat." end)
    f.whisper:SetPoint("LEFT", f.invite, "RIGHT", 4, 0)
    f.whisper:SetScript("OnClick", function() local p = selected(); if p then WhisperPeer(p) end end)

    f.waypoint = MakeButton(c, "Waypoint", 88, 22, function()
        local p = selected()
        if offline() then return offline() end
        if p and not (p.mapID and p.mx) then
            return "Their map position isn't known right now - they may be in a dungeon, or somewhere without a zone map."
        end
        return "Put a map pin (or TomTom arrow) on their position."
    end)
    f.waypoint:SetPoint("LEFT", f.whisper, "RIGHT", 4, 0)
    f.waypoint:SetScript("OnClick", function() local p = selected(); if p then WaypointPeer(p) end end)

    f.meet = MakeButton(c, "Meet here", 88, 22, function()
        local p = selected()
        if offline() then return offline() end
        if p and not CanMeet(p) then
            return ("%s needs FriendsSync 1.3.0 or newer to get meet-up pins."):format(DisplayName(p))
        end
        return "Send them a pin on your position. Their FriendsSync puts a waypoint on it, so they can find you."
    end)
    f.meet:SetPoint("LEFT", f.waypoint, "RIGHT", 4, 0)
    f.meet:SetScript("OnClick", function() local p = selected(); if p then SendMeet(p) end end)

    f.match = MakeButton(c, "Match step", 96, 20, function()
        local p = selected()
        if type(_G.RXP) ~= "table" then return "RestedXP isn't loaded, so there's no guide to switch." end
        local diff = p and StepDiff(p)
        if diff and math.abs(diff) <= K.STEP_SYNC_RANGE then return "You're already in sync with them." end
        return "Switch your RestedXP guide to the same guide and step they are on."
    end)
    f.match:SetPoint("TOPRIGHT", -10, -198)
    f.match:SetScript("OnClick", function() AskMatch(selected()) end)

    f.status = page:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.status:SetPoint("BOTTOMLEFT", 16, 18)

    local ping = MakeButton(page, "Refresh", 90, 22,
        "Look for online friends with FriendsSync now, instead of waiting for the next automatic check.")
    ping:SetPoint("BOTTOMRIGHT", -24, 12)
    ping:SetScript("OnClick", PingFriends)

    -- Settings page
    local box = MakePanel(settingsPage)
    box:SetPoint("TOPLEFT", 12, -30)
    box:SetPoint("BOTTOMRIGHT", -12, 24)
    BuildSettings(box, 16, -14, 310)
    local note = box:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    note:SetPoint("BOTTOMLEFT", 16, 12)
    note:SetPoint("RIGHT", -16, 0)
    note:SetJustifyH("LEFT")
    note:SetText("Tip: right-click a friend for quick actions. /fsync settings opens this tab.")

    SetBackgroundAlpha(f, tonumber(Opt("alpha")) or 1)
    SelectTab(1)
    f:SetScript("OnShow", function() if f.tab == 2 then RefreshSettings() else RefreshUI() end end)
    return f
end

local function FillDetail(p)
    local d = UI.detail
    d.empty:SetShown(not p)
    d.content:SetShown(p and true or false)
    if not p then return end
    local c = d.content
    local active = IsActive(p)

    SetClassIcon(c.icon, p.class, not active)
    c.name:SetText(ColoredName(p))
    local bits = { ("Level %s %s"):format(p.level or "?", ClassName(p.class) or "") }
    if active then
        bits[#bits + 1] = GREEN .. "Online|r"
        local dist = Distance(p)
        if dist then bits[#bits + 1] = ("%d yd away"):format(dist) end
        c.where:SetText(WhereText(p))
    else
        bits[#bits + 1] = GREY .. "Offline, seen " .. Ago(p.seenAt and time() - p.seenAt) .. "|r"
        c.where:SetText(GREY .. "Last seen in " .. WhereText(p) .. "|r")
    end
    local realm = RealmLabel(p)
    if realm then bits[#bits + 1] = GREY .. realm .. "|r" end
    c.sub:SetText(table.concat(bits, GREY .. "  ·  |r"))
    c.tip:SetText(GOLD .. "Tip:|r " .. BestTip(p))

    FillLevelTrack(c.levelTrack, p)

    local diff, why = StepDiff(p)
    if p.guideName then
        if diff then
            c.guide:SetText(WHITE .. p.guideName .. "|r   " .. StepLabel(p))
        else
            c.guide:SetText(GOLD .. "Different guides|r" .. GREY .. (why == "other" and "  - Match step loads theirs" or "") .. "|r")
        end
    else
        c.guide:SetText(GREY .. "They aren't using a RestedXP guide.|r")
    end
    FillGuideTrack(c.track, p)
    c.PlaceQuests(p.guideName and true or false)
    UI.match:SetShown(p.guideName and true or false)

    -- Quest sections; click a header to fold it.
    local qw = tonumber((c.questScroll:GetWidth()))
    if not (qw and qw > 50) then qw = 340 end
    c.questChild:SetWidth(qw)
    c.questSummary:SetText(QuestSummary(p))
    DB.questFolded = DB.questFolded or {}
    local y = 0
    local sections = QuestSections(p)
    for i, s in ipairs(sections) do
        local row = c.questRows[i]
        if not row then
            row = CreateFrame("Button", nil, c.questChild)
            row:SetHeight(16)
            row.icon = row:CreateTexture(nil, "ARTWORK")
            row.icon:SetSize(12, 12)
            row.icon:SetPoint("LEFT", 0, 0)
            row.text = row:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
            row.text:SetPoint("LEFT", row.icon, "RIGHT", 4, 0)
            row:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            row.lines = {}
            row:SetScript("OnClick", function(self)
                DB.questFolded[self.id] = not DB.questFolded[self.id] or nil
                RefreshUI()
            end)
            c.questRows[i] = row
        end
        local folded = DB.questFolded[s.id] and true or false
        row.id = s.id
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", 0, -y)
        row:SetWidth(qw)
        row.icon:SetTexture(folded and "Interface\\Buttons\\UI-PlusButton-Up" or "Interface\\Buttons\\UI-MinusButton-Up")
        row.text:SetText(("%s (%d)"):format(s.title, s.n or #s.lines))
        row:Show()
        y = y + 18
        local entries = {}
        if not folded then
            for _, l in ipairs(s.lines) do entries[#entries + 1] = l end
            if s.note then entries[#entries + 1] = { text = s.note } end
        end
        for j, e in ipairs(entries) do
            local line = row.lines[j]
            if not line then
                line = CreateFrame("Button", nil, c.questChild)
                line.text = line:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
                line.text:SetPoint("TOPLEFT")
                line.text:SetJustifyH("LEFT")
                line.text:SetJustifyV("TOP")
                line:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
                line:RegisterForClicks("LeftButtonUp", "RightButtonUp")
                line:SetScript("OnClick", function(self, button)
                    local fp = selectedKey and peers[selectedKey]
                    if self.quest and fp then QuestClick(fp, self.quest, button) end
                end)
                line:SetScript("OnEnter", function(self)
                    local fp = selectedKey and peers[selectedKey]
                    if self.quest and fp then QuestEnter(self, fp, self.quest) end
                end)
                line:SetScript("OnLeave", function() if GameTooltip then GameTooltip:Hide() end end)
                row.lines[j] = line
            end
            line.quest = e.id and e or false
            line:EnableMouse(e.id and true or false)
            line:ClearAllPoints()
            line:SetPoint("TOPLEFT", 16, -y)
            line.text:SetWidth(qw - 16)
            line.text:SetText(e.text)
            local lh = tonumber((line.text:GetStringHeight())) or 12
            line:SetSize(qw - 16, lh)
            line:Show()
            y = y + lh + 2
        end
        for j = #entries + 1, #row.lines do row.lines[j]:Hide() end
        if #entries > 0 then y = y + 4 end
    end
    for i = #sections + 1, #c.questRows do
        local row = c.questRows[i]
        row:Hide()
        for _, line in ipairs(row.lines) do line:Hide() end
    end
    c.questChild:SetHeight(math.max(10, y))

    UI.invite:SetEnabled(active)
    UI.whisper:SetEnabled(active)
    UI.waypoint:SetEnabled((active and p.mapID and p.mx) and true or false)
    UI.meet:SetEnabled((active and CanMeet(p)) and true or false)
    local canMatch = p.guideName and type(_G.RXP) == "table" and not (diff and math.abs(diff) <= K.STEP_SYNC_RANGE)
    UI.match:SetEnabled(canMatch and true or false)
end

function RefreshUI()
    if not UI or not UI:IsShown() then return end

    local list = SortedPeers()
    local sel = selectedKey and peers[selectedKey]
    if not sel or IsHidden(sel) then selectedKey = nil end
    if not selectedKey and list[1] then selectedKey = list[1].key end

    local online = 0
    local rows, offline = {}, {}
    for _, p in ipairs(list) do
        if IsActive(p) then
            online = online + 1
            rows[#rows + 1] = p
        elseif Opt("showOffline") then
            offline[#offline + 1] = p
        end
    end
    if #offline > 0 then
        rows[#rows + 1] = { group = #offline }
        if not DB.offlineCollapsed then
            for _, p in ipairs(offline) do rows[#rows + 1] = p end
        end
    end
    local friends = 0
    for _ in pairs(targets) do friends = friends + 1 end
    UI.onlineCount:SetText(online .. " online")
    UI.status:SetText(("Synced with %d of %s"):format(online, Plural(friends, "online friend")))
    UI.sort.text:SetText(GREY .. "Sort:|r " .. (K.SORT_LABEL[Opt("sort")] or "Name"))

    -- As many cards as fit the list's current height.
    local h = tonumber((UI.list:GetHeight()))
    local n = h and math.max(1, math.min(K.MAX_CARDS, math.floor((h - 8) / K.CARD_H))) or K.CARDS
    for i = #UI.cards + 1, n do UI.cards[i] = CreateCard(UI.list, i) end
    FauxScrollFrame_Update(UI.scroll, #rows, n, K.CARD_H)
    local offset = FauxScrollFrame_GetOffset(UI.scroll)
    for i, card in ipairs(UI.cards) do
        local p = i <= n and rows[i + offset]
        if p and p.group then
            FillGroupCard(card, p.group)
        elseif p then
            FillCard(card, p)
        else
            card.key, card.header = nil, false
            card:Hide()
        end
    end

    FillDetail(selectedKey and peers[selectedKey])
end

-- Opens the window on a tab (1 Friends, 2 Settings), optionally with a friend selected.
local function OpenUI(tab, key)
    UI = UI or CreateUI()
    if key and peers[key] then selectedKey = key end
    UI:Show()
    UI.SelectTab(tab or UI.tab or 1)
end

local function ToggleUI()
    UI = UI or CreateUI()
    if UI:IsShown() then UI:Hide() else OpenUI() end
end

------------------------------------------------------------------------
-- Minimap button and AddOns menu entry
------------------------------------------------------------------------

local minimapButton

local function LauncherClick(mouse)
    if mouse == "RightButton" then
        if UI and UI:IsShown() and UI.tab == 2 then UI:Hide() else OpenUI(2) end
    else
        ToggleUI()
    end
end

local function LauncherTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:AddLine("FriendsSync")
    local n = 0
    for _, p in ipairs(SortedPeers()) do
        if IsActive(p) then
            n = n + 1
            if n <= 10 then
                local gap = Opt("levelGap") and LevelGap(p) or ""
                local d = Distance(p)
                local where = (d and d <= NearbyYards()) and (GREEN .. d .. " yd|r") or (p.zone ~= "" and p.zone or "?")
                GameTooltip:AddDoubleLine(ColoredName(p) .. (gap ~= "" and (" " .. gap) or ""),
                    ("Lv %s  %s"):format(p.level or "?", where), 1, 1, 1, 0.8, 0.8, 0.8)
            end
        end
    end
    if n == 0 then GameTooltip:AddLine("No friends synced right now.", 0.6, 0.6, 0.6) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: open window", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Right-click: settings", 0.5, 0.5, 0.5)
    if owner == minimapButton then GameTooltip:AddLine("Drag: move button", 0.5, 0.5, 0.5) end
    GameTooltip:Show()
end

_G.FriendsSync_OnAddonCompartmentClick = function(_, mouse) LauncherClick(mouse) end
_G.FriendsSync_OnAddonCompartmentEnter = function(_, owner) LauncherTooltip(owner) end
_G.FriendsSync_OnAddonCompartmentLeave = function() GameTooltip:Hide() end

local function PlaceMinimapButton()
    local a = math.rad(DB.minimapAngle or 220)
    local r = Minimap:GetWidth() / 2 + 5
    minimapButton:ClearAllPoints()
    minimapButton:SetPoint("CENTER", Minimap, "CENTER", math.cos(a) * r, math.sin(a) * r)
end

function UpdateMinimapButton()
    if not Minimap then return end
    if DB.minimapHide then
        if minimapButton then minimapButton:Hide() end
        return
    end
    if not minimapButton then
        local b = CreateFrame("Button", "FriendsSyncMinimapButton", Minimap)
        b:SetSize(31, 31)
        b:SetFrameStrata("MEDIUM")
        b:SetFrameLevel(8)
        b:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
        local bg = b:CreateTexture(nil, "BACKGROUND")
        bg:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
        bg:SetSize(20, 20)
        bg:SetPoint("TOPLEFT", 7, -5)
        local icon = b:CreateTexture(nil, "ARTWORK")
        icon:SetTexture(K.ICON)
        icon:SetSize(17, 17)
        icon:SetPoint("TOPLEFT", 7, -6)
        icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
        local border = b:CreateTexture(nil, "OVERLAY")
        border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
        border:SetSize(53, 53)
        border:SetPoint("TOPLEFT")
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:RegisterForDrag("LeftButton")
        b:SetScript("OnClick", function(_, mouse) LauncherClick(mouse) end)
        b:SetScript("OnEnter", LauncherTooltip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnDragStart", function(self)
            GameTooltip:Hide()
            self:SetScript("OnUpdate", function()
                local mx, my = Minimap:GetCenter()
                local cx, cy = GetCursorPosition()
                local s = Minimap:GetEffectiveScale()
                if mx then DB.minimapAngle = math.deg(math.atan2(cy / s - my, cx / s - mx)) end
                PlaceMinimapButton()
            end)
        end)
        b:SetScript("OnDragStop", function(self) self:SetScript("OnUpdate", nil) end)
        minimapButton = b
    end
    PlaceMinimapButton()
    minimapButton:Show()
end


do
    ------------------------------------------------------------------------
    -- Right-click menu for a friend (own frame: Blizzard menus opened by addons break gamepad input on Forever)
    ------------------------------------------------------------------------

    local peerMenu
    K.MENU_ROW = 18

    local function MenuRow(menu, i)
        local b = CreateFrame("Button", nil, menu)
        b:SetHeight(K.MENU_ROW)
        b:SetPoint("TOPLEFT", 8, -28 - (i - 1) * K.MENU_ROW)
        b:SetPoint("RIGHT", menu, "RIGHT", -8, 0)
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", 6, 0)
        b.text:SetJustifyH("LEFT")
        b:SetScript("OnClick", function(self)
            menu:Hide()
            if self.fn then Try(self.fn) end
        end)
        return b
    end

    function ShowPeerMenu(owner, p)
        if not p then return end
        if not peerMenu then
            local m = CreateFrame("Frame", "FriendsSyncPeerMenu", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
            m:SetFrameStrata("FULLSCREEN_DIALOG")
            m:SetClampedToScreen(true)
            m:EnableMouse(true)
            m:SetWidth(180)
            if m.SetBackdrop then
                m:SetBackdrop({
                    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
                    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                    tile = true, tileSize = 16, edgeSize = 16, insets = { left = 4, right = 4, top = 4, bottom = 4 },
                })
                m:SetBackdropColor(0.05, 0.05, 0.05, 0.95)
            end
            m.title = m:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            m.title:SetPoint("TOPLEFT", 14, -10)
            m.title:SetPoint("RIGHT", -10, 0)
            m.title:SetJustifyH("LEFT")
            m.title:SetWordWrap(false)
            m.items = {}
            m:Hide()
            tinsert(UISpecialFrames, "FriendsSyncPeerMenu")
            pcall(m.RegisterEvent, m, "GLOBAL_MOUSE_DOWN")
            m:SetScript("OnEvent", function(self)
                if self:IsShown() and not self:IsMouseOver() then self:Hide() end
            end)
            peerMenu = m
        end
        local m = peerMenu
        local active = IsActive(p)
        local entries = {
            { "Whisper", function() WhisperPeer(p) end, active },
            { "Invite to group", function() InvitePeer(p) end, active },
            { "Set waypoint", function() WaypointPeer(p) end, active and p.mapID and p.mx },
            { "Send meet-up pin", function() SendMeet(p) end, active and CanMeet(p) },
            { "Match guide step", function() AskMatch(p) end, p.guideName and type(_G.RXP) == "table" },
            { "Show details", function() OpenUI(1, p.key) end, true },
            { "Hide from FriendsSync", function() SetHidden(p, true) end, true },
            { CANCEL or "Cancel", nil, true },
        }
        m.title:SetText(ColoredName(p))
        for i, e in ipairs(entries) do
            local b = m.items[i] or MenuRow(m, i)
            m.items[i] = b
            local on = e[3] and true or false
            b.fn = e[2]
            b.text:SetText(e[1])
            local c = on and 1 or 0.5
            b.text:SetTextColor(c, c, c)
            b:SetEnabled(on)
            b:Show()
        end
        m:SetHeight(28 + #entries * K.MENU_ROW + 10)
        m:ClearAllPoints()
        local x, y = nil, nil
        if GetCursorPosition then x, y = GetCursorPosition() end
        local scale = tonumber((UIParent:GetEffectiveScale()))
        if tonumber(x) and tonumber(y) and scale and scale > 0 then
            m:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x / scale - 4, y / scale + 4)
        else
            m:SetPoint("TOPLEFT", owner, "TOPRIGHT", 0, 0)
        end
        m:Show()
        if GameTooltip and GameTooltip.Hide then GameTooltip:Hide() end
    end

    ------------------------------------------------------------------------
    -- Mini tracker: online friends at a glance, without opening the window
    ------------------------------------------------------------------------

    K.TRACKER_ROWS, K.TRACKER_W = 6, 230

    function PlaceTracker()
        tracker:ClearAllPoints()
        local pos = DB.trackerPos
        if type(pos) == "table" and pos[1] then
            tracker:SetPoint(pos[1], UIParent, pos[2] or pos[1], tonumber(pos[3]) or 0, tonumber(pos[4]) or 0)
        else
            tracker:SetPoint("TOPRIGHT", UIParent, "TOPRIGHT", -230, -240)
        end
    end

    local function TrackerDragStart()
        if not Opt("trackerLock") then tracker:StartMoving() end
    end

    local function TrackerDragStop()
        tracker:StopMovingOrSizing()
        local point, _, rel, x, y = tracker:GetPoint(1)
        if type(point) == "string" then DB.trackerPos = { point, rel or point, tonumber(x) or 0, tonumber(y) or 0 } end
    end

    local function CreateTracker()
        local t = CreateFrame("Frame", "FriendsSyncTracker", UIParent, BackdropTemplateMixin and "BackdropTemplate" or nil)
        t:SetWidth(K.TRACKER_W)
        t:SetClampedToScreen(true)
        t:SetMovable(true)
        t:EnableMouse(true)
        t:RegisterForDrag("LeftButton")
        t:SetScript("OnDragStart", TrackerDragStart)
        t:SetScript("OnDragStop", TrackerDragStop)
        if t.SetBackdrop then
            t:SetBackdrop({
                bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
                edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
                edgeSize = 10, insets = { left = 2, right = 2, top = 2, bottom = 2 },
            })
            t:SetBackdropColor(0, 0, 0, 0.45)
            t:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.6)
        end
        t.title = t:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        t.title:SetPoint("TOPLEFT", 8, -6)
        t.title:SetText("FriendsSync")
        t.empty = t:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
        t.empty:SetPoint("TOPLEFT", 8, -22)
        t.empty:SetText("No synced friends online")
        t.rows = {}
        for i = 1, K.TRACKER_ROWS do
            local r = CreateFrame("Button", nil, t)
            r:SetHeight(16)
            r:SetPoint("TOPLEFT", 6, -20 - (i - 1) * 16)
            r:SetPoint("RIGHT", t, "RIGHT", -6, 0)
            r:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
            r.name = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.name:SetPoint("LEFT", 2, 0)
            r.name:SetWidth(96)
            r.name:SetJustifyH("LEFT")
            r.name:SetWordWrap(false)
            r.info = r:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            r.info:SetPoint("LEFT", r.name, "RIGHT", 4, 0)
            r.info:SetPoint("RIGHT", -2, 0)
            r.info:SetJustifyH("RIGHT")
            r.info:SetWordWrap(false)
            r:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            r:RegisterForDrag("LeftButton")
            r:SetScript("OnDragStart", TrackerDragStart)
            r:SetScript("OnDragStop", TrackerDragStop)
            r:SetScript("OnClick", function(self, button)
                local p = self.key and peers[self.key]
                if not p then return end
                if button == "RightButton" then ShowPeerMenu(self, p) else OpenUI(1, p.key) end
            end)
            r:SetScript("OnEnter", CardTooltip)
            r:SetScript("OnLeave", function() GameTooltip:Hide() end)
            t.rows[i] = r
        end
        tracker = t
        PlaceTracker()
        return t
    end

    function RefreshTracker()
        if not DB then return end
        if not Opt("tracker") then
            if tracker then tracker:Hide() end
            return
        end
        local t = tracker or CreateTracker()
        local shown = 0
        for _, p in ipairs(SortedPeers()) do
            if shown >= K.TRACKER_ROWS then break end
            if IsActive(p) then
                shown = shown + 1
                local r = t.rows[shown]
                r.key = p.key
                r.name:SetText(ColoredName(p))
                local gap = Opt("levelGap") and LevelGap(p) or ""
                local d = Distance(p)
                local extra
                if d and d <= NearbyYards() then
                    extra = GREEN .. d .. " yd|r"
                elseif p.guideName then
                    extra = StepLabel(p, true)
                else
                    extra = GREY .. (p.zone ~= "" and p.zone or "") .. "|r"
                end
                r.info:SetText(("Lv %s%s  %s"):format(p.level or "?", gap ~= "" and (" " .. gap) or "", extra or ""))
                r:Show()
            end
        end
        for i = shown + 1, K.TRACKER_ROWS do
            t.rows[i].key = nil
            t.rows[i]:Hide()
        end
        t.empty:SetShown(shown == 0)
        t:SetHeight(24 + math.max(1, shown) * 16)
        t:Show()
    end

    ------------------------------------------------------------------------
    -- Small button above the game's social (friends) button by the chat window
    ------------------------------------------------------------------------

    local friendsButton

    function UpdateFriendsButton()
        if not DB then return end
        local anchor = _G.QuickJoinToastButton or _G.FriendsMicroButton
        if not Opt("friendsButton") or type(anchor) ~= "table" then
            if friendsButton then friendsButton:Hide() end
            return
        end
        if not friendsButton then
            local b = CreateFrame("Button", "FriendsSyncSocialButton", anchor)
            b:SetSize(24, 24)
            b:SetPoint("BOTTOM", anchor, "TOP", 0, 2)
            local icon = b:CreateTexture(nil, "ARTWORK")
            icon:SetAllPoints()
            icon:SetTexture(K.ICON)
            icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
            b:SetHighlightTexture("Interface\\Buttons\\ButtonHilight-Square", "ADD")
            b.count = b:CreateFontString(nil, "OVERLAY", "NumberFontNormalSmall")
            b.count:SetPoint("BOTTOMRIGHT", 3, -2)
            b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
            b:SetScript("OnClick", function(_, mouse) LauncherClick(mouse) end)
            b:SetScript("OnEnter", LauncherTooltip)
            b:SetScript("OnLeave", function() GameTooltip:Hide() end)
            friendsButton = b
        end
        local n = 0
        for _, p in pairs(peers) do
            if IsActive(p) and not IsHidden(p) then n = n + 1 end
        end
        friendsButton.count:SetText(n > 0 and tostring(n) or "")
        friendsButton:Show()
    end
end

------------------------------------------------------------------------
-- Game options: Esc > Options > AddOns > FriendsSync
------------------------------------------------------------------------

local function RegisterOptionsPanel()
    local panel = CreateFrame("Frame", "FriendsSyncOptionsPanel")
    panel.name = "FriendsSync"
    local title = panel:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", 16, -16)
    title:SetText("FriendsSync")
    local open = MakeButton(panel, "Open FriendsSync", 140, 22)
    open:SetPoint("TOPRIGHT", -16, -14)
    open:SetScript("OnClick", function()
        if SettingsPanel and SettingsPanel.IsShown and SettingsPanel:IsShown() then pcall(HideUIPanel, SettingsPanel) end
        OpenUI(1)
    end)
    BuildSettings(panel, 16, -50, 310)
    panel:SetScript("OnShow", RefreshSettings)
    if Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterAddOnCategory then
        Settings.RegisterAddOnCategory(Settings.RegisterCanvasLayoutCategory(panel, "FriendsSync"))
    elseif InterfaceOptions_AddCategory then
        InterfaceOptions_AddCategory(panel)
    end
end

------------------------------------------------------------------------
-- System message filter: hide "No player named X" for our hidden whispers
------------------------------------------------------------------------

local notFoundPattern
if ERR_CHAT_PLAYER_NOT_FOUND_S then
    notFoundPattern = "^" .. ERR_CHAT_PLAYER_NOT_FOUND_S:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"):gsub("%%%%s", "(.+)") .. "$"
end

local function SystemFilter(_, _, msg, ...)
    if not notFoundPattern or type(msg) ~= "string" then return false end
    local name = msg:match(notFoundPattern)
    local sentAt = name and recentWhisper[name:lower()]
    if not sentAt or GetTime() - sentAt > 10 then return false end
    local short = CharId(name)
    for key, p in pairs(peers) do
        if CharId(key) == short then SetOffline(p) end
    end
    for k, t in pairs(targets) do
        if t.route.t == "W" and t.route.n:lower() == name:lower() then
            DropQueued(RouteId(t.route))
            targets[k] = nil
        end
    end
    return true
end

------------------------------------------------------------------------
-- World map dots
------------------------------------------------------------------------

local mapHolder, MapDotsOn, HookWorldMap, RegisterOpenMapToggle
do
    -- Same look and tooltip as OpenMap's friend dots, so both read alike on one map.
    K.MAP_DOT = 12
    K.CIRCLE_ATLAS = "WhiteCircle-RaidBlips"
    K.CIRCLE_TEXTURE = "Interface\\Minimap\\PartyRaidBlips"
    local mapPins = {}
    local mapPinsAt, mapScale = 0, nil

    function MapDotsOn() return DB and DB.mapDots ~= false end

    local function Circle(tex)
        local atlasOK = C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo(K.CIRCLE_ATLAS)
        if not (atlasOK and tex.SetAtlas and pcall(tex.SetAtlas, tex, K.CIRCLE_ATLAS)) then tex:SetTexture(K.CIRCLE_TEXTURE) end
    end

    -- 4245 -> "4,245"
    local function Thousands(n)
        local s = tostring(n)
        while true do
            local k
            s, k = s:gsub("^(%d+)(%d%d%d)", "%1,%2")
            if k == 0 then return s end
        end
    end

    local function MapPinEnter(pin)
        local p = pin.peer
        if not p then return end
        local c = p.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[p.class]
        local name = DisplayName(p)
        local realm = p.key:match("%-([^%-]+)$")
        if realm and realm ~= Realm() then name = name .. (FOREIGN_SERVER_LABEL or " (*)") end
        GameTooltip:SetOwner(pin, "ANCHOR_RIGHT")
        GameTooltip:AddLine(name, c and c.r or 1, c and c.g or 1, c and c.b or 1)
        if p.level and p.level > 0 then GameTooltip:AddLine((LEVEL or "Level") .. " " .. p.level, 1, 1, 1) end
        local info = p.mapID and C_Map and SafeCall(C_Map.GetMapInfo, p.mapID)
        local zone = (type(info) == "table" and info.name) or (p.zone ~= "" and p.zone) or "?"
        GameTooltip:AddLine(("%s  %.1f, %.1f"):format(zone, (p.mx or 0) / 100, (p.my or 0) / 100), 1, 1, 1)
        local d = Distance(p)
        if d then GameTooltip:AddLine(Thousands(d) .. " yd away", 1, 1, 1) end
        GameTooltip:AddLine("Friend", 0.6, 0.8, 1)
        local ago = math.floor(GetTime() - (p.lastSeen or 0))
        if ago >= 20 then GameTooltip:AddLine(("Updated %d s ago"):format(ago), 0.6, 0.6, 0.6) end
        GameTooltip:Show()
    end

    local function NewMapPin(canvas)
        local pin = CreateFrame("Button", nil, canvas)
        pin:SetSize(K.MAP_DOT, K.MAP_DOT)
        pin.dot = pin:CreateTexture(nil, "ARTWORK")
        pin.dot:SetAllPoints()
        Circle(pin.dot)
        pin.glow = pin:CreateTexture(nil, "HIGHLIGHT")
        pin.glow:SetAllPoints()
        Circle(pin.glow)
        pin.glow:SetBlendMode("ADD")
        pin.glow:SetAlpha(0.3)
        pin:SetScript("OnEnter", MapPinEnter)
        pin:SetScript("OnLeave", function() GameTooltip:Hide() end)
        pin:SetScript("OnClick", function(self) if self.peer then WaypointPeer(self.peer) end end)
        return pin
    end

    -- Where a friend is on the map shown (0..1 of the canvas), or nil when not on it.
    local function PeerOnMap(p, shown, stitched)
        local x, y
        if stitched then
            if p.inst and p.inst >= 0 and p.wx and p.wy then
                local ok, a, b = pcall(OpenMapAPI.CanvasFromWorldPos, p.inst, p.wx, p.wy)
                if ok and type(a) == "number" and type(b) == "number" then return a, b end
            end
            return nil
        end
        local mx, my = p.mx / 10000, p.my / 10000
        if p.mapID == shown then
            x, y = mx, my
        elseif C_Map and C_Map.GetMapRectOnMap then
            local ok, left, right, top, bottom = pcall(C_Map.GetMapRectOnMap, p.mapID, shown)
            left, right, top, bottom = Plain(left), Plain(right), Plain(top), Plain(bottom)
            if ok and type(left) == "number" and type(right) == "number" and type(top) == "number"
                and type(bottom) == "number" and right > left and bottom > top then
                x, y = left + mx * (right - left), top + my * (bottom - top)
            end
        end
        if x and x >= 0 and x <= 1 and y >= 0 and y <= 1 then return x, y end
    end

    -- Friends another map layer already shows: group members (the map's own party/raid dots) and, on
    -- OpenMap's stitched map with its friends layer on, friends who share where they are through OpenMap.
    local function DrawnElsewhere(p, stitched)
        if IsInGroup and SafeCall(IsInGroup) then
            for _, inGroup in ipairs({ UnitInParty, UnitInRaid }) do
                if SafeCall(inGroup, p.key) or SafeCall(inGroup, DisplayName(p)) then return true end
            end
        end
        if not stitched then return false end
        local om = _G.OpenMap
        local mod = type(om) == "table" and type(om.GetModule) == "function" and SafeCall(om.GetModule, om, "worldmap")
        if type(mod) ~= "table" or type(mod.FriendPlace) ~= "function" or not (type(mod.db) == "table" and mod.db.friends) then
            return false
        end
        return SafeCall(mod.FriendPlace, p.key) ~= nil
    end

    local function UpdateMapPins()
        local map = _G.WorldMapFrame
        local canvas = map and map.GetCanvas and map:GetCanvas()
        local used = 0
        if canvas and map:IsShown() and MapDotsOn() then
            local shown = map.GetMapID and map:GetMapID()
            local api = _G.OpenMapAPI
            local stitched = type(api) == "table" and type(api.IsStitched) == "function" and api.IsStitched()
                and type(api.CanvasFromWorldPos) == "function"
            local w, h = canvas:GetWidth(), canvas:GetHeight()
            local scale = canvas:GetScale() or 1
            if scale <= 0 then scale = 1 end
            mapScale = scale
            local level = canvas:GetFrameLevel() + 2000
            if stitched and type(api.ArtTopLevel) == "function" then
                local top = tonumber(api.ArtTopLevel())
                if top and top + 5 > level then level = top + 5 end
            end
            level = math.min(level, 9900)
            for _, p in pairs(peers) do
                if IsActive(p) and p.mapID and p.mx and p.my and (shown or stitched) and not DrawnElsewhere(p, stitched) then
                    local x, y = PeerOnMap(p, shown, stitched)
                    if x then
                        used = used + 1
                        local pin = mapPins[used]
                        if not pin or pin:GetParent() ~= canvas then
                            if pin then pin:Hide() end
                            pin = NewMapPin(canvas)
                            mapPins[used] = pin
                        end
                        pin.peer = p
                        local c = p.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[p.class]
                        pin.dot:SetVertexColor(c and c.r or 1, c and c.g or 1, c and c.b or 1, 1)
                        pin:SetScale(1 / scale)
                        pin:SetFrameLevel(level)
                        pin:ClearAllPoints()
                        pin:SetPoint("CENTER", canvas, "TOPLEFT", x * w * scale, -y * h * scale)
                        pin:Show()
                    end
                end
            end
        end
        for i = used + 1, #mapPins do mapPins[i]:Hide() end
    end

    function HookWorldMap()
        if mapHolder or not _G.WorldMapFrame then return end
        mapHolder = CreateFrame("Frame", nil, _G.WorldMapFrame)
        mapHolder:SetScript("OnUpdate", function()
            local now = GetTime()
            local canvas = _G.WorldMapFrame.GetCanvas and _G.WorldMapFrame:GetCanvas()
            local zoomed = canvas and canvas:GetScale() ~= mapScale
            if zoomed or now - mapPinsAt >= 0.2 then
                mapPinsAt = now
                Try(UpdateMapPins)
            end
        end)
        mapHolder:SetScript("OnShow", function() mapPinsAt = 0 end)
    end

    function RegisterOpenMapToggle()
        local api = _G.OpenMapAPI
        if type(api) ~= "table" or type(api.RegisterMenuToggle) ~= "function" then return end
        api.RegisterMenuToggle(ADDON, {
            id = "dots", label = "FriendsSync friends", icon = K.ICON, section = "FriendsSync",
            get = MapDotsOn,
            set = function(v)
                DB.mapDots = v and true or false
                RefreshSettings()
                if RefreshUI then RefreshUI() end
            end,
        })
    end
end

------------------------------------------------------------------------
-- Events / init
------------------------------------------------------------------------

local SESSION_FIELDS = { "online", "lastSeen", "announced", "nearby", "nearbyAt", "qbuf", "guideSeen", "versionWarned", "meet" }

local events = CreateFrame("Frame")
events:RegisterEvent("ADDON_LOADED")
events:RegisterEvent("PLAYER_LOGIN")

events:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= ADDON then return end
        FriendsSyncDB = FriendsSyncDB or {}
        DB = FriendsSyncDB
        if DB.notify == nil then DB.notify = true end
        DB.peers = DB.peers or {}
        DB.hidden = DB.hidden or {}
        peers = DB.peers
        for _, p in pairs(peers) do
            for _, k in ipairs(SESSION_FIELDS) do p[k] = nil end
        end
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "PLAYER_LOGIN" then
        myKey = FullName(PlayerName() or "?")
        peers[myKey] = nil
        -- Events and tickers first, so a failure below can never stop syncing.
        for _, e in ipairs({ "CHAT_MSG_ADDON", "BN_CHAT_MSG_ADDON", "FRIENDLIST_UPDATE", "BN_FRIEND_INFO_CHANGED",
            "BN_FRIEND_ACCOUNT_ONLINE", "BN_FRIEND_ACCOUNT_OFFLINE", "QUEST_LOG_UPDATE", "PLAYER_ENTERING_WORLD" }) do
            pcall(self.RegisterEvent, self, e)
        end
        lastRefill = GetTime()
        C_Timer.NewTicker(0.25, function() Try(Flush) end)
        C_Timer.NewTicker(1, function() Try(Tick) end)
        Try(C_ChatInfo.RegisterAddonMessagePrefix, K.COMM)
        local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
        if addFilter then Try(addFilter, "CHAT_MSG_SYSTEM", SystemFilter) end
        if C_FriendList and C_FriendList.ShowFriends then Try(C_FriendList.ShowFriends) end
        Try(ScanQuests)
        Try(function() guideSig = BuildGuide() end)
        Try(RefreshTargets)
        Try(UpdateMinimapButton)
        Try(UpdateFriendsButton)
        Try(RefreshTracker)
        Try(RegisterOptionsPanel)
        Try(HookWorldMap)
        Try(RegisterOpenMapToggle)
        if not mapHolder then C_Timer.NewTicker(2, function() if not mapHolder then Try(HookWorldMap) end end) end

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, channel, sender = ...
        if Plain(prefix) ~= K.COMM then return end
        text, channel, sender = Plain(text), Plain(channel), Plain(sender)
        if type(text) == "string" and type(sender) == "string" and channel == "WHISPER" then
            Try(OnWhisperAddon, text, sender)
        else
            Debug("ignored addon message: channel " .. tostring(channel) .. ", sender " .. tostring(sender) .. " (secret/unknown)")
        end

    elseif event == "BN_CHAT_MSG_ADDON" then
        local prefix, text, _, senderID = ...
        if Plain(prefix) ~= K.COMM then return end
        text, senderID = Plain(text), Plain(senderID)
        if type(text) == "string" and senderID then
            Try(OnBNetAddon, text, senderID)
        else
            Debug("ignored Battle.net message: text or sender is secret/unknown")
        end

    elseif event == "QUEST_LOG_UPDATE" then
        questDirtyAt = GetTime()

    elseif event == "PLAYER_ENTERING_WORLD" then
        questDirtyAt = GetTime()
        statusAt = 0

    else -- friend list changes
        Try(RefreshTargets)
    end
end)

------------------------------------------------------------------------
-- Slash commands
------------------------------------------------------------------------

SLASH_FRIENDSSYNC1 = "/fsync"
SLASH_FRIENDSSYNC2 = "/friendsync"
SlashCmdList.FRIENDSSYNC = function(msg)
    local cmd, arg = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = (cmd or ""):lower()
    if cmd == "" or cmd == "show" then
        ToggleUI()
    elseif cmd == "ping" then
        PingFriends()
    elseif cmd == "notify" or cmd == "alerts" then
        DB.notify = not Opt("notify")
        Print("Alerts " .. (DB.notify and "enabled." or "disabled."))
        RefreshSettings()
    elseif cmd == "settings" or cmd == "options" or cmd == "config" then
        OpenUI(2)
    elseif cmd == "tracker" then
        DB.tracker = not Opt("tracker")
        Try(RefreshTracker)
        RefreshSettings()
        Print("Mini tracker " .. (DB.tracker and "shown." or "hidden."))
    elseif cmd == "list" then
        local list = SortedPeers()
        if #list == 0 then Print("No synced friends yet.") end
        for _, p in ipairs(list) do
            local d = IsActive(p) and Distance(p)
            Print(("%s - %s - level %s - %s%s"):format(DisplayName(p), IsActive(p) and "online" or "offline",
                LevelText(p.level, p.xp, p.xpMax, p.rested), p.zone or "?", d and (" - %d yd"):format(d) or ""))
        end
    elseif cmd == "forget" and arg ~= "" then
        local short, removed = CharId(arg), false
        for key in pairs(peers) do
            if CharId(key) == short then
                peers[key] = nil
                removed = true
            end
        end
        Print(removed and ("Forgot " .. arg .. ".") or ("No synced friend named " .. arg .. "."))
        if RefreshUI then RefreshUI() end
    elseif cmd == "status" then
        Try(RefreshTargets)
        local w, b, active = 0, 0, 0
        for _, t in pairs(targets) do
            if t.route.t == "B" then b = b + 1 else w = w + 1 end
        end
        for _, p in pairs(peers) do
            if IsActive(p) then active = active + 1 end
        end
        Print(("Build %s. You are %s. Reachable friends: %d Battle.net, %d WoW friends list. Synced now: %d. Queued: %d.")
            :format(K.BUILD, tostring(myKey), b, w, active, #sendQueue))
        if lastError then Print("Last error: " .. lastError) end
    elseif cmd == "minimap" then
        DB.minimapHide = not DB.minimapHide
        Try(UpdateMinimapButton)
        RefreshSettings()
        Print("Minimap button " .. (DB.minimapHide and "hidden." or "shown."))
    elseif cmd == "map" then
        DB.mapDots = not MapDotsOn()
        Print("World map dots " .. (DB.mapDots and "shown." or "hidden."))
        RefreshSettings()
    elseif cmd == "debug" then
        DB.debug = not DB.debug
        Print("Debug " .. (DB.debug and "on." or "off."))
    else
        Print("/fsync - open window | /fsync settings | /fsync tracker | /fsync ping | /fsync list | /fsync status | /fsync notify | /fsync map | /fsync minimap | /fsync forget <name> | /fsync debug")
    end
end
