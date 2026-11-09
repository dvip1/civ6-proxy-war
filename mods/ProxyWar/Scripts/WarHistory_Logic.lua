-- Copyright (C) 2026 Dvip Patel
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ===========================================================================
-- WarHistory_Logic.lua
--
-- Pure bookkeeping for the War History tab. Written by the gameplay script
-- (which persists it in a Game property so it lives in the save file) and
-- read by the UI. No game API calls except through the `world` adapter
-- passed to Reconcile, so it is unit-testable outside Civ VI.
--
-- A war is one pair of major civs (Civ VI wars are pairwise; a joint war is
-- several pairwise wars). Record fields:
--   id  sequential id          a, b  the two sides (a = declarer if ag == 1)
--   n   ordinal for this pair  st/et start/end turn (et = -1 while ongoing)
--   ca/cb cities captured by a/b      ka/kb units destroyed by a/b
--   ag  1 = a declared, 0 = unknown (war found by reconcile, not by event)
--   sp  sponsoring player if a proxy war, else -1
--   rv  1 if the sponsor was revealed to b
--   en  end type: 0 ongoing, 1 peace, 2 conquest (someone eliminated)
--   el  eliminated player or -1
-- ===========================================================================

WarHistory = WarHistory or {};

WarHistory.PROPERTY_KEY = "WARHIST_DATA_V1";
WarHistory.FIELDS = { "id", "a", "b", "n", "st", "et", "ca", "cb", "ka", "kb", "ag", "sp", "rv", "en", "el" };
WarHistory.END_ONGOING, WarHistory.END_PEACE, WarHistory.END_CONQUEST = 0, 1, 2;

WarHistory.Config = {
	CITY_POINTS      = 3,     -- a captured city is worth this many unit kills
	MIN_POINTS       = 2,     -- fewer total points than this => stalemate
	VICTORY_MARGIN   = 0.15,  -- (pa - pb) / (pa + pb)
	DECISIVE_MARGIN  = 0.5,
};

-- Outcome codes double as LOC suffixes (LOC_WARHIST_OUTCOME_<code>)
WarHistory.Outcome = {
	ONGOING = "ONGOING", STALEMATE = "STALEMATE", VICTORY = "VICTORY",
	DECISIVE = "DECISIVE", CONQUEST = "CONQUEST",
};

function WarHistory.New() return { nextId = 1, wars = {} } end

-- ---------------------------------------------------------------------------
-- Serialisation: "id,a,b,...;id,a,b,...". Numbers only.
-- ---------------------------------------------------------------------------
function WarHistory.Serialize(state)
	local out = {};
	for _, w in ipairs(state.wars) do
		local row = {};
		for i, f in ipairs(WarHistory.FIELDS) do row[i] = tostring(w[f]) end
		out[#out + 1] = table.concat(row, ",");
	end
	return table.concat(out, ";");
end

function WarHistory.Deserialize(s)
	local state = WarHistory.New();
	if type(s) ~= "string" or s == "" then return state end
	for rec in s:gmatch("[^;]+") do
		local w, i = {}, 1;
		for v in rec:gmatch("[^,]+") do
			local f = WarHistory.FIELDS[i];
			if f then w[f] = tonumber(v) end
			i = i + 1;
		end
		if w.id and w.a and w.b then
			for _, f in ipairs(WarHistory.FIELDS) do if w[f] == nil then w[f] = -1 end end
			table.insert(state.wars, w);
			if w.id >= state.nextId then state.nextId = w.id + 1 end
		end
	end
	return state;
end

-- ---------------------------------------------------------------------------
local function samePair(w, x, y) return (w.a == x and w.b == y) or (w.a == y and w.b == x) end

function WarHistory.FindActive(state, x, y)
	for i = #state.wars, 1, -1 do
		local w = state.wars[i];
		if w.en == WarHistory.END_ONGOING and samePair(w, x, y) then return w end
	end
	return nil;
end

local function pairCount(state, x, y)
	local n = 0;
	for _, w in ipairs(state.wars) do if samePair(w, x, y) then n = n + 1 end end
	return n;
end

-- Idempotent: returns the existing ongoing war if there is one. If that war
-- was found by reconcile (aggressor unknown) and we now learn who declared,
-- fill it in.
function WarHistory.Declare(state, aggressor, defender, turn, known)
	local w = WarHistory.FindActive(state, aggressor, defender);
	if w then
		if known and w.ag == 0 then
			w.a, w.b, w.ca, w.cb, w.ka, w.kb = aggressor, defender,
				(w.a == aggressor) and w.ca or w.cb, (w.a == aggressor) and w.cb or w.ca,
				(w.a == aggressor) and w.ka or w.kb, (w.a == aggressor) and w.kb or w.ka;
			w.ag = 1;
		end
		return w, false;
	end
	w = {
		id = state.nextId, a = aggressor, b = defender, n = pairCount(state, aggressor, defender) + 1,
		st = turn, et = -1, ca = 0, cb = 0, ka = 0, kb = 0,
		ag = known and 1 or 0, sp = -1, rv = 0, en = WarHistory.END_ONGOING, el = -1,
	};
	state.nextId = state.nextId + 1;
	table.insert(state.wars, w);
	return w, true;
end

function WarHistory.MarkProxy(state, proxy, target, sponsor, revealed, turn)
	local w = WarHistory.Declare(state, proxy, target, turn, true);
	w.sp = sponsor;
	w.rv = revealed and 1 or 0;
	return w;
end

local function credit(state, winner, loser, fieldA, fieldB)
	local w = WarHistory.FindActive(state, winner, loser);
	if w == nil then return false end
	if w.a == winner then w[fieldA] = w[fieldA] + 1 else w[fieldB] = w[fieldB] + 1 end
	return true;
end

function WarHistory.CityCaptured(state, capturer, owner) return credit(state, capturer, owner, "ca", "cb") end
function WarHistory.UnitKilled(state, killer, victim)    return credit(state, killer, victim, "ka", "kb") end

function WarHistory.EndPeace(state, x, y, turn)
	local w = WarHistory.FindActive(state, x, y);
	if w == nil then return nil end
	w.en, w.et = WarHistory.END_PEACE, turn;
	return w;
end

-- Close every ongoing war of `loser` as a conquest by the other side.
function WarHistory.Eliminated(state, loser, turn)
	local closed = 0;
	for _, w in ipairs(state.wars) do
		if w.en == WarHistory.END_ONGOING and (w.a == loser or w.b == loser) then
			w.en, w.et, w.el = WarHistory.END_CONQUEST, turn, loser;
			closed = closed + 1;
		end
	end
	return closed;
end

-- ---------------------------------------------------------------------------
-- Reconcile with the actual game state (end of every turn, and on load).
-- world: majors() -> sorted alive major ids, isAlive(id), isAtWar(a, b)
-- Returns true if anything changed.
-- ---------------------------------------------------------------------------
-- seedTurn: start turn to record for wars discovered here (default `turn`);
-- pass -1 on the first load into an existing game ("began before records").
function WarHistory.Reconcile(state, world, turn, seedTurn)
	local changed = false;
	for _, w in ipairs(state.wars) do
		if w.en == WarHistory.END_ONGOING then
			if not world.isAlive(w.a) then
				WarHistory.Eliminated(state, w.a, turn); changed = true;
			elseif not world.isAlive(w.b) then
				WarHistory.Eliminated(state, w.b, turn); changed = true;
			elseif not world.isAtWar(w.a, w.b) then
				w.en, w.et = WarHistory.END_PEACE, turn; changed = true;
			end
		end
	end
	local majors = world.majors();
	for i = 1, #majors do
		for j = i + 1, #majors do
			local x, y = majors[i], majors[j];
			if world.isAtWar(x, y) and WarHistory.FindActive(state, x, y) == nil then
				WarHistory.Declare(state, x, y, seedTurn or turn, false); changed = true;
			end
		end
	end
	return changed;
end

-- ---------------------------------------------------------------------------
-- GetOutcome(w) -> code, winnerId|nil
-- ---------------------------------------------------------------------------
function WarHistory.GetOutcome(w)
	local C, O = WarHistory.Config, WarHistory.Outcome;
	if w.en == WarHistory.END_ONGOING then
		return O.ONGOING, nil;
	end
	if w.en == WarHistory.END_CONQUEST then
		return O.CONQUEST, (w.el == w.a) and w.b or w.a;
	end
	local pa = w.ca * C.CITY_POINTS + w.ka;
	local pb = w.cb * C.CITY_POINTS + w.kb;
	local total = pa + pb;
	if total < C.MIN_POINTS then return O.STALEMATE, nil end
	local margin = (pa - pb) / total;
	local winner = margin > 0 and w.a or w.b;
	margin = math.abs(margin);
	if margin >= C.DECISIVE_MARGIN then return O.DECISIVE, winner end
	if margin >= C.VICTORY_MARGIN  then return O.VICTORY, winner end
	return O.STALEMATE, nil;
end

-- For display: ongoing first (newest first), then ended (most recently ended first).
function WarHistory.Sorted(state, filter)
	local list = {};
	for _, w in ipairs(state.wars) do
		if filter == nil or filter(w) then table.insert(list, w) end
	end
	table.sort(list, function(x, y)
		local xo, yo = x.en == WarHistory.END_ONGOING, y.en == WarHistory.END_ONGOING;
		if xo ~= yo then return xo end
		if xo then
			if x.st ~= y.st then return x.st > y.st end
		else
			if x.et ~= y.et then return x.et > y.et end
		end
		return x.id > y.id;
	end);
	return list;
end
