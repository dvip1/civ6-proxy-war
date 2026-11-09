-- Copyright (C) 2026 Dvip Patel
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Offline tests for WarHistory_Logic.lua. Run from repo root: luajit tests/run_history_tests.lua
dofile("mods/ProxyWar/Scripts/WarHistory_Logic.lua")

local H, O = WarHistory, WarHistory.Outcome
local passed, failed = 0, 0
local function check(name, cond, msg)
	if cond then passed = passed + 1
	else failed = failed + 1; print("FAIL " .. name .. (msg and (": " .. msg) or "")) end
end

-- Declare / ordinals -----------------------------------------------------------
do
	local s = H.New()
	local w1, created = H.Declare(s, 1, 2, 10, true)
	check("declare creates", created and w1.n == 1 and w1.a == 1 and w1.b == 2 and w1.st == 10 and w1.ag == 1)
	local again, created2 = H.Declare(s, 2, 1, 11, true)
	check("declare idempotent (either order)", again == w1 and not created2 and #s.wars == 1)
	H.EndPeace(s, 2, 1, 20)
	check("peace closes", w1.en == H.END_PEACE and w1.et == 20)
	local w2 = H.Declare(s, 2, 1, 30, true)
	check("second war on same pair", w2.n == 2 and w2.a == 2 and w2.id == 2)
	local w3 = H.Declare(s, 1, 3, 31, true)
	check("ordinal is per pair", w3.n == 1)
end

-- Captures and kills credit the right side ---------------------------------------
do
	local s = H.New()
	local w = H.Declare(s, 1, 2, 10, true)
	H.CityCaptured(s, 1, 2); H.CityCaptured(s, 2, 1); H.CityCaptured(s, 2, 1)
	H.UnitKilled(s, 1, 2); H.UnitKilled(s, 1, 2); H.UnitKilled(s, 2, 1)
	check("captures", w.ca == 1 and w.cb == 2, w.ca .. " " .. w.cb)
	check("kills", w.ka == 2 and w.kb == 1, w.ka .. " " .. w.kb)
	check("no war => not credited", H.UnitKilled(s, 1, 3) == false)
	H.EndPeace(s, 1, 2, 15)
	check("ended war => not credited", H.CityCaptured(s, 1, 2) == false and w.ca == 1)
end

-- Unknown-aggressor record gets fixed when the declaration is learned --------------
do
	local s = H.New()
	local w = H.Declare(s, 1, 2, 10, false)          -- found by reconcile: a=1,b=2 arbitrary
	H.UnitKilled(s, 2, 1); H.CityCaptured(s, 2, 1)   -- 2 is winning
	H.Declare(s, 2, 1, 10, true)                     -- now we learn 2 declared
	check("aggressor fixed", w.a == 2 and w.b == 1 and w.ag == 1)
	check("counters follow the swap", w.ka == 1 and w.ca == 1 and w.kb == 0 and w.cb == 0,
		string.format("%d %d %d %d", w.ka, w.kb, w.ca, w.cb))
end

-- Outcomes -----------------------------------------------------------------------------
do
	local function ended(ca, cb, ka, kb)
		return { a = 1, b = 2, ca = ca, cb = cb, ka = ka, kb = kb, en = H.END_PEACE, el = -1 }
	end
	check("ongoing", H.GetOutcome({ a = 1, b = 2, en = H.END_ONGOING }) == O.ONGOING)
	check("nothing happened => stalemate", H.GetOutcome(ended(0, 0, 0, 1)) == O.STALEMATE)
	check("close fight => stalemate", H.GetOutcome(ended(0, 0, 10, 9)) == O.STALEMATE)
	local c, wnr = H.GetOutcome(ended(0, 0, 6, 4))     -- margin 0.2
	check("victory", c == O.VICTORY and wnr == 1, c)
	c, wnr = H.GetOutcome(ended(0, 2, 1, 1))           -- 1 vs 7 => margin 0.75 for b
	check("decisive for b (cities weigh 3)", c == O.DECISIVE and wnr == 2, c)
	c, wnr = H.GetOutcome({ a = 1, b = 2, ca = 0, cb = 0, ka = 0, kb = 9, en = H.END_CONQUEST, el = 2 })
	check("conquest: eliminated side loses regardless of stats", c == O.CONQUEST and wnr == 1)
end

-- Elimination closes all of the loser's wars ---------------------------------------------
do
	local s = H.New()
	local w12 = H.Declare(s, 1, 2, 10, true)
	local w32 = H.Declare(s, 3, 2, 12, true)
	local w13 = H.Declare(s, 1, 3, 12, true)
	check("eliminated count", H.Eliminated(s, 2, 40) == 2)
	check("eliminated wars closed", w12.en == H.END_CONQUEST and w32.en == H.END_CONQUEST and w12.el == 2)
	check("unrelated war untouched", w13.en == H.END_ONGOING)
end

-- Reconcile --------------------------------------------------------------------------------
do
	local wars, alive = { ["0>3"] = true }, { [0] = true, [1] = true, [2] = true, [3] = true }
	local world = {
		majors = function() local t = {}; for id = 0, 3 do if alive[id] then t[#t + 1] = id end end; return t end,
		isAlive = function(id) return alive[id] == true end,
		isAtWar = function(a, b) return wars[a .. ">" .. b] or wars[b .. ">" .. a] or false end,
	}
	local s = H.New()
	check("seed: finds existing war", H.Reconcile(s, world, 100, -1) and #s.wars == 1)
	check("seed: unknown start + aggressor", s.wars[1].st == -1 and s.wars[1].ag == 0)
	check("no change => false", H.Reconcile(s, world, 101) == false)

	wars["0>3"] = nil
	H.Reconcile(s, world, 105)
	check("peace detected", s.wars[1].en == H.END_PEACE and s.wars[1].et == 105)

	wars["1>2"] = true
	H.Reconcile(s, world, 110)
	check("new war found at current turn", #s.wars == 2 and s.wars[2].st == 110)

	alive[2] = false; wars["1>2"] = nil
	H.Reconcile(s, world, 120)
	check("elimination detected", s.wars[2].en == H.END_CONQUEST and s.wars[2].el == 2)
end

-- Proxy marking ------------------------------------------------------------------------------
do
	local s = H.New()
	local w = H.MarkProxy(s, 4, 0, 2, true, 50)
	check("proxy creates war", w.a == 4 and w.b == 0 and w.sp == 2 and w.rv == 1 and w.ag == 1)
	local again = H.Declare(s, 4, 0, 50, true)       -- the declare-war event arriving afterwards
	check("declare after proxy keeps sponsor", again == w and w.sp == 2 and #s.wars == 1)
	local s2 = H.New()
	H.Declare(s2, 4, 0, 50, true)                    -- event first, then proxy marking
	local w2 = H.MarkProxy(s2, 4, 0, 2, false, 50)
	check("proxy after declare", #s2.wars == 1 and w2.sp == 2 and w2.rv == 0)
end

-- Serialisation --------------------------------------------------------------------------------
do
	local s = H.New()
	local w = H.Declare(s, 1, 2, 10, true); H.UnitKilled(s, 1, 2); H.EndPeace(s, 1, 2, 22)
	H.MarkProxy(s, 3, 0, 1, true, 30)
	local str = H.Serialize(s)
	local r = H.Deserialize(str)
	check("roundtrip count", #r.wars == 2)
	local ok = true
	for i, rw in ipairs(r.wars) do
		for _, f in ipairs(H.FIELDS) do if rw[f] ~= s.wars[i][f] then ok = false; print("  field " .. f) end end
	end
	check("roundtrip fields (incl. negatives)", ok)
	check("roundtrip nextId", r.nextId == 3)
	check("serialize is stable", H.Serialize(r) == str)
	check("empty/nil", #H.Deserialize(nil).wars == 0 and #H.Deserialize("").wars == 0)
	check("garbage tolerated", #H.Deserialize(";;x,y;").wars == 0)
	local big = H.New()
	for i = 1, 300 do H.Declare(big, i % 7, 7 + i % 5, i, true); H.EndPeace(big, i % 7, 7 + i % 5, i + 1) end
	check("300 wars roundtrip", #H.Deserialize(H.Serialize(big)).wars == 300)
end

-- Sorting: ongoing first (newest), then ended (most recently ended) ------------------------------
do
	local s = H.New()
	H.Declare(s, 1, 2, 5, true);  H.EndPeace(s, 1, 2, 9)    -- id1 ended 9
	H.Declare(s, 1, 3, 6, true);  H.EndPeace(s, 1, 3, 15)   -- id2 ended 15
	H.Declare(s, 2, 3, 20, true)                            -- id3 ongoing from 20
	H.Declare(s, 0, 1, 25, true)                            -- id4 ongoing from 25
	local ids = {}
	for _, w in ipairs(H.Sorted(s)) do ids[#ids + 1] = w.id end
	check("sort order", table.concat(ids, ",") == "4,3,2,1", table.concat(ids, ","))
	check("filter", #H.Sorted(s, function(w) return w.a == 1 end) == 2)
end

-- Every outcome and ordinal 1..10 has text --------------------------------------------------------
do
	local f = io.open("mods/ProxyWar/Text/en_US/ProxyWar_Text.xml"):read("*a")
	for _, code in pairs(O) do
		check("LOC outcome " .. code, f:find('Tag="LOC_WARHIST_OUTCOME_' .. code .. '"', 1, true) ~= nil)
	end
	for i = 1, 10 do
		check("LOC ordinal " .. i, f:find('Tag="LOC_WARHIST_ORDINAL_' .. i .. '"', 1, true) ~= nil)
	end
end

print(string.format("history: %d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
