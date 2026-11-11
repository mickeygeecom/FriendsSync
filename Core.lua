local ADDON = ...

local PREFIX = "|cff33ff99FriendsSync|r: "
local COMM = "FriendsSync"
local BUILD = "4"
local PROTO = 1
local SEP = "~"
local MAX_MSG = 250
local BURST, RATE = 8, 1            -- send throttle: burst size, messages regained per second
local HEARTBEAT = 30                 -- always resend status at least this often
local STATUS_MIN_INTERVAL = 5
local MOVE_INTERVAL, MOVE_YARDS = 10, 25
local PEER_TIMEOUT = 100
local HELLO_BASE, HELLO_MAX = 60, 600
local TARGET_REFRESH = 15
local NEARBY_YARDS, NEARBY_COOLDOWN = 150, 300
local LEVEL_GAP_WARN = 3
local STEP_SYNC_RANGE = 3
local NAME_MAX = 90

local DB, peers
local myKey
local targets, targetsShort = {}, {}
local helloNext, helloTries = {}, {}
local sendQueue = {}
local tokens, lastRefill = BURST, 0
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

------------------------------------------------------------------------
-- Helpers
------------------------------------------------------------------------

local function Print(msg)
    DEFAULT_CHAT_FRAME:AddMessage(PREFIX .. tostring(msg))
end

local function Debug(msg)
    if DB and DB.debug then Print("|cff888888" .. tostring(msg) .. "|r") end
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
    s = (tostring(s or ""):gsub(SEP, "-"):gsub("|", "/"))
    if maxLen and #s > maxLen then s = s:sub(1, maxLen) end
    return s
end

local function Split(text)
    local t = {}
    for field in (text .. SEP):gmatch("(.-)" .. SEP) do
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

-- Name the game accepts for /w and invites ("Jane Doe" -> "Jane-Doe" on Forever).
local function TargetName(p)
    return (DisplayName(p):gsub(" ", "-"))
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
    return (p.online and p.lastSeen and GetTime() - p.lastSeen < PEER_TIMEOUT) and true or false
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
        ok, err = pcall(BNSendGameData, route.id, COMM, text)
    else
        recentWhisper[route.n:lower()] = GetTime()
        ok, err = pcall(C_ChatInfo.SendAddonMessage, COMM, text, "WHISPER", route.n)
    end
    if not ok then
        lastError = tostring(err)
        Debug("send failed: " .. lastError)
    end
end

local function Flush()
    local now = GetTime()
    tokens = math.min(BURST, tokens + (now - lastRefill) * RATE)
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
        Num(mx, 10000), Num(my, 10000), Num(wx), Num(wy), inst or -1, zone, sub }, SEP)
    local core = table.concat({ level, xp, rested, zone, sub }, SEP)
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
    return Clean(group, NAME_MAX) .. "\n" .. Clean(name, NAME_MAX)
end

local function BuildGuide()
    local group, name, step, steps = GetGuideInfo()
    return table.concat({ "G", myKey, Clean(group, NAME_MAX), Clean(name, NAME_MAX), step or 0, steps or 0 }, SEP)
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
        return Plain(info.title), id, complete and true or false
    end
    if GetQuestLogTitle then
        local title, _, _, isHeader, _, isComplete, _, id = GetQuestLogTitle(i)
        if isHeader or type(id) ~= "number" or id <= 0 then return nil end
        return title, id, isComplete == 1 or isComplete == true
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
        local title, questID, complete = QuestLogEntry(i)
        if questID and not byId[questID] then
            local done, total = QuestObjectives(i, questID)
            local q = { id = questID, title = type(title) == "string" and title or ("Quest #" .. questID),
                done = done, total = total, complete = complete }
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
    local budget = MAX_MSG - #table.concat({ "Q", myKey, "99", "99", "" }, SEP)
    local chunks, cur = {}, ""
    for _, q in ipairs(myQuests) do
        local e = EncodeQuest(q)
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
        msgs[i] = table.concat({ "Q", myKey, i, #chunks, c }, SEP)
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
    return table.concat({ "H", myKey, PROTO, isReply and 1 or 0 }, SEP)
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
    local moved = x and statusX and (inst ~= statusInst or (x - statusX) ^ 2 + (y - statusY) ^ 2 > MOVE_YARDS ^ 2)
    local due = force
        or (core ~= statusCore and now - statusAt >= STATUS_MIN_INTERVAL)
        or (moved and now - statusAt >= MOVE_INTERVAL)
        or now - statusAt >= HEARTBEAT
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
    return math.sqrt((x - p.wx) ^ 2 + (y - p.wy) ^ 2)
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
    if d <= NEARBY_YARDS then
        if not p.nearby then
            p.nearby = true
            local now = GetTime()
            if DB.notify and now - (p.nearbyAt or 0) > NEARBY_COOLDOWN then
                p.nearbyAt = now
                local _, _, _, together = CompareQuests(p)
                local extra = together > 0 and (" - %s in progress"):format(together == 1 and "1 shared quest" or (together .. " shared quests")) or ""
                Print(("%s is nearby (%d yd)%s."):format(ChatName(p), d, extra))
            end
        end
    elseif d > NEARBY_YARDS * 1.5 then
        p.nearby = nil
    end
end

------------------------------------------------------------------------
-- Receiving
------------------------------------------------------------------------

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
        if DB.notify then
            Print(("%s is online - level %s, %s."):format(ChatName(p), p.level or "?",
                p.zone ~= "" and p.zone or "unknown zone"))
        end
    elseif oldLevel and p.level and p.level > oldLevel and DB.notify then
        Print(("%s |cffffd100reached level %d!|r"):format(ChatName(p), p.level))
    end
    CheckNearby(p)
end

local function HandleGuide(p, f)
    if not f[4] or f[4] == "" then
        p.guideGroup, p.guideName, p.step, p.steps = nil, nil, nil, nil
        return
    end
    p.guideGroup, p.guideName = f[3] or "", f[4]
    p.step, p.steps = tonumber(f[5]) or 0, tonumber(f[6]) or 0
end

local function HandleQuests(p, f)
    local seq, total = tonumber(f[3]), tonumber(f[4])
    if not seq or not total or seq < 1 or seq > total then return end
    if seq == 1 then p.qbuf = {} end
    if not p.qbuf then return end
    p.qbuf[seq] = f[5] or ""
    if seq < total then return end

    local list = {}
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
            end
        end
    end
    p.quests, p.qbuf = list, nil
end

local function OnMessage(text, route)
    Debug("< " .. RouteId(route) .. " " .. text)
    local f = Split(text)
    local kind, key = f[1], f[2]
    if not key or key == "" or key == myKey then return end

    local p = GetPeer(key)
    p.online, p.lastSeen, p.seenAt = true, GetTime(), time()

    if kind == "H" then
        p.proto = tonumber(f[3])
        if f[4] ~= "1" then Enqueue(route, "H", BuildHello(true)) end
        SendFullState(route)
    elseif kind == "S" then
        HandleStatus(p, f)
    elseif kind == "G" then
        HandleGuide(p, f)
    elseif kind == "Q" then
        HandleQuests(p, f)
    end
    if RefreshUI then RefreshUI() end
end

local function MessageKey(text)
    return text:match("^%a" .. SEP .. "([^" .. SEP .. "]+)")
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
            helloNext[k] = now + math.min(HELLO_BASE * 2 ^ (tries - 1), HELLO_MAX)
            Enqueue(t.route, "H", BuildHello(false))
        end
    end
end

local function Tick()
    local now = GetTime()
    if now - lastTargetRefresh >= TARGET_REFRESH then RefreshTargets() end
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
end

------------------------------------------------------------------------
-- Actions
------------------------------------------------------------------------

local function InvitePeer(p)
    local name = TargetName(p)
    local invite = (C_PartyInfo and C_PartyInfo.InviteUnit) or InviteUnit
    if invite then invite(name) end
end

local function WhisperPeer(p)
    local text = "/w " .. TargetName(p) .. " "
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

local function WaypointPeer(p)
    if not (p.mapID and p.mx and p.my) then
        Print("No map position known for " .. DisplayName(p) .. ".")
        return
    end
    local x, y = p.mx / 10000, p.my / 10000
    local tomtom = _G.TomTom
    if type(tomtom) == "table" and tomtom.AddWaypoint then
        tomtom:AddWaypoint(p.mapID, x, y, { title = DisplayName(p), from = ADDON, persistent = false, crazy = true })
        Print(("Waypoint set to %s (%.1f, %.1f)."):format(DisplayName(p), x * 100, y * 100))
    elseif C_Map.SetUserWaypoint and UiMapPoint and C_Map.CanSetUserWaypointOnMap and C_Map.CanSetUserWaypointOnMap(p.mapID) then
        C_Map.SetUserWaypoint(UiMapPoint.CreateFromCoordinates(p.mapID, x, y))
        Print(("Map pin set to %s (%.1f, %.1f)."):format(DisplayName(p), x * 100, y * 100))
    else
        Print(("%s is at %.1f, %.1f in %s."):format(DisplayName(p), x * 100, y * 100, p.zone or "?"))
    end
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

local WIN_W, WIN_H = 660, 540
local LIST_W = 230
local CARD_H, CARDS = 46, 9
local BAR_TEX = "Interface\\TargetingFrame\\UI-StatusBar"
local ICON = "Interface\\AddOns\\FriendsSync\\Icon"
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
        if n <= STEP_SYNC_RANGE then return GREEN .. "In sync|r" end
        local what = short and tostring(n) or Plural(n, "step")
        if diff > 0 then return "|cffff9933" .. what .. " ahead|r" end
        return "|cff66bbff" .. what .. " behind|r"
    end
    if why == "other" then return GREY .. "Other guide|r" end
    return ""
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
    if together > 0 and d and d <= NEARBY_YARDS then
        return ("You're close and share %s. Invite them and quest together!"):format(Plural(together, "quest"))
    end
    if diff and diff > STEP_SYNC_RANGE then
        return ("They're %s ahead in the guide. Click Match step to jump there, or ask them to wait."):format(Plural(diff, "step"))
    end
    if diff and diff < -STEP_SYNC_RANGE then
        return ("You're %s ahead in the guide. Wait for them, or they can match your step."):format(Plural(-diff, "step"))
    end
    if gap and gap >= LEVEL_GAP_WARN then
        return ("They're %s ahead of you. Their quests and mobs will be tough for you."):format(Plural(gap, "level"))
    end
    if gap and gap <= -LEVEL_GAP_WARN then
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

local function QuestListText(p)
    local shared, theirs, mine = CompareQuests(p)
    local L = {}
    local function add(s) L[#L + 1] = s end
    local function section(title, n)
        if #L > 0 then add(" ") end
        add(("%s%s (%d)|r"):format(GOLD, title, n))
    end
    if #shared > 0 then
        section("You both have", #shared)
        for _, s in ipairs(shared) do
            add(("%s%s|r\n    %syou|r %s   %sthem|r %s"):format(WHITE, QuestTitle(s.id), GREY, QuestProgress(s.me), GREY, QuestProgress(s.them)))
        end
    end
    local can, done = {}, {}
    for _, q in ipairs(theirs) do
        if CompletedByMe(q.id) then done[#done + 1] = q else can[#can + 1] = q end
    end
    if #can > 0 then
        section("You could pick up", #can)
        for _, q in ipairs(can) do add(("%s%s|r  %s"):format(WHITE, QuestTitle(q.id), QuestProgress(q))) end
    end
    if #mine > 0 then
        section("Only you have", #mine)
        for _, q in ipairs(mine) do add(("%s%s|r  %s"):format(WHITE, q.title, QuestProgress(q))) end
    end
    if #done > 0 then
        section("They have, you already did", #done)
        for _, q in ipairs(done) do add(GREY .. QuestTitle(q.id) .. "|r") end
    end
    return table.concat(L, "\n")
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

local function MakePanel(parent)
    local f = CreateFrame("Frame", nil, parent, BackdropTemplateMixin and "BackdropTemplate" or nil)
    if f.SetBackdrop then
        f:SetBackdrop({
            bgFile = "Interface\\ChatFrame\\ChatFrameBackground",
            edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
            edgeSize = 12, insets = { left = 3, right = 3, top = 3, bottom = 3 },
        })
        f:SetBackdropColor(0, 0, 0, 0.45)
        f:SetBackdropBorderColor(0.5, 0.5, 0.5, 0.8)
    end
    return f
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

-- XP bar with a rested overlay: label on the left, "Level 10 - 50%" on the bar.
local function MakeXPBar(parent)
    local h = CreateFrame("Frame", nil, parent)
    h:SetHeight(16)
    h.label = h:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.label:SetPoint("LEFT")
    h.label:SetWidth(120)
    h.label:SetJustifyH("LEFT")
    h.label:SetWordWrap(false)
    h.rested = CreateFrame("StatusBar", nil, h)
    h.rested:SetPoint("TOPLEFT", 124, 0)
    h.rested:SetPoint("BOTTOMRIGHT")
    h.rested:SetStatusBarTexture(BAR_TEX)
    h.rested:SetStatusBarColor(0.0, 0.39, 0.88, 0.45)
    local bg = h.rested:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    h.bar = CreateFrame("StatusBar", nil, h.rested)
    h.bar:SetAllPoints()
    h.bar:SetStatusBarTexture(BAR_TEX)
    h.bar:SetStatusBarColor(0.58, 0.0, 0.55)
    h.text = h.bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    h.text:SetPoint("CENTER")
    function h.Set(label, level, xp, xpMax, rested)
        h.label:SetText(label)
        local max = (xpMax and xpMax > 0) and xpMax or 1
        xp = xp or 0
        h.bar:SetMinMaxValues(0, max)
        h.bar:SetValue(xp)
        h.rested:SetMinMaxValues(0, max)
        h.rested:SetValue(math.min(max, xp + (rested or 0)))
        local pct = XPPercent(xp, xpMax)
        h.text:SetText(("Level %s%s%s"):format(level or "?", pct and (" - " .. pct .. "%") or "",
            (rested and rested > 0) and " - rested" or ""))
    end
    return h
end

local function SortedPeers()
    local list = {}
    for _, p in pairs(peers) do list[#list + 1] = p end
    table.sort(list, function(a, b)
        local ao, bo = IsActive(a), IsActive(b)
        if ao ~= bo then return ao end
        return DisplayName(a):lower() < DisplayName(b):lower()
    end)
    return list
end

local function CardTooltip(card)
    local p = card.key and peers[card.key]
    if not p then return end
    GameTooltip:SetOwner(card, "ANCHOR_RIGHT")
    GameTooltip:AddLine(ColoredName(p))
    GameTooltip:AddLine(("Level %s %s"):format(LevelText(p.level, p.xp, p.xpMax, p.rested), ClassName(p.class) or ""), 1, 1, 1)
    if IsActive(p) then
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
    GameTooltip:AddLine("Click to see details", 0.5, 0.5, 0.5)
    GameTooltip:Show()
end

local function CreateCard(parent, i)
    local c = CreateFrame("Button", nil, parent)
    c:SetHeight(CARD_H - 2)
    c:SetPoint("TOPLEFT", 4, -4 - (i - 1) * CARD_H)
    c:SetPoint("RIGHT", parent, "RIGHT", -26, 0)
    c:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
    c.sel = c:CreateTexture(nil, "BACKGROUND")
    c.sel:SetAllPoints()
    c.sel:SetColorTexture(0.2, 0.6, 1, 0.25)
    c.icon = c:CreateTexture(nil, "ARTWORK")
    c.icon:SetSize(30, 30)
    c.icon:SetPoint("LEFT", 4, 1)
    c.name = c:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    c.name:SetPoint("TOPLEFT", c.icon, "TOPRIGHT", 6, 0)
    c.name:SetPoint("RIGHT", c, "RIGHT", -62, 0)
    c.name:SetJustifyH("LEFT")
    c.name:SetWordWrap(false)
    c.badge = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.badge:SetPoint("TOPRIGHT", -4, -6)
    c.badge:SetJustifyH("RIGHT")
    c.info = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.info:SetPoint("TOPLEFT", c.name, "BOTTOMLEFT", 0, -3)
    c.info:SetPoint("RIGHT", c, "RIGHT", -4, 0)
    c.info:SetJustifyH("LEFT")
    c.info:SetWordWrap(false)
    c.xp = CreateFrame("StatusBar", nil, c)
    c.xp:SetHeight(3)
    c.xp:SetPoint("BOTTOMLEFT", 40, 3)
    c.xp:SetPoint("BOTTOMRIGHT", -4, 3)
    c.xp:SetStatusBarTexture(BAR_TEX)
    c.xp:SetStatusBarColor(0.58, 0.0, 0.55)
    local bg = c.xp:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.5)
    c:SetScript("OnClick", function(self)
        selectedKey = self.key
        RefreshUI()
    end)
    c:SetScript("OnEnter", CardTooltip)
    c:SetScript("OnLeave", function() GameTooltip:Hide() end)
    return c
end

local function FillCard(c, p)
    local active = IsActive(p)
    c.key = p.key
    c.sel:SetShown(p.key == selectedKey)
    SetClassIcon(c.icon, p.class, not active)
    c.name:SetText(ColoredName(p))
    if active then
        c.info:SetText(("Lv %s  %s%s|r"):format(p.level or "?", GREY, p.zone ~= "" and p.zone or "?"))
        local d = Distance(p)
        if d and d <= NEARBY_YARDS then
            c.badge:SetText(GREEN .. "Nearby|r")
        else
            c.badge:SetText(StepLabel(p, true))
        end
    else
        c.info:SetText(GREY .. "Offline - " .. Ago(p.seenAt and time() - p.seenAt) .. "|r")
        c.badge:SetText("")
    end
    c.xp:SetMinMaxValues(0, (p.xpMax and p.xpMax > 0) and p.xpMax or 1)
    c.xp:SetValue(p.xp or 0)
    c.xp:SetShown(active)
    c:Show()
end

-- Guide track: one bar for the guide with a "You" marker above and a "Them" marker below.
-- On different guides it shows two small progress bars instead.
local TRACK_W = WIN_W - LIST_W - 30 - 28

local function ClassRGB(class)
    local c = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if c then return c.r, c.g, c.b end
    return 1, 1, 1
end

local function TrackTexture(t, layer)
    local tex = t:CreateTexture(nil, layer)
    tex:SetTexture(BAR_TEX)
    return tex
end

local function MakeGuideTrack(parent)
    local t = CreateFrame("Frame", nil, parent)
    t:SetSize(TRACK_W, 46)
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
    m:SetPoint("CENTER", t, "TOPLEFT", frac * TRACK_W, y)
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

local function FillGuideTrack(t, p)
    if not p.guideName then t:Hide() return end
    t:Show()
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
        Bar(t, t.barA, -19, 8, 0, TRACK_W, 0.15, 0.15, 0.15, 0.9)
        Bar(t, t.fillA, -19, 8, 0, lo * TRACK_W, 0.45, 0.45, 0.45)
        local gr, gg, gb = 0.25, 0.9, 0.25
        if math.abs(diff) > STEP_SYNC_RANGE then
            if diff > 0 then gr, gg, gb = 1, 0.6, 0.2 else gr, gg, gb = 0.4, 0.73, 1 end
        end
        Bar(t, t.gap, -19, 8, lo * TRACK_W, (hi - lo) * TRACK_W, gr, gg, gb)
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
        Bar(t, t.barA, -13, 5, 0, TRACK_W, 0.15, 0.15, 0.15, 0.9)
        Bar(t, t.fillA, -13, 5, 0, myFrac * TRACK_W, 1, 0.82, 0)
        Bar(t, t.barB, -37, 5, 0, TRACK_W, 0.15, 0.15, 0.15, 0.9)
        Bar(t, t.fillB, -37, 5, 0, theirFrac * TRACK_W, r, g, b)
    end
end

local function CreateDetail(f)
    local d = MakePanel(f)
    d:SetPoint("TOPLEFT", LIST_W + 18, -30)
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

    local tipBox = CreateFrame("Frame", nil, c, BackdropTemplateMixin and "BackdropTemplate" or nil)
    tipBox:SetPoint("TOPLEFT", 8, -58)
    tipBox:SetPoint("TOPRIGHT", -8, -58)
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
    h1:SetPoint("TOPLEFT", 10, -110)
    c.myBar = MakeXPBar(c)
    c.myBar:SetPoint("TOPLEFT", 14, -128)
    c.myBar:SetPoint("RIGHT", -12, 0)
    c.theirBar = MakeXPBar(c)
    c.theirBar:SetPoint("TOPLEFT", 14, -148)
    c.theirBar:SetPoint("RIGHT", -12, 0)

    local h2 = MakeHeading(c, "Guide")
    h2:SetPoint("TOPLEFT", 10, -176)
    c.guide = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.guide:SetPoint("TOPLEFT", 14, -196)
    c.guide:SetPoint("RIGHT", -110, 0)
    c.guide:SetJustifyH("LEFT")
    c.guide:SetWordWrap(false)
    c.track = MakeGuideTrack(c)
    c.track:SetPoint("TOPLEFT", 14, -218)

    local h3 = MakeHeading(c, "Quests")
    h3:SetPoint("TOPLEFT", 10, -270)
    c.questSummary = c:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.questSummary:SetPoint("TOPLEFT", 14, -288)
    c.questSummary:SetPoint("RIGHT", -10, 0)
    c.questSummary:SetJustifyH("LEFT")

    local sf = CreateFrame("ScrollFrame", "FriendsSyncQuestScroll", c, "UIPanelScrollFrameTemplate")
    sf:SetPoint("TOPLEFT", 14, -306)
    sf:SetPoint("BOTTOMRIGHT", -30, 38)
    local child = CreateFrame("Frame", nil, sf)
    child:SetSize(340, 10)
    sf:SetScrollChild(child)
    c.quests = child:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    c.quests:SetPoint("TOPLEFT")
    c.quests:SetWidth(340)
    c.quests:SetJustifyH("LEFT")
    c.quests:SetJustifyV("TOP")
    c.questChild = child

    return d
end

local function CreateUI()
    local f = CreateFrame("Frame", "FriendsSyncFrame", UIParent, "BasicFrameTemplateWithInset")
    f:SetSize(WIN_W, WIN_H)
    f:SetPoint("CENTER")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", f.StopMovingOrSizing)
    f:SetFrameStrata("MEDIUM")
    f:Hide()
    tinsert(UISpecialFrames, f:GetName())
    SetTitle(f, "FriendsSync")

    -- Left: friend cards
    local listHead = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    listHead:SetPoint("TOPLEFT", 16, -32)
    listHead:SetText("Friends")
    f.onlineCount = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.onlineCount:SetPoint("TOPRIGHT", f, "TOPLEFT", LIST_W + 10, -34)

    local list = MakePanel(f)
    list:SetPoint("TOPLEFT", 12, -50)
    list:SetPoint("BOTTOMLEFT", 12, 44)
    list:SetWidth(LIST_W)

    local scroll = CreateFrame("ScrollFrame", "FriendsSyncListScroll", list, "FauxScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", 4, -4)
    scroll:SetPoint("BOTTOMRIGHT", -26, 4)
    scroll:SetScript("OnVerticalScroll", function(self, offset)
        FauxScrollFrame_OnVerticalScroll(self, offset, CARD_H, RefreshUI)
    end)
    f.scroll = scroll
    f.cards = {}
    for i = 1, CARDS do f.cards[i] = CreateCard(list, i) end

    -- Right: details for the selected friend
    f.detail = CreateDetail(f)
    local c = f.detail.content
    local function selected() return selectedKey and peers[selectedKey] end

    f.invite = MakeButton(c, "Invite", 90, 22, "Invite them to a group.")
    f.invite:SetPoint("BOTTOMLEFT", 10, 10)
    f.invite:SetScript("OnClick", function() local p = selected(); if p then InvitePeer(p) end end)

    f.whisper = MakeButton(c, "Whisper", 90, 22, "Start a whisper to them in chat.")
    f.whisper:SetPoint("LEFT", f.invite, "RIGHT", 4, 0)
    f.whisper:SetScript("OnClick", function() local p = selected(); if p then WhisperPeer(p) end end)

    f.waypoint = MakeButton(c, "Waypoint", 90, 22, "Put a map pin (or TomTom arrow) on their position.")
    f.waypoint:SetPoint("LEFT", f.whisper, "RIGHT", 4, 0)
    f.waypoint:SetScript("OnClick", function() local p = selected(); if p then WaypointPeer(p) end end)

    f.match = MakeButton(c, "Match step", 96, 20, "Switch your RestedXP guide to the same guide and step they are on.")
    f.match:SetPoint("TOPRIGHT", -10, -192)
    f.match:SetScript("OnClick", function()
        local p = selected()
        if not (p and p.guideName) then return end
        StaticPopup_Show("FRIENDSSYNC_MATCH", DisplayName(p), p.guideName .. " - step " .. (p.step or 1), p.key)
    end)

    -- Bottom bar
    local cb = CreateFrame("CheckButton", nil, f, "UICheckButtonTemplate")
    cb:SetSize(24, 24)
    cb:SetPoint("BOTTOMLEFT", 12, 12)
    cb:SetScript("OnClick", function(self) DB.notify = self:GetChecked() and true or false end)
    cb:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Chat alerts", 1, 1, 1)
        GameTooltip:AddLine("Tell me in chat when a synced friend comes online, levels up or is nearby.", nil, nil, nil, true)
        GameTooltip:Show()
    end)
    cb:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local cbText = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    cbText:SetPoint("LEFT", cb, "RIGHT", 2, 0)
    cbText:SetText("Chat alerts")
    f.notify = cb

    f.status = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.status:SetPoint("LEFT", cbText, "RIGHT", 16, 0)

    local ping = MakeButton(f, "Refresh", 90, 22,
        "Look for online friends with FriendsSync now, instead of waiting for the next automatic check.")
    ping:SetPoint("BOTTOMRIGHT", -12, 12)
    ping:SetScript("OnClick", PingFriends)

    f:SetScript("OnShow", function() RefreshUI() end)
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
        bits[#bits + 1] = WhereText(p)
        local dist = Distance(p)
        if dist then bits[#bits + 1] = ("%d yd away"):format(dist) end
    else
        bits[#bits + 1] = GREY .. "Offline, seen " .. Ago(p.seenAt and time() - p.seenAt) .. "|r"
    end
    c.sub:SetText(table.concat(bits, GREY .. "  ·  |r"))
    c.tip:SetText(GOLD .. "Tip:|r " .. BestTip(p))

    c.myBar.Set("You", tonumber(Plain(UnitLevel("player"))), tonumber(Plain(UnitXP("player"))),
        tonumber(Plain(UnitXPMax("player"))), tonumber(SafeCall(GetXPExhaustion)))
    c.theirBar.Set(ColoredName(p), p.level, p.xp, p.xpMax, p.rested)

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

    c.questSummary:SetText(QuestSummary(p))
    c.quests:SetText(QuestListText(p))
    c.questChild:SetHeight(c.quests:GetStringHeight() + 10)

    UI.invite:SetEnabled(active)
    UI.whisper:SetEnabled(active)
    UI.waypoint:SetEnabled((active and p.mapID and p.mx) and true or false)
    local canMatch = p.guideName and type(_G.RXP) == "table" and not (diff and math.abs(diff) <= STEP_SYNC_RANGE)
    UI.match:SetEnabled(canMatch and true or false)
end

function RefreshUI()
    if not UI or not UI:IsShown() then return end
    UI.notify:SetChecked(DB.notify)

    local list = SortedPeers()
    if selectedKey and not peers[selectedKey] then selectedKey = nil end
    if not selectedKey and list[1] then selectedKey = list[1].key end

    local online = 0
    for _, p in ipairs(list) do
        if IsActive(p) then online = online + 1 end
    end
    local friends = 0
    for _ in pairs(targets) do friends = friends + 1 end
    UI.onlineCount:SetText(online .. " online")
    UI.status:SetText(("Synced with %d of %s"):format(online, Plural(friends, "online friend")))

    FauxScrollFrame_Update(UI.scroll, #list, CARDS, CARD_H)
    local offset = FauxScrollFrame_GetOffset(UI.scroll)
    for i, card in ipairs(UI.cards) do
        local p = list[i + offset]
        if p then
            FillCard(card, p)
        else
            card.key = nil
            card:Hide()
        end
    end

    FillDetail(selectedKey and peers[selectedKey])
end

local function ToggleUI()
    UI = UI or CreateUI()
    UI:SetShown(not UI:IsShown())
end

------------------------------------------------------------------------
-- Minimap button and AddOns menu entry
------------------------------------------------------------------------

local minimapButton

local function LauncherClick(mouse)
    if mouse == "RightButton" then
        DB.notify = not DB.notify
        Print("Chat alerts " .. (DB.notify and "on." or "off."))
        if RefreshUI then RefreshUI() end
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
                GameTooltip:AddDoubleLine(ColoredName(p), ("Lv %s  %s"):format(p.level or "?", p.zone ~= "" and p.zone or "?"),
                    1, 1, 1, 0.8, 0.8, 0.8)
            end
        end
    end
    if n == 0 then GameTooltip:AddLine("No friends synced right now.", 0.6, 0.6, 0.6) end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: open window", 0.5, 0.5, 0.5)
    GameTooltip:AddLine("Right-click: chat alerts " .. (DB.notify and "off" or "on"), 0.5, 0.5, 0.5)
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

local function UpdateMinimapButton()
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
        icon:SetTexture(ICON)
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
-- Events / init
------------------------------------------------------------------------

local SESSION_FIELDS = { "online", "lastSeen", "announced", "nearby", "nearbyAt", "qbuf" }

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
        Try(C_ChatInfo.RegisterAddonMessagePrefix, COMM)
        local addFilter = (ChatFrameUtil and ChatFrameUtil.AddMessageEventFilter) or ChatFrame_AddMessageEventFilter
        if addFilter then Try(addFilter, "CHAT_MSG_SYSTEM", SystemFilter) end
        if C_FriendList and C_FriendList.ShowFriends then Try(C_FriendList.ShowFriends) end
        Try(ScanQuests)
        Try(function() guideSig = BuildGuide() end)
        Try(RefreshTargets)
        Try(UpdateMinimapButton)

    elseif event == "CHAT_MSG_ADDON" then
        local prefix, text, channel, sender = ...
        if Plain(prefix) ~= COMM then return end
        text, channel, sender = Plain(text), Plain(channel), Plain(sender)
        if type(text) == "string" and type(sender) == "string" and channel == "WHISPER" then
            Try(OnWhisperAddon, text, sender)
        else
            Debug("ignored addon message: channel " .. tostring(channel) .. ", sender " .. tostring(sender) .. " (secret/unknown)")
        end

    elseif event == "BN_CHAT_MSG_ADDON" then
        local prefix, text, _, senderID = ...
        if Plain(prefix) ~= COMM then return end
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
        DB.notify = not DB.notify
        Print("Chat alerts " .. (DB.notify and "enabled." or "disabled."))
        if RefreshUI then RefreshUI() end
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
            :format(BUILD, tostring(myKey), b, w, active, #sendQueue))
        if lastError then Print("Last error: " .. lastError) end
    elseif cmd == "minimap" then
        DB.minimapHide = not DB.minimapHide
        Try(UpdateMinimapButton)
        Print("Minimap button " .. (DB.minimapHide and "hidden." or "shown."))
    elseif cmd == "debug" then
        DB.debug = not DB.debug
        Print("Debug " .. (DB.debug and "on." or "off."))
    else
        Print("/fsync - open window | /fsync ping | /fsync list | /fsync status | /fsync notify | /fsync minimap | /fsync forget <name> | /fsync debug")
    end
end
