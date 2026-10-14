-------------------------------------------------------------------------------
-- Dundun Finder
--
-- Dundun is a neutral elite hiding somewhere in each bountiful delve. This addon:
--   1. Gives you a button and a keybind whose macro targets him and puts a
--      raid icon on him in one press. Targeting and marking are both
--      protected in Midnight, so they only ever happen from your own key
--      press or click; the addon just sets the macro up for you.
--   2. Shows a small panel only while you're inside a bountiful delve, which
--      says whether the press found him, alerts the first time it does, and
--      pulses a quiet reminder until then. It has a close button for the run.
--   3. Has a settings page under Options > AddOns > Dundun Finder.
-------------------------------------------------------------------------------

local ADDON_NAME = ...

local DELVE_DIFFICULTY_ID = 208
-- A bountiful delve's pin on the zone map uses this art.
local BOUNTIFUL_ATLAS = "delves-bountiful"
-- Midnight zones with delves, checked after the maps above the delve itself.
local DELVE_ZONE_MAPS = { 2393, 2395, 2405, 2413, 2424, 2437, 2443, 2512 }
local MARK_NAMES = { "Star", "Circle", "Diamond", "Triangle", "Moon", "Square", "Cross", "Skull" }
local BINDING_KEY = "CLICK DundunFinderButton:LeftButton"

local NUDGE_MIN, NUDGE_MAX, NUDGE_STEP = 10, 120, 5

-- Dundun's face, the texture the delve difficulty popup uses for him.
local DUNDUN_FACE = 647701
local NPC_NAME = "Dundun"

local DEFAULTS = {
  enabled       = true,
  mark          = 4,      -- 4 = triangle
  sound         = true,
  announce      = true,
  showFrame     = true,
  nudge         = true,   -- pulse the panel text until he's found
  nudgeInterval = 30,     -- seconds between pulses
  lock          = false,  -- stop the panel from being dragged
  scale         = 1,      -- panel scale
  hideWhenFound = false,  -- hide the panel a few seconds after he's marked
  -- Lower right, pulled in from the corner so it clears the bag and action bars.
  pos           = { point = "BOTTOMRIGHT", relPoint = "BOTTOMRIGHT", x = -200, y = 180 },
}

local POS_VERSION = 2   -- bump when the default position changes, so old saves pick it up once

local SCALE_MIN, SCALE_MAX, SCALE_STEP = 0.6, 1.6, 0.1
local HIDE_DELAY = 5   -- seconds the "marked" status stays before hideWhenFound hides the panel

local db
local state = {
  active            = false,  -- inside a bountiful delve, so the panel belongs on screen
  dismissed         = false,  -- closed with the X for the rest of this run
  found             = false,  -- a press found and marked him this delve
  nudgeTicker       = nil,
  hideTimer         = nil,
  preview           = false,  -- panel shown from the options page for positioning
  pendingVisibility = false,
  pendingMacro      = false,
}
local settingObjects = {}   -- key -> Settings object, once the options page exists
local InitDB                -- defined further down, used by the options page

-------------------------------------------------------------------------------
-- Helpers
-------------------------------------------------------------------------------

local function Print(msg, ...)
  if select("#", ...) > 0 then msg = msg:format(...) end
  print("|cff33ff99Dundun Finder|r: " .. msg)
end

local function MarkIcon(index)
  return ("|TInterface\\TargetingFrame\\UI-RaidTargetingIcon_%d:0|t"):format(index)
end

local function IsSecret(v)
  return issecretvalue and issecretvalue(v)
end

-- True only while you're standing inside a delve instance. This deliberately
-- ignores whether a delve run is still open, because a run stays open after
-- you walk out and the panel shouldn't follow you into the open world.
local function IsInDelve()
  if not IsInInstance() then return false end
  local _, _, difficultyID = GetInstanceInfo()
  return difficultyID == DELVE_DIFFICULTY_ID
end

-- True when the delve you're in is bountiful today. There's no direct API for
-- it, so this finds the delve's pin on a zone map and checks its art: first on
-- the maps above the delve itself, then on the known Midnight delve zones.
local function IsBountifulDelve()
  local instanceName = GetInstanceInfo()
  local mapID = C_Map.GetBestMapForUnit("player")
  local mapInfo = mapID and C_Map.GetMapInfo(mapID)
  local mapName = mapInfo and mapInfo.name

  local zones, seen = {}, {}
  local function AddZone(id)
    if id and id > 0 and not seen[id] then
      seen[id] = true
      zones[#zones + 1] = id
    end
  end
  local info = mapInfo
  for _ = 1, 10 do
    if not (info and info.parentMapID and info.parentMapID > 0) then break end
    AddZone(info.parentMapID)
    info = C_Map.GetMapInfo(info.parentMapID)
  end
  for _, id in ipairs(DELVE_ZONE_MAPS) do AddZone(id) end

  for _, zoneID in ipairs(zones) do
    local ok, poiIDs = pcall(C_AreaPoiInfo.GetDelvesForMap, zoneID)
    if ok and poiIDs then
      for _, poiID in ipairs(poiIDs) do
        local okInfo, poi = pcall(C_AreaPoiInfo.GetAreaPOIInfo, zoneID, poiID)
        if okInfo and poi then
          local sameDelve = (poi.name and (poi.name == instanceName or poi.name == mapName))
            or (mapID and poi.linkedUiMapID == mapID)
          if sameDelve then
            return poi.atlasName == BOUNTIFUL_ATLAS
          end
        end
      end
    end
  end
  return false
end

local function IsActive()
  return db.enabled and state.active
end

local function BoundKeyText()
  local key = GetBindingKey(BINDING_KEY)
  if key then return GetBindingText(key) end
  return nil
end

local function ScalePercent(scale)
  return math.floor((tonumber(scale) or 1) * 100 + 0.5)
end

-- GUID of a unit, or nil when it is unavailable or a Midnight secret value.
local function SafeGUID(unit)
  local ok, guid = pcall(UnitGUID, unit)
  if ok and guid and not IsSecret(guid) then return guid end
  return nil
end

-------------------------------------------------------------------------------
-- Frame: movable panel with status text and the secure "target" button
-------------------------------------------------------------------------------

local frame = CreateFrame("Frame", "DundunFinderFrame", UIParent, "BackdropTemplate")
frame:SetSize(210, 84)
frame:SetFrameStrata("MEDIUM")
frame:SetClampedToScreen(true)
frame:SetMovable(true)
frame:EnableMouse(true)
frame:RegisterForDrag("LeftButton")
frame:SetBackdrop({
  bgFile   = "Interface\\Tooltips\\UI-Tooltip-Background",
  edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
  tile = true, tileSize = 16, edgeSize = 12,
  insets = { left = 3, right = 3, top = 3, bottom = 3 },
})
frame:SetBackdropColor(0, 0, 0, 0.75)
frame:SetBackdropBorderColor(0.6, 0.6, 0.6, 1)
frame:Hide()

frame:SetScript("OnDragStart", function(self)
  if db.lock and not state.preview then return end
  if not InCombatLockdown() then self:StartMoving() end
end)
frame:SetScript("OnDragStop", function(self)
  self:StopMovingOrSizing()
  local point, _, relPoint, x, y = self:GetPoint()
  db.pos = { point = point, relPoint = relPoint, x = x, y = y }
end)

-- Panel icon: Dundun's face.
local icon = frame:CreateTexture(nil, "ARTWORK")
icon:SetSize(26, 26)
icon:SetPoint("TOPLEFT", 8, -7)
icon:SetTexture(DUNDUN_FACE)
icon:SetTexCoord(0.07, 0.93, 0.07, 0.93)   -- trim the usual icon border

local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
title:SetPoint("TOP", 0, -8)
title:SetText("Dundun Finder")

-- Close button. The stock close template hides its parent directly, which the
-- game blocks in combat for a panel holding a secure button, so this uses the
-- version without scripts and handles the click itself further down.
local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButtonNoScripts")
closeButton:SetSize(20, 20)
closeButton:SetPoint("TOPRIGHT", -2, -2)
closeButton:SetFrameLevel(frame:GetFrameLevel() + 5)
closeButton:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Hide until the next delve")
  GameTooltip:AddLine("The keybind still works while the panel is hidden.", 1, 1, 1, true)
  GameTooltip:Show()
end)
closeButton:SetScript("OnLeave", function() GameTooltip:Hide() end)

local statusText = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
statusText:SetPoint("TOP", title, "BOTTOM", 0, -4)
statusText:SetWidth(196)

-- The quiet nudge: fade the status text out and back a couple of times.
local pulse = statusText:CreateAnimationGroup()
local fadeOut = pulse:CreateAnimation("Alpha")
fadeOut:SetFromAlpha(1)
fadeOut:SetToAlpha(0.15)
fadeOut:SetDuration(0.35)
fadeOut:SetOrder(1)
local fadeIn = pulse:CreateAnimation("Alpha")
fadeIn:SetFromAlpha(0.15)
fadeIn:SetToAlpha(1)
fadeIn:SetDuration(0.35)
fadeIn:SetOrder(2)
pulse:SetLooping("REPEAT")

-- The secure button. Clicking it (mouse or keybind) runs the macro text, which
-- is the only way an addon is allowed to target or mark something for you.
local button = CreateFrame("Button", "DundunFinderButton", frame,
  "SecureActionButtonTemplate, UIPanelButtonTemplate")
button:SetSize(190, 22)
button:SetPoint("BOTTOM", 0, 8)
button:RegisterForClicks("AnyDown")   -- fire once per press, not on both down and up
button:SetAttribute("type", "macro")
button:SetScript("OnEnter", function(self)
  GameTooltip:SetOwner(self, "ANCHOR_TOP")
  GameTooltip:AddLine("Target " .. NPC_NAME)
  local key = BoundKeyText()
  if key then
    GameTooltip:AddLine("Keybind: " .. key, 0.5, 1, 0.5)
  end
  GameTooltip:Show()
end)
button:SetScript("OnLeave", function() GameTooltip:Hide() end)

local function SetStatus(text, r, g, b)
  statusText:SetText(text)
  statusText:SetTextColor(r or 1, g or 1, b or 1)
end

local function SearchingStatus()
  local key = BoundKeyText()
  if key then
    return ("Press %s to target %s"):format(key, NPC_NAME)
  end
  return ("Click below to target %s"):format(NPC_NAME)
end

local function UpdateMacro()
  if InCombatLockdown() then
    state.pendingMacro = true
    return
  end
  state.pendingMacro = false
  -- Out of combat the target is cleared first so a failed /target can't mark
  -- something else, and in combat the current target is kept (a stray icon
  -- beats losing your target mid-fight).
  button:SetAttribute("macrotext", table.concat({
    "/cleartarget [nocombat]",
    "/target " .. NPC_NAME,
    ("/tm [exists] %d"):format(db.mark),
  }, "\n"))
  button:SetText("Target " .. NPC_NAME)
end

local function ApplyPosition()
  local p = db.pos or DEFAULTS.pos
  frame:ClearAllPoints()
  frame:SetPoint(p.point or "CENTER", UIParent, p.relPoint or p.point or "CENTER", p.x or 0, p.y or 0)
end

local function ApplyScale()
  if InCombatLockdown() then
    state.pendingVisibility = true   -- re-applied along with visibility after combat
    return
  end
  local scale = tonumber(db.scale) or 1
  if scale < SCALE_MIN then scale = SCALE_MIN end
  if scale > SCALE_MAX then scale = SCALE_MAX end
  frame:SetScale(scale)
end

local function ApplyVisibility()
  local want = state.preview
    or (db.showFrame and IsActive() and not state.dismissed
        and not (db.hideWhenFound and state.found))
  if InCombatLockdown() then
    state.pendingVisibility = true
    return
  end
  state.pendingVisibility = false
  ApplyScale()
  if want then frame:Show() else frame:Hide() end
end

-------------------------------------------------------------------------------
-- The nudge
-------------------------------------------------------------------------------

local function StopNudging()
  if state.nudgeTicker then
    state.nudgeTicker:Cancel()
    state.nudgeTicker = nil
  end
  pulse:Stop()
end

local function Nudge()
  if not IsActive() or state.found or not db.nudge or not frame:IsShown() then return end
  SetStatus(SearchingStatus(), 1, 0.82, 0)
  pulse:Play()
  C_Timer.After(2.1, function() pulse:Stop() end)
end

local function StartNudging()
  StopNudging()
  if not db.nudge or not IsActive() or state.found then return end
  local interval = tonumber(db.nudgeInterval) or DEFAULTS.nudgeInterval
  if interval < NUDGE_MIN then interval = NUDGE_MIN end
  state.nudgeTicker = C_Timer.NewTicker(interval, Nudge)
end

-------------------------------------------------------------------------------
-- The press
-------------------------------------------------------------------------------

local function OnFound()
  if state.found then return end
  state.found = true
  StopNudging()
  SetStatus(("%s marked %s"):format(NPC_NAME, MarkIcon(db.mark)), 0.4, 1, 0.4)
  if db.announce then
    local msg = ("%s found! Marked with %s."):format(NPC_NAME, MARK_NAMES[db.mark] or "a raid icon")
    Print(msg)
    -- RaidWarningUtil replaced RaidNotice_AddMessage in 12.1.5, which now only
    -- exists when the game's deprecation fallbacks are switched on.
    if RaidWarningUtil and RaidWarningUtil.AddMessage then
      RaidWarningUtil.AddMessage(msg, ChatTypeInfo["RAID_WARNING"])
    elseif RaidNotice_AddMessage and RaidWarningFrame then
      RaidNotice_AddMessage(RaidWarningFrame, msg, ChatTypeInfo["RAID_WARNING"])
    end
  end
  if db.sound then
    PlaySound(SOUNDKIT.RAID_WARNING, "Master")
  end
  if db.hideWhenFound then
    if state.hideTimer then state.hideTimer:Cancel() end
    state.hideTimer = C_Timer.NewTimer(HIDE_DELAY, function()
      state.hideTimer = nil
      ApplyVisibility()
    end)
  end
end

-- The macro can only ever switch the target to Dundun. Out of combat it
-- clears the target first, so anything targeted after the press is him. In
-- combat the target is kept, so it counts only when it visibly changed.
-- PreClick and PostClick are plain script handlers and may run Lua freely.
button:SetScript("PreClick", function()
  state.clickInCombat = UnitAffectingCombat("player") and true or false
  state.targetBefore = SafeGUID("target")
  state.hadTargetBefore = UnitExists("target") and true or false
end)

button:SetScript("PostClick", function()
  C_Timer.After(0.1, function()
    if not IsActive() or state.found then return end
    if not UnitExists("target") then
      SetStatus(("%s not in range yet."):format(NPC_NAME), 1, 0.6, 0.2)
      return
    end
    if not state.clickInCombat or not state.hadTargetBefore then
      OnFound()
      return
    end
    local now = SafeGUID("target")
    if state.targetBefore and now and now ~= state.targetBefore then
      OnFound()
    end
    -- Otherwise there is no way to tell in combat, so the status stays as it is.
  end)
end)

-------------------------------------------------------------------------------
-- Delve tracking
-------------------------------------------------------------------------------

local function BeginSearch()
  state.found = false
  state.dismissed = false
  if not db.enabled then return end
  SetStatus(SearchingStatus(), 1, 0.82, 0)
  StartNudging()
  ApplyVisibility()
end

local function EndSearch()
  StopNudging()
  if state.hideTimer then
    state.hideTimer:Cancel()
    state.hideTimer = nil
  end
  ApplyVisibility()
end

-- Turns the panel on once you're inside a bountiful delve and off as soon as
-- you leave. Bountiful is only checked on the way in, so a slow map update
-- partway through a run can't make the panel vanish.
local function RefreshDelveState()
  if not IsInDelve() then
    if state.active then
      state.active = false
      EndSearch()
    end
    return
  end
  if not state.active and IsBountifulDelve() then
    state.active = true
    BeginSearch()
  end
end

-------------------------------------------------------------------------------
-- Applying settings (shared by the options page and slash commands)
-------------------------------------------------------------------------------

local apply = {}

apply.enabled = function()
  if db.enabled and state.active then
    BeginSearch()
  else
    StopNudging()
    ApplyVisibility()
  end
end

apply.mark = function()
  state.found = false     -- the next press puts the new icon on him
  UpdateMacro()
end

apply.showFrame = function()
  -- Turning the panel on also brings it back after the X was clicked.
  if db.showFrame and state.dismissed then
    state.dismissed = false
    StartNudging()
  end
  ApplyVisibility()
end

apply.nudge = function() StartNudging() end
apply.nudgeInterval = function() StartNudging() end
apply.scale = function() ApplyScale() end
apply.hideWhenFound = function() ApplyVisibility() end

-- Preview: show the panel from the options page so it can be dragged into
-- place. Ends when the options window closes.
local function SetPreview(on)
  state.preview = on and true or false
  if state.preview then
    SetStatus("Drag me into place, then close settings.", 0.6, 0.8, 1)
    ApplyVisibility()
    if not IsActive() then UpdateMacro() end
  else
    if IsActive() then
      if state.found then
        SetStatus(("%s marked %s"):format(NPC_NAME, MarkIcon(db.mark)), 0.4, 1, 0.4)
      else
        SetStatus(SearchingStatus(), 1, 0.82, 0)
      end
    end
    ApplyVisibility()
  end
end

-- The X hides the panel for the rest of this run. In combat the hide waits
-- until combat ends, since the panel holds a secure button.
closeButton:SetScript("OnClick", function()
  if state.preview then
    SetPreview(false)
    return
  end
  state.dismissed = true
  StopNudging()
  if InCombatLockdown() then
    SetStatus("Closing when combat ends.", 0.7, 0.7, 0.7)
  end
  ApplyVisibility()
end)

-- Set a value, going through the Settings object when the options page exists
-- so the page stays in sync. Falls back to writing the table directly.
local function SetSettingValue(key, value)
  local setting = settingObjects[key]
  if setting then
    setting:SetValue(value)     -- fires the value-changed callback, which applies
  else
    db[key] = value
    if apply[key] then apply[key]() end
  end
end

-------------------------------------------------------------------------------
-- Options page: Options > AddOns > Dundun Finder
-------------------------------------------------------------------------------

local optionsCategory

local function BuildOptionsPage()
  if not (Settings and Settings.RegisterVerticalLayoutCategory and Settings.RegisterAddOnSetting) then
    return
  end

  local category, layout = Settings.RegisterVerticalLayoutCategory("Dundun Finder")
  optionsCategory = category

  local function AddHeader(text)
    if CreateSettingsListSectionHeaderInitializer and layout then
      pcall(function() layout:AddInitializer(CreateSettingsListSectionHeaderInitializer(text)) end)
    end
  end

  local function Register(key, label)
    local default = DEFAULTS[key]
    local setting = Settings.RegisterAddOnSetting(category, "DundunFinder_" .. key, key, db, type(default), label, default)
    setting:SetValueChangedCallback(function()
      if apply[key] then apply[key]() end
    end)
    settingObjects[key] = setting
    return setting
  end

  local function Checkbox(key, label, tooltip)
    local setting = Register(key, label)
    Settings.CreateCheckbox(category, setting, tooltip)
  end

  AddHeader("General")
  Checkbox("enabled", "Enable Dundun Finder", "Show the panel in bountiful delves and track whether " .. NPC_NAME .. " has been marked.")

  do
    local setting = Register("mark", "Raid icon")
    local function GetOptions()
      local container = Settings.CreateControlTextContainer()
      for i, name in ipairs(MARK_NAMES) do
        container:Add(i, MarkIcon(i) .. " " .. name)
      end
      return container:GetData()
    end
    Settings.CreateDropdown(category, setting, GetOptions, "Which raid icon to put on " .. NPC_NAME .. ".")
  end

  AddHeader("Alerts")
  Checkbox("announce", "Announce when found", "Prints to chat and shows a raid-warning style banner.")
  Checkbox("sound", "Play a sound when found", "Plays the raid warning sound.")

  AddHeader("Nudge")
  Checkbox("nudge", "Pulse the panel until he's found", "Every so often the panel text fades in and out as a quiet reminder. No sound.")
  do
    local setting = Register("nudgeInterval", "Seconds between nudges")
    local options = Settings.CreateSliderOptions(NUDGE_MIN, NUDGE_MAX, NUDGE_STEP)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
      return ("%ds"):format(value)
    end)
    Settings.CreateSlider(category, setting, options, "How long to wait between pulses.")
  end

  AddHeader("Panel")
  Checkbox("showFrame", "Show panel in delves", "The panel appears in bountiful delves and holds the Target button and status text. The keybind works even with the panel hidden.")
  Checkbox("hideWhenFound", "Hide panel once he's marked", ("Hides the panel %d seconds after %s is marked."):format(HIDE_DELAY, NPC_NAME))
  Checkbox("lock", "Lock panel position", "Stops the panel from being dragged by accident. Preview from this page still lets you move it.")
  do
    local setting = Register("scale", "Panel scale")
    local options = Settings.CreateSliderOptions(SCALE_MIN, SCALE_MAX, SCALE_STEP)
    options:SetLabelFormatter(MinimalSliderWithSteppersMixin.Label.Right, function(value)
      return ("%d%%"):format(ScalePercent(value))
    end)
    Settings.CreateSlider(category, setting, options, "Size of the on-screen panel.")
  end
  if CreateSettingsButtonInitializer and layout then
    pcall(function()
      layout:AddInitializer(CreateSettingsButtonInitializer(
        "Preview panel", "Show / Hide", function()
          SetPreview(not state.preview)
        end, "Shows the panel so you can drag it into place. It hides again when you close settings.", true))
      layout:AddInitializer(CreateSettingsButtonInitializer(
        "Panel position", "Reset", function()
          db.pos = nil
          InitDB()
          ApplyPosition()
          Print("panel position reset.")
        end, "Move the panel back to the default spot.", true))
    end)
  end

  AddHeader("Keybind")
  if CreateSettingsButtonInitializer and layout then
    pcall(function()
      layout:AddInitializer(CreateSettingsButtonInitializer(
        "Keybind", "Open Keybindings", function()
          if Settings.OpenToCategory and Settings.KEYBINDINGS_CATEGORY_ID then
            Settings.OpenToCategory(Settings.KEYBINDINGS_CATEGORY_ID)
          end
        end, "The Target " .. NPC_NAME .. " binding lives under Keybindings > AddOns > Dundun Finder.", true))
    end)
  end

  Settings.RegisterAddOnCategory(category)

  -- End the preview whenever the options window closes.
  if SettingsPanel and SettingsPanel.HookScript then
    SettingsPanel:HookScript("OnHide", function()
      if state.preview then SetPreview(false) end
    end)
  end
end

local function OpenOptions()
  if optionsCategory and Settings and Settings.OpenToCategory then
    Settings.OpenToCategory(optionsCategory:GetID())
  else
    Print("options page not available; use /dundun commands instead.")
  end
end

-------------------------------------------------------------------------------
-- Saved variables
-------------------------------------------------------------------------------

function InitDB()
  DundunFinderDB = DundunFinderDB or {}
  db = DundunFinderDB
  for k, v in pairs(DEFAULTS) do
    if db[k] == nil then
      if type(v) == "table" then
        db[k] = {}
        for k2, v2 in pairs(v) do db[k][k2] = v2 end
      else
        db[k] = v
      end
    end
  end
  if type(db.mark) ~= "number" or db.mark < 1 or db.mark > 8 then db.mark = DEFAULTS.mark end
  if type(db.nudgeInterval) ~= "number" then db.nudgeInterval = DEFAULTS.nudgeInterval end
  if type(db.scale) ~= "number" or db.scale < SCALE_MIN or db.scale > SCALE_MAX then db.scale = DEFAULTS.scale end
  -- One-time move to the current default spot for saves made before it changed.
  if db.posVersion ~= POS_VERSION then
    db.pos = {}
    for k, v in pairs(DEFAULTS.pos) do db.pos[k] = v end
    db.posVersion = POS_VERSION
  end
end

-------------------------------------------------------------------------------
-- Events
-------------------------------------------------------------------------------

local handlers = {}

handlers.ADDON_LOADED = function(name)
  if name ~= ADDON_NAME then return end
  InitDB()
  ApplyPosition()
  UpdateMacro()
  BuildOptionsPage()
  if not db.shownWelcome then
    db.shownWelcome = true
    Print("loaded. Bind a key under Options > Keybindings > AddOns > Dundun Finder, then press it in a delve. /dundun config for settings.")
  end
end

handlers.PLAYER_ENTERING_WORLD = function()
  -- Every loading screen is a fresh run, so close out the last one (hiding the
  -- panel) before deciding whether the new place needs it.
  if state.active then
    state.active = false
    EndSearch()
  end
  RefreshDelveState()
  -- Instance and map pin info can lag a moment after the loading screen.
  C_Timer.After(2, RefreshDelveState)
  C_Timer.After(5, RefreshDelveState)
end

handlers.ZONE_CHANGED_NEW_AREA = RefreshDelveState
handlers.AREA_POIS_UPDATED = RefreshDelveState

handlers.PLAYER_REGEN_ENABLED = function()
  if state.pendingVisibility then ApplyVisibility() end
  if state.pendingMacro then UpdateMacro() end
end

handlers.UPDATE_BINDINGS = function()
  if IsActive() and not state.found then SetStatus(SearchingStatus(), 1, 0.82, 0) end
end

local ev = CreateFrame("Frame")
for event in pairs(handlers) do ev:RegisterEvent(event) end
ev:SetScript("OnEvent", function(_, event, ...)
  local h = handlers[event]
  if h then h(...) end
end)

-------------------------------------------------------------------------------
-- Keybinding labels
-------------------------------------------------------------------------------

_G["BINDING_NAME_" .. BINDING_KEY] = "Target Dundun"

-------------------------------------------------------------------------------
-- Slash commands
-------------------------------------------------------------------------------

local function OnOff(v) return v and "|cff40ff40on|r" or "|cffff4040off|r" end

local function ShowHelp()
  local version = (C_AddOns and C_AddOns.GetAddOnMetadata and C_AddOns.GetAddOnMetadata(ADDON_NAME, "Version")) or "?"
  Print("v%s. Settings:", version)
  print(("  enabled %s | mark: %s %s | keybind: %s"):format(
    OnOff(db.enabled), MarkIcon(db.mark), MARK_NAMES[db.mark], BoundKeyText() or "|cffff8000not set|r"))
  print(("  sound %s | announce %s | panel %s | nudge %s every %ds"):format(
    OnOff(db.sound), OnOff(db.announce), OnOff(db.showFrame), OnOff(db.nudge), db.nudgeInterval))
  print(("  panel locked %s | scale %d%% | hide when found %s"):format(
    OnOff(db.lock), ScalePercent(db.scale), OnOff(db.hideWhenFound)))
  print("  /dundun config - open the settings page")
  print("  /dundun toggle - enable or disable the addon")
  print("  /dundun mark <1-8 or name> - raid icon to use (e.g. 4 or triangle)")
  print("  /dundun sound | announce | panel - toggle each")
  print("  /dundun nudge [on | off | seconds] - toggle the nudge or set its interval")
  print("  /dundun lock - lock or unlock the panel position")
  print("  /dundun scale <60-160> - panel size in percent")
  print("  /dundun reset - move the panel back to the default spot")
end

local function ParseMark(text)
  local n = tonumber(text)
  if n and n >= 1 and n <= 8 then return n end
  text = (text or ""):lower()
  for i, name in ipairs(MARK_NAMES) do
    if name:lower() == text then return i end
  end
  return nil
end

SLASH_DUNDUNFINDER1 = "/dundun"
SLASH_DUNDUNFINDER2 = "/dundunfinder"
SlashCmdList.DUNDUNFINDER = function(input)
  local cmd, rest = (input or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = (cmd or ""):lower()

  if cmd == "" or cmd == "help" then
    ShowHelp()

  elseif cmd == "config" or cmd == "options" or cmd == "settings" then
    OpenOptions()

  elseif cmd == "toggle" or cmd == "enable" or cmd == "disable" then
    local value
    if cmd == "toggle" then value = not db.enabled else value = (cmd == "enable") end
    SetSettingValue("enabled", value)
    Print("addon %s.", OnOff(db.enabled))

  elseif cmd == "mark" then
    local m = ParseMark(rest)
    if not m then
      Print("usage: /dundun mark <1-8 or star/circle/diamond/triangle/moon/square/cross/skull>")
      return
    end
    SetSettingValue("mark", m)
    Print("will mark %s with %s %s.", NPC_NAME, MarkIcon(m), MARK_NAMES[m])

  elseif cmd == "sound" then
    SetSettingValue("sound", not db.sound)
    Print("sound %s.", OnOff(db.sound))

  elseif cmd == "announce" then
    SetSettingValue("announce", not db.announce)
    Print("announcements %s.", OnOff(db.announce))

  elseif cmd == "panel" or cmd == "frame" or cmd == "button" then
    if state.dismissed and db.showFrame then
      -- Closed with the X: bring it back rather than turning the setting off.
      state.dismissed = false
      StartNudging()
      ApplyVisibility()
      Print("panel shown.")
    else
      SetSettingValue("showFrame", not db.showFrame)
      Print("panel %s.", OnOff(db.showFrame))
    end

  elseif cmd == "nudge" then
    local seconds = tonumber(rest)
    if rest == "" then
      SetSettingValue("nudge", not db.nudge)
    elseif rest:lower() == "off" then
      SetSettingValue("nudge", false)
    elseif rest:lower() == "on" then
      SetSettingValue("nudge", true)
    elseif seconds then
      if seconds < NUDGE_MIN then seconds = NUDGE_MIN end
      if seconds > NUDGE_MAX then seconds = NUDGE_MAX end
      SetSettingValue("nudgeInterval", seconds)
      SetSettingValue("nudge", true)
    else
      Print("usage: /dundun nudge [on | off | seconds]")
      return
    end
    Print("nudge %s, every %d seconds.", OnOff(db.nudge), db.nudgeInterval)

  elseif cmd == "lock" then
    SetSettingValue("lock", not db.lock)
    Print("panel position %s.", db.lock and "locked" or "unlocked")

  elseif cmd == "scale" then
    local pct = tonumber(rest)
    if not pct then
      Print("usage: /dundun scale <60-160>  (currently %d%%)", ScalePercent(db.scale))
      return
    end
    local scale = pct / 100
    if scale < SCALE_MIN then scale = SCALE_MIN end
    if scale > SCALE_MAX then scale = SCALE_MAX end
    SetSettingValue("scale", scale)
    Print("panel scale %d%%.", ScalePercent(db.scale))

  elseif cmd == "reset" then
    db.pos = nil
    InitDB()
    ApplyPosition()
    Print("panel position reset.")

  else
    ShowHelp()
  end
end
