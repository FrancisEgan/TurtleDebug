----------------------------------------------------------------------
--  TurtleDebug  –  minimal Lua variable inspector for Turtle WoW
--  /debug            toggle the window
--  /debug <var>      inspect a global variable immediately
----------------------------------------------------------------------

local INDENT = "    "   -- 4 spaces per nesting level
local MAX_DEPTH = 12    -- guard against infinite recursion
local MAX_KEYS  = 500   -- cap per table to keep output sane

----------------------------------------------------------------------
--  Pretty-printer  (JSON-ish style)
----------------------------------------------------------------------

local function TypeColor(v)
    local t = type(v)
    if t == "string"   then return "|cff98c379"  end  -- green
    if t == "number"   then return "|cffd19a66"  end  -- orange
    if t == "boolean"  then return "|cff56b6c2"  end  -- cyan
    if t == "function" then return "|cffc678dd"  end  -- purple
    if t == "table"    then return "|cffe5c07b"  end  -- yellow
    return "|cffabb2bf"                                -- grey
end

local function SortedKeys(tbl)
    local keys = {}
    for k in pairs(tbl) do
        table.insert(keys, k)
    end
    table.sort(keys, function(a, b)
        if type(a) == type(b) then
            if type(a) == "number" then return a < b end
            return tostring(a) < tostring(b)
        end
        if type(a) == "number" then return true end
        return false
    end)
    return keys
end

local function FormatValue(v)
    local t = type(v)
    if t == "string" then
        local safe = string.gsub(v, "|", "||")
        return TypeColor(v) .. "\"" .. safe .. "\"|r"
    end
    if t == "boolean" then return TypeColor(v) .. tostring(v) .. "|r" end
    if t == "number"  then return TypeColor(v) .. tostring(v) .. "|r" end
    if t == "function" then return TypeColor(v) .. "function()|r" end
    if t == "userdata" then return "|cffabb2bf<userdata>|r" end
    return "|cffabb2bf" .. tostring(v) .. "|r"
end

local function PrettyPrint(val, depth, visited, lines)
    depth   = depth   or 0
    visited = visited or {}
    lines   = lines   or {}

    if type(val) ~= "table" then
        table.insert(lines, string.rep(INDENT, depth) .. FormatValue(val))
        return lines
    end
    if visited[val] then
        table.insert(lines, string.rep(INDENT, depth) .. "|cffe06c75<circular reference>|r")
        return lines
    end
    if depth >= MAX_DEPTH then
        table.insert(lines, string.rep(INDENT, depth) .. "|cffe06c75<max depth>|r")
        return lines
    end
    visited[val] = true

    local keys = SortedKeys(val)
    if table.getn(keys) == 0 then
        table.insert(lines, string.rep(INDENT, depth) .. TypeColor(val) .. "{}|r")
        return lines
    end

    local prefix = string.rep(INDENT, depth)
    table.insert(lines, prefix .. "{")

    local count = 0
    for _, k in ipairs(keys) do
        count = count + 1
        if count > MAX_KEYS then
            table.insert(lines, prefix .. INDENT ..
                "|cffe06c75... (" .. (table.getn(keys) - MAX_KEYS) .. " more keys)|r")
            break
        end
        local v = val[k]
        local keyStr
        if type(k) == "number" then
            keyStr = "|cffd19a66[" .. k .. "]|r"
        else
            keyStr = "|cff61afef" .. tostring(k) .. "|r"
        end
        if type(v) == "table" then
            table.insert(lines, prefix .. INDENT .. keyStr .. " = ")
            PrettyPrint(v, depth + 1, visited, lines)
        else
            table.insert(lines, prefix .. INDENT .. keyStr .. " = " .. FormatValue(v))
        end
    end
    table.insert(lines, prefix .. "}")
    return lines
end

----------------------------------------------------------------------
--  Plain-text serialiser (for clipboard)
----------------------------------------------------------------------

local function PlainValue(v)
    local t = type(v)
    if t == "string"   then return "\"" .. v .. "\"" end
    if t == "function" then return "function()" end
    if t == "userdata" then return "<userdata>" end
    return tostring(v)
end

local function PlainPrint(val, depth, visited, lines)
    depth   = depth   or 0
    visited = visited or {}
    lines   = lines   or {}

    if type(val) ~= "table" then
        table.insert(lines, string.rep(INDENT, depth) .. PlainValue(val))
        return lines
    end
    if visited[val] then
        table.insert(lines, string.rep(INDENT, depth) .. "<circular reference>")
        return lines
    end
    if depth >= MAX_DEPTH then
        table.insert(lines, string.rep(INDENT, depth) .. "<max depth>")
        return lines
    end
    visited[val] = true

    local keys = SortedKeys(val)
    if table.getn(keys) == 0 then
        table.insert(lines, string.rep(INDENT, depth) .. "{}")
        return lines
    end

    local prefix = string.rep(INDENT, depth)
    table.insert(lines, prefix .. "{")
    local count = 0
    for _, k in ipairs(keys) do
        count = count + 1
        if count > MAX_KEYS then
            table.insert(lines, prefix .. INDENT ..
                "... (" .. (table.getn(keys) - MAX_KEYS) .. " more keys)")
            break
        end
        local v = val[k]
        local keyStr
        if type(k) == "number" then keyStr = "[" .. k .. "]"
        else keyStr = tostring(k) end
        if type(v) == "table" then
            table.insert(lines, prefix .. INDENT .. keyStr .. " =")
            PlainPrint(v, depth + 1, visited, lines)
        else
            table.insert(lines, prefix .. INDENT .. keyStr .. " = " .. PlainValue(v))
        end
    end
    table.insert(lines, prefix .. "}")
    return lines
end

----------------------------------------------------------------------
--  Resolve a dotted path  ("UnitName"  or  "MyAddon.settings.flag")
--  Also supports expressions with parens: GetPlayerMapPosition("player")
----------------------------------------------------------------------

local function Resolve(path)
    -- If it looks like an expression (has parentheses), evaluate it
    if string.find(path, "%(") then
        local fn = loadstring("return " .. path)
        if fn then
            local ok, r1, r2, r3, r4, r5 = pcall(fn)
            if ok then
                -- Pack multiple return values into a table if more than one
                if r2 ~= nil then
                    return { r1, r2, r3, r4, r5 }, true
                else
                    return r1, true
                end
            else
                return nil, false
            end
        else
            return nil, false
        end
    end

    -- Simple dotted path
    local parts = {}
    for part in string.gfind(path, "[^%.]+") do
        table.insert(parts, part)
    end
    local obj = getglobal(parts[1])
    if obj == nil and table.getn(parts) == 1 then
        return nil, false
    end
    for i = 2, table.getn(parts) do
        if type(obj) ~= "table" then return nil, false end
        obj = obj[parts[i]]
    end
    return obj, true
end

----------------------------------------------------------------------
--  Build all frames in pure Lua  (no XML needed)
----------------------------------------------------------------------

local plainTextCache = ""
local watchList = {}   -- ordered list of { name = "...", collapsed = false }
local activeTab = "inspect"

-- Main frame
local frame = CreateFrame("Frame", "TurtleDebugFrame", UIParent)
frame:SetWidth(520)
frame:SetHeight(440)
frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
frame:SetFrameStrata("DIALOG")
frame:SetMovable(true)
frame:EnableMouse(true)
frame:SetToplevel(true)
frame:RegisterForDrag("LeftButton")
frame:SetScript("OnDragStart", function() this:StartMoving() end)
frame:SetScript("OnDragStop",  function() this:StopMovingOrSizing() end)
frame:SetBackdrop({
    bgFile   = "Interface\\DialogFrame\\UI-DialogBox-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    tile     = true, tileSize = 16, edgeSize = 16,
    insets   = { left = 4, right = 4, top = 4, bottom = 4 },
})
frame:SetBackdropColor(0.08, 0.08, 0.12, 0.95)
frame:SetBackdropBorderColor(0.35, 0.45, 0.65, 0.8)
frame:SetResizable(true)
frame:SetMinResize(390, 280)
frame:SetMaxResize(900, 800)
frame:Hide()

-- Title
local title = frame:CreateFontString("TurtleDebugTitle", "OVERLAY", "GameFontNormalLarge")
title:SetPoint("TOP", frame, "TOP", 0, -12)
title:SetText("|cffabd473Turtle Debug|r")

-- Close button
local closeBtn = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
closeBtn:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

-- Resize grip (bottom-right corner, invisible but easy to grab)
local resizeGrip = CreateFrame("Frame", nil, frame)
resizeGrip:SetWidth(24)
resizeGrip:SetHeight(24)
resizeGrip:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -2, 2)
resizeGrip:EnableMouse(true)
resizeGrip:SetFrameLevel(frame:GetFrameLevel() + 10)

resizeGrip:SetScript("OnMouseDown", function()
    frame:StartSizing("BOTTOMRIGHT")
end)
resizeGrip:SetScript("OnMouseUp", function()
    frame:StopMovingOrSizing()
end)

----------------------------------------------------------------------
--  Tab buttons
----------------------------------------------------------------------

local function MakeTab(name, label, xOff)
    local tab = CreateFrame("Button", name, frame)
    tab:SetWidth(90)
    tab:SetHeight(24)
    tab:SetPoint("TOPLEFT", frame, "TOPLEFT", xOff, -30)

    local bg = tab:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints(tab)
    bg:SetTexture(0, 0, 0, 0.4)
    tab.bg = bg

    local text = tab:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    text:SetPoint("CENTER", tab, "CENTER", 0, 0)
    text:SetText(label)
    tab.label = text

    tab:SetScript("OnEnter", function()
        if tab.active then return end
        tab.bg:SetTexture(0.2, 0.3, 0.5, 0.4)
    end)
    tab:SetScript("OnLeave", function()
        if tab.active then return end
        tab.bg:SetTexture(0, 0, 0, 0.4)
    end)

    tab.active = false
    return tab
end

local tabInspect = MakeTab("TurtleDebugTabInspect", "Inspect", 12)
local tabWatch   = MakeTab("TurtleDebugTabWatch",   "Watch",   106)

local function SetActiveTab(which)
    activeTab = which
    if which == "inspect" then
        tabInspect.active = true
        tabInspect.bg:SetTexture(0.15, 0.25, 0.45, 0.7)
        tabInspect.label:SetTextColor(1, 1, 1)
        tabWatch.active = false
        tabWatch.bg:SetTexture(0, 0, 0, 0.4)
        tabWatch.label:SetTextColor(0.6, 0.6, 0.6)
    else
        tabWatch.active = true
        tabWatch.bg:SetTexture(0.15, 0.25, 0.45, 0.7)
        tabWatch.label:SetTextColor(1, 1, 1)
        tabInspect.active = false
        tabInspect.bg:SetTexture(0, 0, 0, 0.4)
        tabInspect.label:SetTextColor(0.6, 0.6, 0.6)
    end
end

----------------------------------------------------------------------
--  Helper: scrollable mouse wheel
----------------------------------------------------------------------

local function AddMouseWheel(sf)
    sf:EnableMouseWheel(true)
    sf:SetScript("OnMouseWheel", function()
        local cur = this:GetVerticalScroll()
        local max = this:GetVerticalScrollRange()
        local step = 40
        if arg1 > 0 then
            this:SetVerticalScroll(math.max(0, cur - step))
        else
            this:SetVerticalScroll(math.min(max, cur + step))
        end
    end)
end

----------------------------------------------------------------------
--  INSPECT TAB  (container frame)
----------------------------------------------------------------------

local inspectPanel = CreateFrame("Frame", "TurtleDebugInspectPanel", frame)
inspectPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -54)
inspectPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)

-- "Variable / expression:" label
local label = inspectPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
label:SetPoint("TOPLEFT", inspectPanel, "TOPLEFT", 16, 0)
label:SetText("|cffccccccVariable / expression:|r")

-- Inspect button (anchored to the right)
local inspectBtn = CreateFrame("Button", nil, inspectPanel, "UIPanelButtonTemplate")
inspectBtn:SetWidth(80)
inspectBtn:SetHeight(22)
inspectBtn:SetPoint("TOPRIGHT", inspectPanel, "TOPRIGHT", -12, -16)
inspectBtn:SetText("Inspect")
inspectBtn:SetScript("OnClick", function() TurtleDebug_Inspect() end)

-- Input editbox (fills space between left edge and Inspect button)
local input = CreateFrame("EditBox", "TurtleDebugInput", inspectPanel)
input:SetHeight(20)
input:SetPoint("TOPLEFT", inspectPanel, "TOPLEFT", 16, -16)
input:SetPoint("RIGHT", inspectBtn, "LEFT", -6, 0)
input:SetAutoFocus(false)
input:SetMaxLetters(300)
input:SetFontObject(ChatFontNormal)

local inputBG = input:CreateTexture(nil, "BACKGROUND")
inputBG:SetPoint("TOPLEFT", input, "TOPLEFT", -4, 4)
inputBG:SetPoint("BOTTOMRIGHT", input, "BOTTOMRIGHT", 4, -4)
inputBG:SetTexture(0, 0, 0, 0.5)

input:SetScript("OnEnterPressed", function() TurtleDebug_Inspect() end)
input:SetScript("OnEscapePressed", function() this:ClearFocus() end)

-- Colored output scroll
local scroll = CreateFrame("ScrollFrame", "TurtleDebugScroll", inspectPanel, "UIPanelScrollFrameTemplate")
scroll:SetPoint("TOPLEFT", inspectPanel, "TOPLEFT", 12, -44)
scroll:SetPoint("BOTTOMRIGHT", inspectPanel, "BOTTOMRIGHT", -32, 40)
AddMouseWheel(scroll)

local scrollChild = CreateFrame("Frame", "TurtleDebugScrollChild", scroll)
scrollChild:SetWidth(460)
scrollChild:SetHeight(300)

local displayFS = scrollChild:CreateFontString("TurtleDebugDisplay", "OVERLAY", "GameFontHighlightSmall")
displayFS:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, 0)
displayFS:SetWidth(460)
displayFS:SetJustifyH("LEFT")
displayFS:SetJustifyV("TOP")
scroll:SetScrollChild(scrollChild)

-- Copy scroll (hidden until Select All)
local copyScroll = CreateFrame("ScrollFrame", "TurtleDebugCopyScroll", inspectPanel, "UIPanelScrollFrameTemplate")
copyScroll:SetPoint("TOPLEFT", inspectPanel, "TOPLEFT", 12, -44)
copyScroll:SetPoint("BOTTOMRIGHT", inspectPanel, "BOTTOMRIGHT", -32, 40)
AddMouseWheel(copyScroll)
copyScroll:Hide()

local copyBox = CreateFrame("EditBox", "TurtleDebugCopyBox", copyScroll)
copyBox:SetMultiLine(true)
copyBox:SetMaxLetters(0)
copyBox:EnableMouse(true)
copyBox:SetAutoFocus(false)
copyBox:SetFontObject(GameFontHighlightSmall)
copyBox:SetWidth(460)
copyBox:SetHeight(300)
copyBox:SetScript("OnEscapePressed", function()
    this:ClearFocus()
    TurtleDebugCopyScroll:Hide()
    TurtleDebugScroll:Show()
    inspectCopying = false
    iCopyBtn:SetText("Copy")
end)
copyScroll:SetScrollChild(copyBox)

-- Inspect bottom buttons
local inspectCopying = false
local iCopyBtn = CreateFrame("Button", nil, inspectPanel, "UIPanelButtonTemplate")
iCopyBtn:SetWidth(70)
iCopyBtn:SetHeight(22)
iCopyBtn:SetPoint("BOTTOMRIGHT", inspectPanel, "BOTTOMRIGHT", -12, 10)
iCopyBtn:SetText("Copy")
iCopyBtn:SetScript("OnClick", function()
    if inspectCopying then
        -- Done mode: close copy overlay
        TurtleDebugCopyBox:ClearFocus()
        TurtleDebugCopyScroll:Hide()
        TurtleDebugScroll:Show()
        inspectCopying = false
        iCopyBtn:SetText("Copy")
    else
        -- Copy mode: open copy overlay
        if plainTextCache == "" then return end
        TurtleDebugScroll:Hide()
        TurtleDebugCopyBox:SetText(plainTextCache)
        local _, fontH = TurtleDebugCopyBox:GetFont()
        fontH = fontH or 12
        local numLines = 1
        for _ in string.gfind(plainTextCache, "\n") do numLines = numLines + 1 end
        TurtleDebugCopyBox:SetHeight(math.max(300, numLines * (fontH + 2)))
        TurtleDebugCopyScroll:UpdateScrollChildRect()
        TurtleDebugCopyScroll:SetVerticalScroll(0)
        TurtleDebugCopyScroll:Show()
        TurtleDebugCopyBox:HighlightText()
        TurtleDebugCopyBox:SetFocus()
        inspectCopying = true
        iCopyBtn:SetText("Done")
    end
end)

local iClearBtn = CreateFrame("Button", nil, inspectPanel, "UIPanelButtonTemplate")
iClearBtn:SetWidth(70)
iClearBtn:SetHeight(22)
iClearBtn:SetPoint("RIGHT", iCopyBtn, "LEFT", -6, 0)
iClearBtn:SetText("Clear")
iClearBtn:SetScript("OnClick", function()
    TurtleDebugDisplay:SetText("")
    TurtleDebugCopyBox:SetText("")
    TurtleDebugCopyScroll:Hide()
    TurtleDebugScroll:Show()
    plainTextCache = ""
    inspectCopying = false
    iCopyBtn:SetText("Copy")
end)

----------------------------------------------------------------------
--  WATCH TAB  –  collapsible per-variable sections
----------------------------------------------------------------------

local watchPanel = CreateFrame("Frame", "TurtleDebugWatchPanel", frame)
watchPanel:SetPoint("TOPLEFT", frame, "TOPLEFT", 0, -54)
watchPanel:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
watchPanel:Hide()

-- "Add variable to watch:" label
local wLabel = watchPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
wLabel:SetPoint("TOPLEFT", watchPanel, "TOPLEFT", 16, 0)
wLabel:SetText("|cffccccccAdd variable or function call to watch (supports comma-separated list):|r")

-- Add button (anchored to the right)
local wAddBtn = CreateFrame("Button", nil, watchPanel, "UIPanelButtonTemplate")
wAddBtn:SetWidth(60)
wAddBtn:SetHeight(22)
wAddBtn:SetPoint("TOPRIGHT", watchPanel, "TOPRIGHT", -12, -16)
wAddBtn:SetText("Add")
wAddBtn:SetScript("OnClick", function() TurtleDebug_WatchAdd() end)

-- Watch input (fills space between left edge and Add button)
local wInput = CreateFrame("EditBox", "TurtleDebugWatchInput", watchPanel)
wInput:SetHeight(20)
wInput:SetPoint("TOPLEFT", watchPanel, "TOPLEFT", 16, -16)
wInput:SetPoint("RIGHT", wAddBtn, "LEFT", -6, 0)
wInput:SetAutoFocus(false)
wInput:SetMaxLetters(300)
wInput:SetFontObject(ChatFontNormal)

local wInputBG = wInput:CreateTexture(nil, "BACKGROUND")
wInputBG:SetPoint("TOPLEFT", wInput, "TOPLEFT", -4, 4)
wInputBG:SetPoint("BOTTOMRIGHT", wInput, "BOTTOMRIGHT", 4, -4)
wInputBG:SetTexture(0, 0, 0, 0.5)

wInput:SetScript("OnEscapePressed", function() this:ClearFocus() end)
wInput:SetScript("OnEnterPressed", function() TurtleDebug_WatchAdd() end)

-- Main scroll for watch sections
local wScroll = CreateFrame("ScrollFrame", "TurtleDebugWatchScroll", watchPanel, "UIPanelScrollFrameTemplate")
wScroll:SetPoint("TOPLEFT", watchPanel, "TOPLEFT", 12, -44)
wScroll:SetPoint("BOTTOMRIGHT", watchPanel, "BOTTOMRIGHT", -32, 40)
AddMouseWheel(wScroll)

local wScrollChild = CreateFrame("Frame", "TurtleDebugWatchScrollChild", wScroll)
wScrollChild:SetWidth(460)
wScrollChild:SetHeight(300)
wScroll:SetScrollChild(wScrollChild)

-- Pool of section frames (recycled on refresh)
local watchSections = {}  -- { frame, header, arrow, body, copyBtn, removeBtn, copyScroll, copyBox }

-- Bottom buttons
local wClearBtn = CreateFrame("Button", nil, watchPanel, "UIPanelButtonTemplate")
wClearBtn:SetWidth(80)
wClearBtn:SetHeight(22)
wClearBtn:SetPoint("BOTTOMRIGHT", watchPanel, "BOTTOMRIGHT", -12, 10)
wClearBtn:SetText("Clear All")
wClearBtn:SetScript("OnClick", function()
    watchList = {}
    TurtleDebug_WatchRefresh()
end)

local wRefreshAllBtn = CreateFrame("Button", nil, watchPanel, "UIPanelButtonTemplate")
wRefreshAllBtn:SetWidth(80)
wRefreshAllBtn:SetHeight(22)
wRefreshAllBtn:SetPoint("RIGHT", wClearBtn, "LEFT", -6, 0)
wRefreshAllBtn:SetText("Refresh All")
wRefreshAllBtn:SetScript("OnClick", function() TurtleDebug_WatchRefresh() end)

-- Auto-refresh toggle
local watchAutoRefresh = false
local watchAutoElapsed = 0
local WATCH_AUTO_INTERVAL = 0.5  -- seconds between refreshes

local wAutoBtn = CreateFrame("Button", nil, watchPanel, "UIPanelButtonTemplate")
wAutoBtn:SetWidth(105)
wAutoBtn:SetHeight(22)
wAutoBtn:SetPoint("RIGHT", wRefreshAllBtn, "LEFT", -6, 0)
wAutoBtn:SetText("|cff888888Live Updates|r")

local function SetAutoRefresh(on)
    watchAutoRefresh = on
    watchAutoElapsed = 0
    if on then
        wAutoBtn:SetText("|cffabd473Live Updates|r")
    else
        wAutoBtn:SetText("|cff888888Live Updates|r")
    end
end

wAutoBtn:SetScript("OnClick", function()
    SetAutoRefresh(not watchAutoRefresh)
end)

-- OnUpdate handler for auto-refresh
watchPanel:SetScript("OnUpdate", function()
    if not watchAutoRefresh then return end
    watchAutoElapsed = watchAutoElapsed + arg1
    if watchAutoElapsed >= WATCH_AUTO_INTERVAL then
        watchAutoElapsed = 0
        TurtleDebug_WatchRefresh()
    end
end)

----------------------------------------------------------------------
--  Watch section builder
----------------------------------------------------------------------

local SECTION_WIDTH = 448

local function GetOrCreateSection(index)
    if watchSections[index] then return watchSections[index] end

    local sec = {}

    -- Container
    sec.frame = CreateFrame("Frame", "TurtleDebugWatchSec" .. index, wScrollChild)
    sec.frame:SetWidth(SECTION_WIDTH)
    sec.frame:SetHeight(24)  -- will be resized

    -- Header background
    sec.headerBG = sec.frame:CreateTexture(nil, "BACKGROUND")
    sec.headerBG:SetHeight(22)
    sec.headerBG:SetPoint("TOPLEFT", sec.frame, "TOPLEFT", 0, 0)
    sec.headerBG:SetPoint("TOPRIGHT", sec.frame, "TOPRIGHT", 0, 0)
    sec.headerBG:SetTexture(0.15, 0.2, 0.35, 0.6)

    -- Arrow indicator
    sec.arrow = sec.frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec.arrow:SetPoint("LEFT", sec.frame, "TOPLEFT", 4, -11)
    sec.arrow:SetText("|cffccccccv|r")

    -- Header button (clickable label)
    sec.header = CreateFrame("Button", nil, sec.frame)
    sec.header:SetHeight(22)
    sec.header:SetPoint("TOPLEFT", sec.frame, "TOPLEFT", 16, 0)
    sec.header:SetPoint("TOPRIGHT", sec.frame, "TOPRIGHT", -50, 0)

    sec.headerText = sec.header:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec.headerText:SetPoint("LEFT", sec.header, "LEFT", 0, 0)
    sec.headerText:SetJustifyH("LEFT")

    sec.header:SetScript("OnClick", function()
        local entry = watchList[sec.watchIndex]
        if entry then entry.collapsed = not entry.collapsed end
        TurtleDebug_WatchRefresh()
    end)
    sec.header:SetScript("OnEnter", function()
        sec.headerBG:SetTexture(0.2, 0.3, 0.5, 0.7)
    end)
    sec.header:SetScript("OnLeave", function()
        sec.headerBG:SetTexture(0.15, 0.2, 0.35, 0.6)
    end)

    -- Remove [X] button
    sec.removeBtn = CreateFrame("Button", nil, sec.frame)
    sec.removeBtn:SetWidth(18)
    sec.removeBtn:SetHeight(18)
    sec.removeBtn:SetPoint("RIGHT", sec.frame, "TOPRIGHT", -2, -11)
    local xText = sec.removeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    xText:SetPoint("CENTER", sec.removeBtn, "CENTER", 0, 0)
    xText:SetText("|cffe06c75X|r")
    sec.removeBtn:SetScript("OnClick", function()
        local idx = sec.watchIndex
        if idx and idx <= table.getn(watchList) then
            table.remove(watchList, idx)
            TurtleDebug_WatchRefresh()
        end
    end)
    sec.removeBtn:SetScript("OnEnter", function()
        xText:SetText("|cffff4444X|r")
    end)
    sec.removeBtn:SetScript("OnLeave", function()
        xText:SetText("|cffe06c75X|r")
    end)

    -- Copy button
    sec.copyBtn = CreateFrame("Button", nil, sec.frame)
    sec.copyBtn:SetWidth(36)
    sec.copyBtn:SetHeight(18)
    sec.copyBtn:SetPoint("RIGHT", sec.removeBtn, "LEFT", -2, 0)
    sec.copyBtnText = sec.copyBtn:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    sec.copyBtnText:SetPoint("CENTER", sec.copyBtn, "CENTER", 0, 0)
    sec.copyBtnText:SetText("|cffabb2bfCopy|r")
    sec.copying = false
    sec.copyBtn:SetScript("OnEnter", function()
        if sec.copying then
            sec.copyBtnText:SetText("|cffffffffDone|r")
        else
            sec.copyBtnText:SetText("|cffffffffCopy|r")
        end
    end)
    sec.copyBtn:SetScript("OnLeave", function()
        if sec.copying then
            sec.copyBtnText:SetText("|cff98c379Done|r")
        else
            sec.copyBtnText:SetText("|cffabb2bfCopy|r")
        end
    end)

    -- Body: FontString for colored display
    sec.body = sec.frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    sec.body:SetPoint("TOPLEFT", sec.frame, "TOPLEFT", 8, -24)
    sec.body:SetWidth(SECTION_WIDTH - 16)
    sec.body:SetJustifyH("LEFT")
    sec.body:SetJustifyV("TOP")

    -- Copy overlay (per-section): an EditBox that appears on "C" click
    sec.copyFrame = CreateFrame("Frame", nil, sec.frame)
    sec.copyFrame:SetPoint("TOPLEFT", sec.body, "TOPLEFT", 0, 0)
    sec.copyFrame:SetPoint("BOTTOMRIGHT", sec.frame, "BOTTOMRIGHT", 0, 0)
    sec.copyFrame:SetBackdrop({
        bgFile = "Interface\\DialogFrame\\UI-DialogBox-Background",
        edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
        tile = true, tileSize = 16, edgeSize = 12,
        insets = { left = 3, right = 3, top = 3, bottom = 3 },
    })
    sec.copyFrame:SetBackdropColor(0.05, 0.05, 0.1, 0.95)
    sec.copyFrame:Hide()

    sec.copyEdit = CreateFrame("EditBox", nil, sec.copyFrame)
    sec.copyEdit:SetMultiLine(true)
    sec.copyEdit:SetMaxLetters(0)
    sec.copyEdit:EnableMouse(true)
    sec.copyEdit:SetAutoFocus(false)
    sec.copyEdit:SetFontObject(GameFontHighlightSmall)
    sec.copyEdit:SetPoint("TOPLEFT", sec.copyFrame, "TOPLEFT", 4, -4)
    sec.copyEdit:SetPoint("BOTTOMRIGHT", sec.copyFrame, "BOTTOMRIGHT", -4, 4)
    sec.copyEdit:SetScript("OnEscapePressed", function()
        this:ClearFocus()
        sec.copyFrame:Hide()
        sec.body:Show()
        sec.copying = false
        sec.copyBtnText:SetText("|cffabb2bfCopy|r")
    end)

    sec.copyBtn:SetScript("OnClick", function()
        if sec.copying then
            -- "Done" mode: close copy overlay
            sec.copyEdit:ClearFocus()
            sec.copyFrame:Hide()
            sec.body:Show()
            sec.copying = false
            sec.copyBtnText:SetText("|cffabb2bfCopy|r")
        else
            -- "Copy" mode: open copy overlay
            if sec.plainText and sec.plainText ~= "" then
                sec.body:Hide()
                sec.copyEdit:SetText(sec.plainText)
                local bh = sec.body:GetHeight()
                sec.copyFrame:SetHeight(math.max(30, bh))
                sec.copyFrame:Show()
                sec.copyEdit:HighlightText()
                sec.copyEdit:SetFocus()
                sec.copying = true
                sec.copyBtnText:SetText("|cff98c379Done|r")
            end
        end
    end)

    sec.watchIndex = index
    sec.plainText = ""

    watchSections[index] = sec
    return sec
end

----------------------------------------------------------------------
--  Tab switching
----------------------------------------------------------------------

local function ShowTab(which)
    SetActiveTab(which)
    if which == "inspect" then
        watchPanel:Hide()
        inspectPanel:Show()
    else
        inspectPanel:Hide()
        TurtleDebugCopyScroll:Hide()
        watchPanel:Show()
        TurtleDebug_WatchRefresh()
    end
end

tabInspect:SetScript("OnClick", function() ShowTab("inspect") end)
tabWatch:SetScript("OnClick",   function() ShowTab("watch") end)
SetActiveTab("inspect")

----------------------------------------------------------------------
--  Slash commands
----------------------------------------------------------------------

SLASH_TURTLEDEBUG1 = "/debug"
SlashCmdList["TURTLEDEBUG"] = function(msg)
    msg = msg or ""
    msg = string.gsub(msg, "^%s*(.-)%s*$", "%1")
    -- "/debug watch" switches to watch tab
    if string.lower(msg) == "watch" then
        TurtleDebugFrame:Show()
        ShowTab("watch")
        return
    end
    if msg ~= "" then
        TurtleDebugInput:SetText(msg)
        TurtleDebugFrame:Show()
        ShowTab("inspect")
        TurtleDebug_Inspect()
    else
        if TurtleDebugFrame:IsVisible() then
            TurtleDebugFrame:Hide()
        else
            TurtleDebugFrame:Show()
        end
    end
end

----------------------------------------------------------------------
--  Core: inspect the variable
----------------------------------------------------------------------

function TurtleDebug_Inspect()
    local path = TurtleDebugInput:GetText() or ""
    path = string.gsub(path, "^%s*(.-)%s*$", "%1")
    if path == "" then return end

    TurtleDebugInput:ClearFocus()

    local val, found = Resolve(path)

    local colorLines
    if not found then
        colorLines = { "|cffe06c75nil|r  (not found)" }
        plainTextCache = path .. " = nil  (not found)"
    else
        colorLines = {}
        table.insert(colorLines, "|cff61afef" .. path .. "|r =")
        PrettyPrint(val, 0, {}, colorLines)

        local plain = { path .. " =" }
        PlainPrint(val, 0, {}, plain)
        plainTextCache = table.concat(plain, "\n")
    end

    local colorText = table.concat(colorLines, "\n")

    -- Show colored display via FontString
    TurtleDebugCopyScroll:Hide()
    TurtleDebugScroll:Show()
    TurtleDebugDisplay:SetText(colorText)

    -- Resize scroll child to fit content
    local textHeight = TurtleDebugDisplay:GetHeight()
    if textHeight and textHeight > 0 then
        TurtleDebugScrollChild:SetHeight(textHeight + 10)
    else
        TurtleDebugScrollChild:SetHeight(300)
    end
    TurtleDebugScroll:UpdateScrollChildRect()
    TurtleDebugScroll:SetVerticalScroll(0)
end



----------------------------------------------------------------------
--  Watch: add variable to list
----------------------------------------------------------------------

function TurtleDebug_WatchAdd()
    local raw = TurtleDebugWatchInput:GetText() or ""
    raw = string.gsub(raw, "^%s*(.-)%s*$", "%1")
    if raw == "" then return end

    -- Split on commas and add each entry
    local added = false
    for token in string.gfind(raw .. ",", "([^,]+),") do
        local path = string.gsub(token, "^%s*(.-)%s*$", "%1")
        if path ~= "" then
            -- Check for duplicates
            local dup = false
            for _, entry in ipairs(watchList) do
                if entry.name == path then dup = true; break end
            end
            if not dup then
                table.insert(watchList, { name = path, collapsed = false })
                added = true
            end
        end
    end

    TurtleDebugWatchInput:SetText("")
    TurtleDebugWatchInput:ClearFocus()
    if added then TurtleDebug_WatchRefresh() end
end

----------------------------------------------------------------------
--  Watch: refresh all watched variables (collapsible sections)
----------------------------------------------------------------------

function TurtleDebug_WatchRefresh()
    local n = table.getn(watchList)

    -- Hide surplus sections
    for i = n + 1, table.getn(watchSections) do
        if watchSections[i] and watchSections[i].frame then
            watchSections[i].frame:Hide()
        end
    end

    if n == 0 then
        wScrollChild:SetHeight(30)
        wScroll:UpdateScrollChildRect()
        return
    end

    local yOff = 0

    for i = 1, n do
        local sec = GetOrCreateSection(i)
        sec.watchIndex = i
        local entry = watchList[i]
        local path = entry.name

        -- Resolve variable
        local val, found = Resolve(path)

        -- Build colored and plain text
        local colorLines = {}
        local plainLines = {}
        if not found then
            table.insert(colorLines, "  |cffe06c75nil|r  (not found)")
            table.insert(plainLines, "  nil  (not found)")
        else
            PrettyPrint(val, 1, {}, colorLines)
            PlainPrint(val, 1, {}, plainLines)
        end
        local colorText = table.concat(colorLines, "\n")
        sec.plainText = path .. " =\n" .. table.concat(plainLines, "\n")

        -- Header text
        sec.headerText:SetText("|cff61afef" .. path .. "|r")

        -- Position section
        sec.frame:ClearAllPoints()
        sec.frame:SetPoint("TOPLEFT", wScrollChild, "TOPLEFT", 0, -yOff)
        sec.frame:SetWidth(SECTION_WIDTH)
        sec.frame:Show()

        -- Hide copy overlay and reset button
        sec.copyFrame:Hide()
        sec.body:Show()
        sec.copying = false
        sec.copyBtnText:SetText("|cffabb2bfCopy|r")

        if entry.collapsed then
            sec.arrow:SetText("|cffcccccc>|r")
            sec.body:SetText("")
            sec.body:Hide()
            sec.copyBtn:Hide()
            sec.frame:SetHeight(24)
            yOff = yOff + 26
        else
            sec.arrow:SetText("|cffccccccv|r")
            sec.body:SetText(colorText)
            sec.copyBtn:Show()

            -- Wait for FontString to compute its height
            local bh = sec.body:GetHeight()
            if (not bh) or bh < 14 then bh = 14 end
            sec.frame:SetHeight(26 + bh + 6)
            yOff = yOff + 26 + bh + 8
        end
    end

    wScrollChild:SetHeight(math.max(30, yOff + 10))
    wScroll:UpdateScrollChildRect()
end

----------------------------------------------------------------------
--  Dynamic layout on resize
----------------------------------------------------------------------

local function UpdateDynamicWidths()
    local fw = frame:GetWidth()
    local contentW = fw - 60
    local sectionW = fw - 72

    -- Inspect tab
    scrollChild:SetWidth(contentW)
    displayFS:SetWidth(contentW)
    copyBox:SetWidth(contentW)

    -- Watch tab
    wScrollChild:SetWidth(contentW)

    -- Update section width for new + existing sections
    SECTION_WIDTH = sectionW
    for i = 1, table.getn(watchSections) do
        local sec = watchSections[i]
        if sec and sec.frame then
            sec.frame:SetWidth(sectionW)
            sec.body:SetWidth(sectionW - 16)
        end
    end
end

frame:SetScript("OnSizeChanged", function()
    UpdateDynamicWidths()
end)

----------------------------------------------------------------------
--  Persistence: save / restore state
----------------------------------------------------------------------

local function SaveState()
    -- Write a clean table (drops any stale keys from old versions)
    TurtleDebugSaved = {}
    TurtleDebugSaved.activeTab = activeTab
    TurtleDebugSaved.inspectInput = TurtleDebugInput:GetText() or ""
    TurtleDebugSaved.watchItems = {}
    for i = 1, table.getn(watchList) do
        table.insert(TurtleDebugSaved.watchItems, {
            name = watchList[i].name,
            collapsed = watchList[i].collapsed or false,
        })
    end
    -- Window position and size
    local left = TurtleDebugFrame:GetLeft()
    local top = TurtleDebugFrame:GetTop()
    if left and top then
        TurtleDebugSaved.pos = { x = left, y = top }
    end
    TurtleDebugSaved.size = {
        w = TurtleDebugFrame:GetWidth(),
        h = TurtleDebugFrame:GetHeight(),
    }
    TurtleDebugSaved.autoRefresh = watchAutoRefresh
end

local function RestoreState()
    if not TurtleDebugSaved then return end
    if TurtleDebugSaved.inspectInput and TurtleDebugSaved.inspectInput ~= "" then
        TurtleDebugInput:SetText(TurtleDebugSaved.inspectInput)
    end
    if TurtleDebugSaved.watchItems then
        watchList = {}
        for i = 1, table.getn(TurtleDebugSaved.watchItems) do
            local item = TurtleDebugSaved.watchItems[i]
            table.insert(watchList, {
                name = item.name,
                collapsed = item.collapsed or false,
            })
        end
    elseif TurtleDebugSaved.watchNames then
        -- Migration from old format
        watchList = {}
        for i = 1, table.getn(TurtleDebugSaved.watchNames) do
            table.insert(watchList, { name = TurtleDebugSaved.watchNames[i], collapsed = false })
        end
    end
    if TurtleDebugSaved.activeTab then
        activeTab = TurtleDebugSaved.activeTab
    end
    -- Restore window position
    local pos = TurtleDebugSaved.pos
    if not pos and TurtleDebugSaved.posX then
        pos = { x = TurtleDebugSaved.posX, y = TurtleDebugSaved.posY }
    end
    if pos then
        TurtleDebugFrame:ClearAllPoints()
        TurtleDebugFrame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos.x, pos.y)
    end
    -- Restore window size
    local size = TurtleDebugSaved.size
    if size and size.w and size.h then
        TurtleDebugFrame:SetWidth(size.w)
        TurtleDebugFrame:SetHeight(size.h)
    end
    -- Restore auto-refresh
    if TurtleDebugSaved.autoRefresh then
        SetAutoRefresh(true)
    end
end

-- Event frame for ADDON_LOADED + PLAYER_LOGOUT
local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_LOGOUT")
eventFrame:SetScript("OnEvent", function()
    if event == "ADDON_LOADED" and arg1 == "TurtleDebug" then
        RestoreState()
        -- Apply restored tab (don't evaluate yet, wait for Show)
        SetActiveTab(activeTab)
    elseif event == "PLAYER_LOGOUT" then
        SaveState()
    end
end)

-- When frame is shown, evaluate results for the active tab
frame:SetScript("OnShow", function()
    ShowTab(activeTab)
    if activeTab == "inspect" then
        local txt = TurtleDebugInput:GetText() or ""
        if txt ~= "" then
            TurtleDebug_Inspect()
        end
    end
end)

----------------------------------------------------------------------
--  Load message
----------------------------------------------------------------------

DEFAULT_CHAT_FRAME:AddMessage("|cffabd473Turtle Debug|r loaded. |cffabb2bf/debug|r to toggle")
