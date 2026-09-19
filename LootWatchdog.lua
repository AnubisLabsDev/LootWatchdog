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

LootWatchdogDB = LootWatchdogDB or { enabled = true, debug = false }

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
			if LootWatchdogDB.enabled then
				SendChatMessage(msg, IsInRaid() and "RAID" or "PARTY")
			end
			print(PREFIX .. ": " .. msg)
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
-- Slash command
--------------------------------------------------------------------------------

SLASH_LOOTWATCHDOG1 = "/lwd"
SlashCmdList["LOOTWATCHDOG"] = function(msg)
	msg = (msg or ""):lower():trim()
	if msg == "debug" then
		LootWatchdogDB.debug = not LootWatchdogDB.debug
		print(PREFIX .. ": debug " .. (LootWatchdogDB.debug and "ON" or "OFF"))
	elseif msg == "off" then
		LootWatchdogDB.enabled = false
		print(PREFIX .. ": announcements OFF (still prints locally)")
	elseif msg == "on" then
		LootWatchdogDB.enabled = true
		print(PREFIX .. ": announcements ON")
	else
		print(PREFIX .. ": /lwd on | off | debug")
	end
end
