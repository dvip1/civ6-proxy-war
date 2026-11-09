-- Copyright (C) 2026 Dvip Patel
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ===========================================================================
-- ProxyWar_Gameplay.lua  (gameplay context, AddGameplayScripts)
--
-- Two ways in, one way out:
--   * Humans: networked request from the UI panel (EXECUTE_SCRIPT).
--   * AIs:    each AI major's turn start, it may buy a proxy war itself.
-- Both go through Execute(), which re-validates, makes the proxy declare
-- war, moves the gold, and tells a human target what happened.
-- The sponsor never becomes a party to the war.
-- ===========================================================================
include("ProxyWar_Logic");
include("WarHistory_Logic");

local PROP_LAST_TURN = "PROXYWAR_LAST_SPONSOR_TURN";

local function Log(msg) print("ProxyWar[gameplay]: " .. msg) end

-- ---------------------------------------------------------------------------
-- War history: owned here, persisted in a Game property (lives in the save).
-- ---------------------------------------------------------------------------
local g_History = nil;

local function SaveHistory()
	Game:SetProperty(WarHistory.PROPERTY_KEY, WarHistory.Serialize(g_History));
end

local function IsMajor(id)
	local p = id ~= nil and id >= 0 and Players[id];
	return p and p:IsMajor();
end

local function HistoryWorld()
	return {
		majors = function()
			local ids = {};
			for _, id in ipairs(PlayerManager.GetAliveMajorIDs()) do table.insert(ids, id) end
			table.sort(ids);
			return ids;
		end,
		isAlive = function(id) return Players[id] ~= nil and Players[id]:IsAlive() end,
		isAtWar = function(a, b) return Players[a]:GetDiplomacy():IsAtWarWith(b) end,
	};
end

local function OnHistDeclareWar(actingPlayer, reactingPlayer)
	if not (IsMajor(actingPlayer) and IsMajor(reactingPlayer)) then return end
	local _, created = WarHistory.Declare(g_History, actingPlayer, reactingPlayer, Game.GetCurrentGameTurn(), true);
	SaveHistory();
	if created then Log(string.format("history: war %d -> %d", actingPlayer, reactingPlayer)) end
end

local function OnHistCityConquered(capturerID, ownerID)
	if IsMajor(capturerID) and IsMajor(ownerID) and WarHistory.CityCaptured(g_History, capturerID, ownerID) then
		SaveHistory();
	end
end

local function IsUnitDead(playerID, unitID)
	if playerID == nil or playerID < 0 or unitID == nil or unitID < 0 then return false end
	local u = Players[playerID]:GetUnits():FindID(unitID);
	return u ~= nil and (u:IsDead() or u:IsDelayedDeath());
end

local function OnHistCombat(attackerPlayerID, attackerUnitID, defenderPlayerID, defenderUnitID)
	if not (IsMajor(attackerPlayerID) and IsMajor(defenderPlayerID)) then return end
	local changed = false;
	if IsUnitDead(defenderPlayerID, defenderUnitID) then
		changed = WarHistory.UnitKilled(g_History, attackerPlayerID, defenderPlayerID) or changed;
	end
	if IsUnitDead(attackerPlayerID, attackerUnitID) then
		changed = WarHistory.UnitKilled(g_History, defenderPlayerID, attackerPlayerID) or changed;
	end
	if changed then SaveHistory() end
end

local function ReconcileHistory(seedTurn)
	if WarHistory.Reconcile(g_History, HistoryWorld(), Game.GetCurrentGameTurn(), seedTurn) then
		SaveHistory();
	end
end

local function InitHistory()
	local saved = Game:GetProperty(WarHistory.PROPERTY_KEY);
	g_History = WarHistory.Deserialize(saved);
	-- First time in this game: wars already running began "before records".
	ReconcileHistory((saved == nil or saved == "") and -1 or nil);
	Log(string.format("history: %d wars on record", #g_History.wars));

	local function try(label, fn) local ok, err = pcall(fn); if not ok then Log("history: cannot hook " .. label .. ": " .. tostring(err)) end end
	try("DiplomacyDeclareWar", function() Events.DiplomacyDeclareWar.Add(OnHistDeclareWar) end);
	try("CityConquered",       function() GameEvents.CityConquered.Add(OnHistCityConquered) end);
	try("OnCombatOccurred",    function() GameEvents.OnCombatOccurred.Add(OnHistCombat) end);
	try("TurnEnd",             function() Events.TurnEnd.Add(function() ReconcileHistory(nil) end) end);
	try("PlayerDefeat",        function() Events.PlayerDefeat.Add(function() ReconcileHistory(nil) end) end);
end

local function CivName(id)
	local cfg = PlayerConfigurations[id];
	return Locale.Lookup(cfg:GetCivilizationShortDescription());
end

-- Tell a human target who (maybe) paid for the war on them.
-- Returns whether the sponsor was revealed.
local function NotifyTarget(sponsorID, proxyID, targetID)
	if not Players[targetID]:IsHuman() then return false end
	local revealed = Game.GetRandNum(100, "ProxyWar reveal roll") < ProxyWar.Config.REVEAL_SPONSOR_PCT;
	local msg, sum;
	if revealed then
		msg = Locale.Lookup("LOC_PROXYWAR_NOTIFY_TITLE");
		sum = Locale.Lookup("LOC_PROXYWAR_NOTIFY_REVEALED", CivName(proxyID), CivName(sponsorID));
	else
		msg = Locale.Lookup("LOC_PROXYWAR_NOTIFY_TITLE");
		sum = Locale.Lookup("LOC_PROXYWAR_NOTIFY_HIDDEN", CivName(proxyID));
	end
	NotificationManager.SendNotification(targetID, NotificationTypes.USER_DEFINED_1, msg, sum);
	Log(string.format("notified human target %d (sponsor revealed=%s)", targetID, tostring(revealed)));
	return revealed;
end

-- Returns true if the war happened and gold moved.
-- maxPrice: refuse if the authoritative price is above this (nil = no cap).
local function Execute(sponsorID, proxyID, targetID, maxPrice)
	local world = ProxyWar.GameWorld();
	local eval = ProxyWar.Evaluate(world, sponsorID, proxyID, targetID);
	if not eval.ok then
		Log("rejected: " .. eval.reason); return false;
	end
	-- Situation changed and the price went up: don't silently charge more
	-- than the sponsor agreed to.
	if maxPrice ~= nil and eval.price > maxPrice then
		Log(string.format("rejected: price rose to %d (offered %d)", eval.price, maxPrice)); return false;
	end
	if not ProxyWar.CanAfford(world, sponsorID, eval.price) then
		Log("rejected: " .. ProxyWar.Reason.NOT_ENOUGH_GOLD); return false;
	end

	local pProxyDiplo = Players[proxyID]:GetDiplomacy();
	local warType = WarTypes.SURPRISE_WAR;
	local okFormal, canFormal = pcall(function() return pProxyDiplo:CanDeclareWarOn(targetID, WarTypes.FORMAL_WAR) end);
	if okFormal and canFormal then warType = WarTypes.FORMAL_WAR end

	pProxyDiplo:DeclareWarOn(targetID, warType, true);

	if not pProxyDiplo:IsAtWarWith(targetID) then
		Log("DeclareWarOn did not take effect; no gold moved"); return false;
	end

	Players[sponsorID]:GetTreasury():ChangeGoldBalance(-eval.price);
	Players[proxyID]:GetTreasury():ChangeGoldBalance(eval.price);
	Log(string.format("SUCCESS sponsor %d paid %d gold: proxy %d now at war with %d (warType=%s)",
		sponsorID, eval.price, proxyID, targetID, tostring(warType)));

	local revealed = NotifyTarget(sponsorID, proxyID, targetID);
	WarHistory.MarkProxy(g_History, proxyID, targetID, sponsorID, revealed, Game.GetCurrentGameTurn());
	SaveHistory();
	return true;
end

-- ---------------------------------------------------------------------------
-- Human path. sponsorID is whoever issued the player operation; we never
-- trust a sponsor id coming from params.
-- ---------------------------------------------------------------------------
local function OnInstigate(sponsorID, params)
	Log(string.format("human request sponsor=%s proxy=%s target=%s offer=%s",
		tostring(sponsorID), tostring(params.Proxy), tostring(params.Target), tostring(params.Offer)));
	if params.Proxy == nil or params.Target == nil or params.Offer == nil then
		Log("rejected: malformed params"); return;
	end
	Execute(sponsorID, params.Proxy, params.Target, params.Offer);
end

-- ---------------------------------------------------------------------------
-- AI path. Runs in lockstep on every machine; only synced RNG is used.
-- ---------------------------------------------------------------------------
local function OnPlayerTurnStarted(playerID)
	local C = ProxyWar.Config;
	if not C.AI_ENABLED then return end
	local pPlayer = Players[playerID];
	if pPlayer == nil or not pPlayer:IsMajor() or pPlayer:IsHuman() or not pPlayer:IsAlive() then return end

	local world = ProxyWar.GameWorld();
	local turn = world.normalizedTurn();
	if turn < C.AI_MIN_TURN then return end

	local last = pPlayer:GetProperty(PROP_LAST_TURN);
	if last ~= nil and turn - last < C.AI_COOLDOWN_TURNS then return end

	if Game.GetRandNum(100, "ProxyWar AI roll") >= C.AI_TRY_CHANCE_PCT then return end

	local deal = ProxyWar.ChooseAIDeal(world, playerID);
	if deal == nil then return end

	Log(string.format("AI %d (%s) buying proxy war: %d -> %d for %d | value=%d profit=%d hostility=%d "
		.. "strength=%.2f dist=%s prox=%.2f targetWars=%d pileOn=%.2f leader=%.2f",
		playerID, CivName(playerID), deal.proxy, deal.target, deal.price,
		math.floor(deal.value), math.floor(deal.profit), deal.hostility, deal.strengthShare,
		tostring(deal.distance), deal.proximity, deal.targetWars, deal.pileOn, deal.leader));
	if Execute(playerID, deal.proxy, deal.target, deal.price) then
		pPlayer:SetProperty(PROP_LAST_TURN, turn);
	end
end

local function Initialize()
	InitHistory();
	GameEvents[ProxyWar.EVENT_NAME].Add(OnInstigate);
	GameEvents.PlayerTurnStarted.Add(OnPlayerTurnStarted);
	Log("loaded (AI sponsors " .. (ProxyWar.Config.AI_ENABLED and "ON" or "OFF") .. ")");
end
Initialize();
