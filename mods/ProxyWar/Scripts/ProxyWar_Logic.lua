-- Copyright (C) 2026 Dvip Patel
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ===========================================================================
-- ProxyWar_Logic.lua
--
-- Pure decision logic for "pay civ A to declare war on civ B".
-- Shared by the UI context (to show the asking price) and the gameplay
-- context (authoritative re-check before any gold moves).
--
-- Everything that touches the game goes through a `world` adapter so that
-- this file can be unit-tested outside Civ VI (see tests/run_tests.lua).
-- ===========================================================================

ProxyWar = ProxyWar or {};

ProxyWar.EVENT_NAME = "ProxyWar_Instigate";   -- GameEvents.<name>, via EXECUTE_SCRIPT

ProxyWar.Config = {
	-- Base price = BASE_GOLD + GOLD_PER_TURN * (turn normalised to Standard speed)
	BASE_GOLD          = 100,
	GOLD_PER_TURN      = 4,
	ROUND_TO           = 5,

	-- How A feels about the TARGET. Worse relations => cheaper.
	-- nil => A refuses outright.
	TARGET_STATE_MULT = {
		DIPLO_STATE_ALLIED          = nil,
		DIPLO_STATE_DECLARED_FRIEND = 3.0,
		DIPLO_STATE_FRIENDLY        = 1.75,
		DIPLO_STATE_NEUTRAL         = 1.0,
		DIPLO_STATE_UNFRIENDLY      = 0.6,
		DIPLO_STATE_DENOUNCED       = 0.35,
	},

	-- How A feels about YOU (the sponsor). Worse relations => pricier.
	SPONSOR_STATE_MULT = {
		DIPLO_STATE_ALLIED          = 0.7,
		DIPLO_STATE_DECLARED_FRIEND = 0.8,
		DIPLO_STATE_FRIENDLY        = 0.9,
		DIPLO_STATE_NEUTRAL         = 1.0,
		DIPLO_STATE_UNFRIENDLY      = 1.4,
		DIPLO_STATE_DENOUNCED       = nil,   -- won't take your money
	},

	-- Grievances A holds against B (Gathering Storm). Each point shaves a bit.
	GRIEVANCE_DISCOUNT_PER_POINT = 0.004,  -- 100 grievances => -40%
	GRIEVANCE_DISCOUNT_MAX       = 0.5,

	-- Military strength ratio A/B.
	MIN_STRENGTH_RATIO = 0.5,   -- below this A refuses: it would be suicide
	STRENGTH_MULT_MIN  = 0.6,
	STRENGTH_MULT_MAX  = 2.5,

	-- Each other war A is already fighting makes it pricier.
	BUSY_MULT_PER_WAR  = 0.5,
	MAX_OTHER_WARS     = 2,     -- more than this => refuses

	-- ---- AI sponsors -------------------------------------------------------
	AI_ENABLED          = true,
	AI_MIN_TURN         = 40,    -- normalised turn before AIs start doing it
	AI_COOLDOWN_TURNS   = 20,    -- per sponsoring AI
	AI_TRY_CHANCE_PCT   = 25,    -- chance per eligible turn to even look for a deal
	AI_MAX_GOLD_FRACTION = 0.5,  -- never spend more than this share of treasury
	AI_GOLD_RESERVE     = 100,   -- and always keep at least this much
	-- How much the sponsor wants the target hurt. Not listed => not a target.
	AI_HOSTILITY_WEIGHT = {
		DIPLO_STATE_WAR        = 3,
		DIPLO_STATE_DENOUNCED  = 2,
		DIPLO_STATE_UNFRIENDLY = 1,
	},
	-- When the target is human: chance they learn who paid.
	REVEAL_SPONSOR_PCT  = 50,

	-- ---- AI expected-value model (see ProxyWar.ScoreAIDeal) ----------------
	-- value (gold) = hostility * damage * basePrice * AI_VALUE_MULT
	-- AI buys the deal with the highest (value - price), only if it is > AI_MIN_PROFIT.
	AI_VALUE_MULT       = 1.0,
	AI_MIN_PROFIT       = 0,
	-- Distance between proxy's and target's capitals, in tiles.
	-- <= NEAR: full effect; >= FAR: PROXIMITY_MIN effect; linear between.
	PROXIMITY_NEAR      = 10,
	PROXIMITY_FAR       = 40,
	PROXIMITY_MIN       = 0.1,
	PROXIMITY_UNKNOWN   = 0.5,   -- someone has no capital
	-- Target already fighting others: each war adds this much, capped.
	PILE_ON_PER_WAR     = 0.25,
	PILE_ON_MAX         = 2.0,
	-- Balance of power: favour targets ahead on score. OFF by default --
	-- when on, a leading human becomes the AIs' favourite target.
	AI_TARGET_LEADER    = false,
	LEADER_WEIGHT       = 1.0,   -- multiplier += weight * (score/avgScore - 1), if > 0
	LEADER_MAX          = 2.0,
};

-- Reason keys double as LOC tags (LOC_PROXYWAR_REASON_<KEY>).
ProxyWar.Reason = {
	OK               = "OK",
	SAME_PLAYER      = "SAME_PLAYER",
	NOT_ALIVE        = "NOT_ALIVE",
	PROXY_IS_HUMAN   = "PROXY_IS_HUMAN",
	NOT_MET_PROXY    = "NOT_MET_PROXY",
	NOT_MET_TARGET   = "NOT_MET_TARGET",
	PROXY_NOT_MET_TARGET = "PROXY_NOT_MET_TARGET",
	SPONSOR_AT_WAR_WITH_PROXY = "SPONSOR_AT_WAR_WITH_PROXY",
	ALREADY_AT_WAR   = "ALREADY_AT_WAR",
	CANNOT_DECLARE   = "CANNOT_DECLARE",
	ALLIED_TO_TARGET = "ALLIED_TO_TARGET",
	HATES_SPONSOR    = "HATES_SPONSOR",
	TOO_WEAK         = "TOO_WEAK",
	TOO_BUSY         = "TOO_BUSY",
	NOT_ENOUGH_GOLD  = "NOT_ENOUGH_GOLD",
};

local function clamp(v, lo, hi)
	if v < lo then return lo end
	if v > hi then return hi end
	return v
end

local function roundTo(v, step)
	return math.floor(v / step + 0.5) * step
end

-- ---------------------------------------------------------------------------
-- Evaluate(world, sponsor, proxy, target)
--   returns { ok=bool, reason=<ProxyWar.Reason>, price=number|nil,
--             factors = { base, target, sponsor, grievance, strength, busy } }
--   `ok` means "the proxy will do it for `price`", ignoring sponsor gold.
--   Gold is checked separately by CanAfford so the UI can still show a price.
-- ---------------------------------------------------------------------------
function ProxyWar.Evaluate(world, sponsor, proxy, target)
	local C = ProxyWar.Config;
	local R = ProxyWar.Reason;
	local res = { ok = false, factors = {} };

	local function fail(reason) res.reason = reason; return res; end

	if sponsor == proxy or sponsor == target or proxy == target then return fail(R.SAME_PLAYER) end
	if not (world.isAliveMajor(sponsor) and world.isAliveMajor(proxy) and world.isAliveMajor(target)) then
		return fail(R.NOT_ALIVE)
	end
	if world.isHuman(proxy)              then return fail(R.PROXY_IS_HUMAN) end
	if not world.hasMet(sponsor, proxy)  then return fail(R.NOT_MET_PROXY) end
	if not world.hasMet(sponsor, target) then return fail(R.NOT_MET_TARGET) end
	if not world.hasMet(proxy, target)   then return fail(R.PROXY_NOT_MET_TARGET) end
	if world.isAtWar(sponsor, proxy)     then return fail(R.SPONSOR_AT_WAR_WITH_PROXY) end
	if world.isAtWar(proxy, target)      then return fail(R.ALREADY_AT_WAR) end

	local toTarget  = world.stateType(proxy, target);
	local toSponsor = world.stateType(proxy, sponsor);

	local mTarget = C.TARGET_STATE_MULT[toTarget];
	if toTarget == "DIPLO_STATE_ALLIED" then return fail(R.ALLIED_TO_TARGET) end
	if mTarget == nil then mTarget = 1.0 end          -- unknown state: treat as neutral

	if not world.canDeclareWar(proxy, target) then return fail(R.CANNOT_DECLARE) end

	local mSponsor = C.SPONSOR_STATE_MULT[toSponsor];
	if toSponsor == "DIPLO_STATE_DENOUNCED" then return fail(R.HATES_SPONSOR) end
	if mSponsor == nil then mSponsor = 1.0 end

	local sA = math.max(world.militaryStrength(proxy),  1);
	local sB = math.max(world.militaryStrength(target), 1);
	local ratio = sA / sB;
	if ratio < C.MIN_STRENGTH_RATIO then return fail(R.TOO_WEAK) end
	local mStrength = clamp(1 / ratio, C.STRENGTH_MULT_MIN, C.STRENGTH_MULT_MAX);

	local otherWars = world.otherWarCount(proxy, target);
	if otherWars > C.MAX_OTHER_WARS then return fail(R.TOO_BUSY) end
	local mBusy = 1 + C.BUSY_MULT_PER_WAR * otherWars;

	local grievances = math.max(world.grievances(proxy, target), 0);
	local mGrievance = 1 - math.min(grievances * C.GRIEVANCE_DISCOUNT_PER_POINT, C.GRIEVANCE_DISCOUNT_MAX);

	local base = C.BASE_GOLD + C.GOLD_PER_TURN * world.normalizedTurn();
	local price = base * mTarget * mSponsor * mStrength * mBusy * mGrievance;
	price = math.max(roundTo(price, C.ROUND_TO), C.ROUND_TO);

	res.ok     = true;
	res.reason = R.OK;
	res.price  = price;
	res.factors = {
		base = base, target = mTarget, sponsor = mSponsor, strength = mStrength,
		busy = mBusy, grievance = mGrievance, ratio = ratio, grievances = grievances,
		otherWars = otherWars, toTarget = toTarget, toSponsor = toSponsor,
	};
	return res;
end

function ProxyWar.CanAfford(world, sponsor, price)
	return price ~= nil and world.gold(sponsor) >= price;
end

-- ---------------------------------------------------------------------------
-- AI expected-value model.
--
-- damage    = strengthShare * proximity * pileOn * leader
--   strengthShare = proxyStr / (proxyStr + targetStr)       (0..1)
--   proximity     = 1 near, fading to PROXIMITY_MIN far       (capital distance)
--   pileOn        = 1 + PILE_ON_PER_WAR * target's other wars (capped)
--   leader        = 1, or > 1 for score leaders if AI_TARGET_LEADER
-- value     = hostility * damage * basePrice * AI_VALUE_MULT   (in gold)
-- profit    = value - price
--
-- basePrice is the turn-scaled base price, so "what a war is worth" grows
-- with the game at the same rate as what it costs.
-- ---------------------------------------------------------------------------
local function clamp01ish(v, lo, hi) return math.max(lo, math.min(hi, v)) end

function ProxyWar.Proximity(dist)
	local C = ProxyWar.Config;
	if dist == nil then return C.PROXIMITY_UNKNOWN end
	if dist <= C.PROXIMITY_NEAR then return 1 end
	if dist >= C.PROXIMITY_FAR  then return C.PROXIMITY_MIN end
	local t = (dist - C.PROXIMITY_NEAR) / (C.PROXIMITY_FAR - C.PROXIMITY_NEAR);
	return 1 - t * (1 - C.PROXIMITY_MIN);
end

function ProxyWar.LeaderFactor(world, target)
	local C = ProxyWar.Config;
	if not C.AI_TARGET_LEADER then return 1 end
	local total, n = 0, 0;
	for _, id in ipairs(world.majors()) do total = total + world.score(id); n = n + 1 end
	if n == 0 or total <= 0 then return 1 end
	local rel = world.score(target) / (total / n);
	return clamp01ish(1 + C.LEADER_WEIGHT * (rel - 1), 1, C.LEADER_MAX);
end

-- Scores one already-Evaluate()d, ok deal. Returns a breakdown table.
function ProxyWar.ScoreAIDeal(world, sponsor, proxy, target, hostility, eval)
	local C = ProxyWar.Config;
	local sP = math.max(world.militaryStrength(proxy), 1);
	local sT = math.max(world.militaryStrength(target), 1);
	local strengthShare = sP / (sP + sT);
	local dist          = world.capitalDistance(proxy, target);
	local proximity     = ProxyWar.Proximity(dist);
	local targetWars    = world.otherWarCount(target, proxy);
	local pileOn        = math.min(1 + C.PILE_ON_PER_WAR * targetWars, C.PILE_ON_MAX);
	local leader        = ProxyWar.LeaderFactor(world, target);
	local damage        = strengthShare * proximity * pileOn * leader;
	local value         = hostility * damage * eval.factors.base * C.AI_VALUE_MULT;
	return {
		proxy = proxy, target = target, price = eval.price, hostility = hostility,
		strengthShare = strengthShare, distance = dist, proximity = proximity,
		targetWars = targetWars, pileOn = pileOn, leader = leader,
		damage = damage, value = value, profit = value - eval.price,
	};
end

-- ---------------------------------------------------------------------------
-- ChooseAIDeal(world, sponsor) -> scored deal | nil
--   The deal with the highest expected profit that the AI can afford and
--   that clears AI_MIN_PROFIT. Iteration is over sorted ids and only a
--   strictly better profit replaces the best, so every machine in a
--   multiplayer game picks the same deal.
--   Does NOT roll dice or check cooldowns -- the caller does that.
-- ---------------------------------------------------------------------------
function ProxyWar.ChooseAIDeal(world, sponsor)
	local C = ProxyWar.Config;
	local gold = world.gold(sponsor);
	local budget = math.min(gold * C.AI_MAX_GOLD_FRACTION, gold - C.AI_GOLD_RESERVE);
	if budget <= 0 then return nil end

	local majors = world.majors();
	local best = nil;
	for _, target in ipairs(majors) do
		if target ~= sponsor and world.hasMet(sponsor, target) then
			local hostility = C.AI_HOSTILITY_WEIGHT[world.stateType(sponsor, target)];
			if world.isAtWar(sponsor, target) then hostility = C.AI_HOSTILITY_WEIGHT.DIPLO_STATE_WAR end
			if hostility then
				for _, proxy in ipairs(majors) do
					if proxy ~= sponsor and proxy ~= target then
						local e = ProxyWar.Evaluate(world, sponsor, proxy, target);
						if e.ok and e.price <= budget then
							local d = ProxyWar.ScoreAIDeal(world, sponsor, proxy, target, hostility, e);
							if d.profit > C.AI_MIN_PROFIT and (best == nil or d.profit > best.profit) then
								best = d;
							end
						end
					end
				end
			end
		end
	end
	return best;
end

-- ---------------------------------------------------------------------------
-- Live-game adapter. Works in both UI and gameplay contexts; every call is
-- pcall-guarded so a missing method degrades to a neutral value (and is
-- logged) instead of throwing inside the game.
-- ---------------------------------------------------------------------------
local function safe(label, fallback, fn, ...)
	local ok, v = pcall(fn, ...);
	if ok and v ~= nil then return v end
	if not ok then print("ProxyWar: " .. label .. " failed: " .. tostring(v)) end
	return fallback;
end

function ProxyWar.GameWorld()
	local w = {};

	function w.isAliveMajor(id)
		local p = Players[id];
		return p ~= nil and p:IsAlive() and p:IsMajor();
	end
	function w.isHuman(id)       return Players[id]:IsHuman() end
	function w.hasMet(a, b)      return Players[a]:GetDiplomacy():HasMet(b) end
	function w.isAtWar(a, b)     return Players[a]:GetDiplomacy():IsAtWarWith(b) end
	function w.canDeclareWar(a, b)
		return safe("CanDeclareWarOn", true, function() return Players[a]:GetDiplomacy():CanDeclareWarOn(b) end);
	end
	function w.stateType(a, b)
		return safe("GetDiplomaticStateIndex", "DIPLO_STATE_NEUTRAL", function()
			local idx = Players[a]:GetDiplomaticAI():GetDiplomaticStateIndex(b);
			local row = GameInfo.DiplomaticStates[idx];
			return row and row.StateType;
		end);
	end
	function w.grievances(a, b)
		return safe("GetGrievancesAgainst", 0, function() return Players[a]:GetDiplomacy():GetGrievancesAgainst(b) end);
	end
	function w.militaryStrength(id)
		return safe("GetMilitaryStrength", 1, function() return Players[id]:GetStats():GetMilitaryStrengthWithoutTreasury() end);
	end
	function w.otherWarCount(a, exclude)
		local n = 0;
		local d = Players[a]:GetDiplomacy();
		for _, id in ipairs(PlayerManager.GetAliveMajorIDs()) do
			if id ~= a and id ~= exclude and d:IsAtWarWith(id) then n = n + 1 end
		end
		return n;
	end
	function w.majors()
		local ids = {};
		for _, id in ipairs(PlayerManager.GetAliveMajorIDs()) do table.insert(ids, id) end
		table.sort(ids);   -- deterministic iteration order
		return ids;
	end
	function w.capitalDistance(a, b)
		return safe("capitalDistance", nil, function()
			local ca = Players[a]:GetCities():GetCapitalCity();
			local cb = Players[b]:GetCities():GetCapitalCity();
			if ca == nil or cb == nil then return nil end
			return Map.GetPlotDistance(ca:GetX(), ca:GetY(), cb:GetX(), cb:GetY());
		end);
	end
	function w.score(id)
		return safe("GetScore", 0, function() return Players[id]:GetScore() end);
	end
	function w.gold(id)
		return safe("GetGoldBalance", 0, function() return Players[id]:GetTreasury():GetGoldBalance() end);
	end
	function w.normalizedTurn()
		local turn = Game.GetCurrentGameTurn() - GameConfiguration.GetStartTurn();
		local speedMult = safe("GameSpeed", 100, function()
			return GameInfo.GameSpeeds[GameConfiguration.GetGameSpeedType()].CostMultiplier;
		end);
		return math.max(turn, 0) * 100 / speedMult;
	end
	return w;
end
