local ADDON_NAME = ...
local PREFIX = "|cffff4040LootWatchdog|r"

--------------------------------------------------------------------------------
-- KNOWN LIMITATION (please read): this addon only fires for the "group loot"
-- roll system (Need/Greed/DE/Pass). Current-tier raids/M+ almost always use
-- Personal Loot, which has no rolls at all -- there's nothing to watch there.
-- This is aimed at legacy-raid farming, "Need before Greed" premade groups,
-- and any group loot method where rolling still happens.
--
-- The trickiest part of this addon -- and the one piece I can't verify
-- without a live client -- is recognizing "PlayerName won ITEM (Need)" text
-- in the CHAT_MSG_LOOT feed. Rather than hardcode an exact English sentence
-- (which breaks on other locales and might just be wrong), it heuristically
-- checks that a chat-loot line contains all three of: a group member's name,
-- an item link, and the client's own localized word for "Need". Run
-- `/lwd debug` to print every raw CHAT_MSG_LOOT line so we can tune this
-- fast if it misses a real roll in-game.
--------------------------------------------------------------------------------

local DEFAULT_WHISPER_MSG = "Can I please have that item since you do not actually need it?"

LootWatchdogDB = LootWatchdogDB or { enabled = true, debug = false, whisperMessage = DEFAULT_WHISPER_MSG, minimap = {} }
LootWatchdogDB.whisperMessage = LootWatchdogDB.whisperMessage or DEFAULT_WHISPER_MSG
LootWatchdogDB.minimap = LootWatchdogDB.minimap or {}

local NEED_WORD = _G.NEED or "Need"

-- Escape a player/unit name for use inside a Lua pattern.
local function EscapeForPattern(s)
	return (s:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1"))
end

local function StripRealm(name)
	return name and name:match("^([^%-]+)") or name
end

local function FindUnitByName(name)
	name = StripRealm(name)
	if name == StripRealm(UnitName("player")) then
		return "player"
	end
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			local unit = "raid" .. i
			if StripRealm(UnitName(unit) or "") == name then
				return unit
			end
		end
	elseif IsInGroup() then
		for i = 1, GetNumGroupMembers() - 1 do
			local unit = "party" .. i
			if StripRealm(UnitName(unit) or "") == name then
				return unit
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Equip-slot mapping: dropped item's equipLoc -> inventory slot id(s) to
-- compare against. Two-slot types compare against whichever equipped item is
-- worse, since that's the one the roll would actually replace.
--------------------------------------------------------------------------------

local EQUIP_SLOTS = {
	INVTYPE_HEAD = { 1 },
	INVTYPE_NECK = { 2 },
	INVTYPE_SHOULDER = { 3 },
	INVTYPE_CLOAK = { 15 },
	INVTYPE_CHEST = { 5 },
	INVTYPE_ROBE = { 5 },
	INVTYPE_WAIST = { 6 },
	INVTYPE_LEGS = { 7 },
	INVTYPE_FEET = { 8 },
	INVTYPE_WRIST = { 9 },
	INVTYPE_HAND = { 10 },
	INVTYPE_FINGER = { 11, 12 },
	INVTYPE_TRINKET = { 13, 14 },
	INVTYPE_WEAPON = { 16, 17 },
	INVTYPE_2HWEAPON = { 16 },
	INVTYPE_WEAPONMAINHAND = { 16 },
	INVTYPE_WEAPONOFFHAND = { 17 },
	INVTYPE_SHIELD = { 17 },
	INVTYPE_HOLDABLE = { 17 },
	INVTYPE_RANGED = { 16 },
	INVTYPE_RANGEDRIGHT = { 16 },
}

local function GetWorseEquippedItemLevel(unit, slots)
	local worst, worstLink = nil, nil
	for _, slotID in ipairs(slots) do
		local link = GetInventoryItemLink(unit, slotID)
		local ilvl = link and select(1, C_Item.GetDetailedItemLevelInfo(link)) or 0
		if not worst or ilvl < worst then
			worst, worstLink = ilvl, link
		end
	end
	return worst or 0, worstLink
end

local KNOWN_TRACKS = { "Explorer", "Adventurer", "Veteran", "Champion", "Hero", "Myth" }

local function GetTrackName(itemLink)
	if not itemLink then
		return nil
	end
	local data = C_TooltipInfo.GetHyperlink(itemLink)
	if not data or not data.lines then
		return nil
	end
	for _, line in ipairs(data.lines) do
		local text = line.leftText
		if text then
			for _, track in ipairs(KNOWN_TRACKS) do
				if text:find(track, 1, true) then
					return track
				end
			end
		end
	end
	return nil
end

--------------------------------------------------------------------------------
-- Inspect queue: only one NotifyInspect in flight at a time.
--------------------------------------------------------------------------------

local inspectQueue = {}
local inspecting = false
local inspectFrame = CreateFrame("Frame")
inspectFrame:RegisterEvent("INSPECT_READY")

local function ProcessInspectQueue()
	if inspecting or #inspectQueue == 0 then
		return
	end
	local job = table.remove(inspectQueue, 1)
	inspecting = job
	NotifyInspect(job.unit)
	C_Timer.After(5, function()
		if inspecting == job then
			inspecting = false
			ProcessInspectQueue()
		end
	end)
end

inspectFrame:SetScript("OnEvent", function(_, _, guid)
	if inspecting and UnitGUID(inspecting.unit) == guid then
		local job = inspecting
		inspecting = false
		job.callback(job.unit)
		ClearInspectPlayer(job.unit)
		ProcessInspectQueue()
	end
end)

local function QueueInspect(unit, callback)
	table.insert(inspectQueue, { unit = unit, callback = callback })
	ProcessInspectQueue()
end

--------------------------------------------------------------------------------
-- Popup: Call Out / Whisper / Close. StaticPopup maps button1->OnAccept,
-- button2->OnCancel, button3->OnAlt; if OnAlt is ever wrong on a client, the
-- worst case is button3 just closes the popup, which is what "Close, do
-- nothing" wants anyway.
--------------------------------------------------------------------------------

StaticPopupDialogs["LOOTWATCHDOG_BADNEED"] = {
	text = "%s",
	button1 = "Call Out",
	button2 = "Whisper",
	button3 = CLOSE or "Close",
	OnAccept = function(_, data)
		SendChatMessage(data.announceMsg, IsInRaid() and "RAID" or "PARTY")
	end,
	OnCancel = function(_, data, reason)
		if reason == "clicked" then
			SendChatMessage(LootWatchdogDB.whisperMessage, "WHISPER", nil, data.playerName)
		end
	end,
	timeout = 0,
	whileDead = true,
	hideOnEscape = true,
	preferredIndex = 3,
}

local function ShowBadNeedPopup(playerName, announceMsg)
	StaticPopup_Show("LOOTWATCHDOG_BADNEED", announceMsg, nil, {
		playerName = playerName,
		announceMsg = announceMsg,
	})
end

--------------------------------------------------------------------------------
-- Core: on a detected "PlayerName won ITEM (Need)" chat line, inspect the
-- winner and compare.
--------------------------------------------------------------------------------

local function HandleNeedWin(playerName, itemLink)
	local unit = FindUnitByName(playerName)
	if not unit then
		return
	end

	local _, _, _, equipLoc = C_Item.GetItemInfoInstant(itemLink)
	local slots = equipLoc and EQUIP_SLOTS[equipLoc]
	if not slots then
		return -- not gear, nothing to compare
	end

	QueueInspect(unit, function(inspectedUnit)
		local droppedIlvl = select(1, C_Item.GetDetailedItemLevelInfo(itemLink))
		local equippedIlvl, equippedLink = GetWorseEquippedItemLevel(inspectedUnit, slots)

		if droppedIlvl and equippedIlvl > 0 and droppedIlvl <= equippedIlvl then
			local droppedTrack = GetTrackName(itemLink)
			local equippedTrack = equippedLink and GetTrackName(equippedLink)
			local msg = ("%s needed on %s%s (ilvl %d) but already has %s%s (ilvl %d) equipped -- not an upgrade."):format(
				playerName,
				itemLink,
				droppedTrack and (" [" .. droppedTrack .. "]") or "",
				droppedIlvl or 0,
				equippedLink or "?",
				equippedTrack and (" [" .. equippedTrack .. "]") or "",
				equippedIlvl
			)
			print(PREFIX .. ": " .. msg)
			if LootWatchdogDB.enabled then
				ShowBadNeedPopup(playerName, msg)
			end
		end
	end)
end

--------------------------------------------------------------------------------
-- Chat parsing
--------------------------------------------------------------------------------

local ITEM_LINK_PATTERN = "|c%x+|Hitem:.-|h%[.-%]|h|r"

local watcher = CreateFrame("Frame")
watcher:RegisterEvent("CHAT_MSG_LOOT")
watcher:SetScript("OnEvent", function(_, _, message)
	if LootWatchdogDB.debug then
		print(PREFIX .. " [debug]: " .. message)
	end

	local itemLink = message:match(ITEM_LINK_PATTERN)
	if not itemLink or not message:find(NEED_WORD, 1, true) then
		return
	end

	-- find which group member's name appears in this line
	local candidates = {}
	if IsInRaid() then
		for i = 1, GetNumGroupMembers() do
			table.insert(candidates, UnitName("raid" .. i))
		end
	elseif IsInGroup() then
		table.insert(candidates, UnitName("player"))
		for i = 1, GetNumGroupMembers() - 1 do
			table.insert(candidates, UnitName("party" .. i))
		end
	end

	for _, name in ipairs(candidates) do
		if name and message:find(EscapeForPattern(name)) then
			HandleNeedWin(name, itemLink)
			break
		end
	end
end)

--------------------------------------------------------------------------------
-- ElvUI-flavored color helper. Same approach as PieSpecSwap/PickPocketPal:
-- pull ElvUI's own media colors when ElvUI is loaded, otherwise fall back to
-- a dark backdrop that already looks ElvUI-ish on its own.
--------------------------------------------------------------------------------

local function GetElvUIColors()
	local backdrop = { 0.05, 0.05, 0.05, 0.9 }
	local border = { 0, 0, 0, 1 }
	local accent = { 0.0, 0.6, 1.0, 1.0 }

	if ElvUI then
		local ok, E = pcall(function() return unpack(ElvUI) end)
		if ok and E and E.media then
			local m = E.media
			if m.backdropcolor then
				backdrop = { m.backdropcolor[1], m.backdropcolor[2], m.backdropcolor[3], m.backdropcolor[4] or 0.9 }
			end
			if m.bordercolor then
				border = { m.bordercolor[1], m.bordercolor[2], m.bordercolor[3], m.bordercolor[4] or 1 }
			end
			if m.rgbvaluecolor then
				accent = { m.rgbvaluecolor[1], m.rgbvaluecolor[2], m.rgbvaluecolor[3], 1 }
			end
		end
	end

	return backdrop, border, accent
end

--------------------------------------------------------------------------------
-- Settings window (right-click the minimap icon). Shows the whisper message
-- sent when you click "Whisper" on the bad-Need popup, defaulting to
-- DEFAULT_WHISPER_MSG and editable/savable in place.
--------------------------------------------------------------------------------

local settingsFrame

local function CreateSettingsFrame()
	local f = CreateFrame("Frame", "LootWatchdogSettings", UIParent)
	f:SetSize(360, 230)
	f:SetPoint("CENTER")
	f:SetFrameStrata("DIALOG")
	f:SetMovable(true)
	f:EnableMouse(true)
	f:Hide()

	local backdrop, border = GetElvUIColors()
	f.bg = f:CreateTexture(nil, "BACKGROUND")
	f.bg:SetAllPoints(f)
	f.bg:SetColorTexture(unpack(backdrop))
	f.border = f:CreateTexture(nil, "BORDER")
	f.border:SetPoint("TOPLEFT", -2, 2)
	f.border:SetPoint("BOTTOMRIGHT", 2, -2)
	f.border:SetColorTexture(unpack(border))

	-- title bar doubles as the drag handle
	local titleBar = CreateFrame("Frame", nil, f)
	titleBar:SetPoint("TOPLEFT")
	titleBar:SetPoint("TOPRIGHT", -28, 0)
	titleBar:SetHeight(26)
	titleBar:EnableMouse(true)
	titleBar:RegisterForDrag("LeftButton")
	titleBar:SetScript("OnDragStart", function() f:StartMoving() end)
	titleBar:SetScript("OnDragStop", function() f:StopMovingOrSizing() end)

	local title = titleBar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	title:SetPoint("LEFT", 10, 0)
	title:SetText("LootWatchdog Settings")

	local closeBtn = CreateFrame("Button", nil, f)
	closeBtn:SetSize(24, 24)
	closeBtn:SetPoint("TOPRIGHT", -4, -4)
	closeBtn:SetFrameLevel(f:GetFrameLevel() + 5)
	closeBtn.bg = closeBtn:CreateTexture(nil, "BACKGROUND")
	closeBtn.bg:SetAllPoints(closeBtn)
	closeBtn.bg:SetColorTexture(0.5, 0.1, 0.1, 0.9)
	closeBtn.hl = closeBtn:CreateTexture(nil, "HIGHLIGHT")
	closeBtn.hl:SetAllPoints(closeBtn)
	closeBtn.hl:SetColorTexture(1, 1, 1, 0.25)
	closeBtn.text = closeBtn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	closeBtn.text:SetAllPoints(closeBtn)
	closeBtn.text:SetText("x")
	closeBtn:RegisterForClicks("LeftButtonUp", "LeftButtonDown")
	closeBtn:SetScript("OnClick", function() f:Hide() end)

	-- Escape closes the panel like any other Blizzard window.
	UISpecialFrames = UISpecialFrames or {}
	table.insert(UISpecialFrames, "LootWatchdogSettings")

	local label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	label:SetPoint("TOPLEFT", 16, -36)
	label:SetPoint("RIGHT", f, "RIGHT", -16, 0)
	label:SetJustifyH("LEFT")
	label:SetText("Whisper message sent to the roller when you click Whisper on the popup:")

	local editBoxBg = f:CreateTexture(nil, "BACKGROUND")
	editBoxBg:SetPoint("TOPLEFT", label, "BOTTOMLEFT", 0, -8)
	editBoxBg:SetPoint("RIGHT", f, "RIGHT", -16, 0)
	editBoxBg:SetHeight(90)
	editBoxBg:SetColorTexture(0.1, 0.1, 0.1, 0.9)

	local scrollFrame = CreateFrame("ScrollFrame", nil, f, "UIPanelScrollFrameTemplate")
	scrollFrame:SetPoint("TOPLEFT", editBoxBg, "TOPLEFT", 6, -6)
	scrollFrame:SetPoint("BOTTOMRIGHT", editBoxBg, "BOTTOMRIGHT", -26, 6)

	local editBox = CreateFrame("EditBox", nil, scrollFrame)
	editBox:SetMultiLine(true)
	editBox:SetFontObject(ChatFontNormal)
	editBox:SetAutoFocus(false)
	editBox:SetWidth(scrollFrame:GetWidth())
	editBox:SetText(LootWatchdogDB.whisperMessage)
	editBox:SetScript("OnEscapePressed", function(eb) eb:ClearFocus() end)
	editBox:SetScript("OnTextChanged", function(eb)
		LootWatchdogDB.whisperMessage = eb:GetText()
	end)
	scrollFrame:SetScrollChild(editBox)
	scrollFrame:SetScript("OnSizeChanged", function(_, w) editBox:SetWidth(w) end)
	f.editBox = editBox

	local resetBtn = CreateFrame("Button", nil, f)
	resetBtn:SetSize(140, 22)
	resetBtn:SetPoint("TOPLEFT", editBoxBg, "BOTTOMLEFT", 0, -12)
	resetBtn.bg = resetBtn:CreateTexture(nil, "BACKGROUND")
	resetBtn.bg:SetAllPoints(resetBtn)
	resetBtn.bg:SetColorTexture(0.1, 0.1, 0.1, 0.9)
	resetBtn.hl = resetBtn:CreateTexture(nil, "HIGHLIGHT")
	resetBtn.hl:SetAllPoints(resetBtn)
	resetBtn.hl:SetColorTexture(1, 1, 1, 0.12)
	resetBtn.text = resetBtn:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
	resetBtn.text:SetAllPoints(resetBtn)
	resetBtn.text:SetText("Reset to Default")
	resetBtn:SetScript("OnClick", function()
		LootWatchdogDB.whisperMessage = DEFAULT_WHISPER_MSG
		editBox:SetText(DEFAULT_WHISPER_MSG)
	end)

	settingsFrame = f
	return f
end

local function ToggleSettings()
	if not settingsFrame then
		CreateSettingsFrame()
	else
		settingsFrame.editBox:SetText(LootWatchdogDB.whisperMessage)
	end

	if settingsFrame:IsShown() then
		settingsFrame:Hide()
	else
		settingsFrame:Show()
	end
end

--------------------------------------------------------------------------------
-- Minimap button. Uses LibDBIcon so ElvUI's built-in minimap-button skinning
-- (Skins > General > Blizzard Minimap / LDB icons) reskins it automatically
-- to match ElvUI's look, same as it does for every other LDB-based addon.
--------------------------------------------------------------------------------

local ldbObject = LibStub("LibDataBroker-1.1"):NewDataObject("LootWatchdog", {
	type = "launcher",
	text = "LootWatchdog",
	icon = "Interface\\AddOns\\LootWatchdog\\media\\minimap_icon.png",
	OnClick = function(_, button)
		if button == "LeftButton" then
			LootWatchdogDB.enabled = not LootWatchdogDB.enabled
			print(PREFIX .. ": " .. (LootWatchdogDB.enabled and "enabled" or "disabled"))
		elseif button == "RightButton" then
			ToggleSettings()
		end
	end,
	OnTooltipShow = function(tooltip)
		tooltip:AddLine("LootWatchdog")
		tooltip:AddLine(" ")
		tooltip:AddLine(("Status: %s"):format(LootWatchdogDB.enabled and "|cff20ff20enabled|r" or "|cffff2020disabled|r"))
		tooltip:AddLine("|cffffffffLeft-click:|r toggle on/off")
		tooltip:AddLine("|cffffffffRight-click:|r open settings")
	end,
})

LibStub("LibDBIcon-1.0"):Register("LootWatchdog", ldbObject, LootWatchdogDB.minimap)

--------------------------------------------------------------------------------
-- Slash command
--------------------------------------------------------------------------------

SLASH_LOOTWATCHDOG1 = "/lwd"
SlashCmdList["LOOTWATCHDOG"] = function(input)
	local cmd, rest = input:match("^(%S*)%s*(.-)$")
	cmd = cmd:lower()
	if cmd == "debug" then
		LootWatchdogDB.debug = not LootWatchdogDB.debug
		print(PREFIX .. ": debug " .. (LootWatchdogDB.debug and "ON" or "OFF"))
	elseif cmd == "off" then
		LootWatchdogDB.enabled = false
		print(PREFIX .. ": disabled (won't pop up on bad Needs)")
	elseif cmd == "on" then
		LootWatchdogDB.enabled = true
		print(PREFIX .. ": enabled")
	elseif cmd == "minimap" then
		LootWatchdogDB.minimap.hide = not LootWatchdogDB.minimap.hide
		if LootWatchdogDB.minimap.hide then
			LibStub("LibDBIcon-1.0"):Hide("LootWatchdog")
		else
			LibStub("LibDBIcon-1.0"):Show("LootWatchdog")
		end
	elseif cmd == "msg" then
		if rest ~= "" then
			LootWatchdogDB.whisperMessage = rest
			print(PREFIX .. ": whisper message set to: " .. rest)
		else
			print(PREFIX .. ": current whisper message: " .. LootWatchdogDB.whisperMessage)
		end
	elseif cmd == "settings" or cmd == "options" then
		ToggleSettings()
	else
		print(PREFIX .. ": /lwd on | off | debug | minimap | msg <text> | settings")
	end
end
