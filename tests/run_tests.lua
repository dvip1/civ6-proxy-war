-- Copyright (C) 2026 Dvip Patel
-- SPDX-License-Identifier: GPL-3.0-or-later
-- Offline tests for ProxyWar_Logic.lua. Run: luajit tests/run_tests.lua
-- (from the repo root). No Civ VI needed: the game is replaced by a fake world.

package.path = "./mods/ProxyWar/Scripts/?.lua;" .. package.path
dofile("mods/ProxyWar/Scripts/ProxyWar_Logic.lua")

local R = ProxyWar.Reason
local passed, failed = 0, 0

local function check(name, cond, msg)
	if cond then passed = passed + 1
	else failed = failed + 1; print("FAIL " .. name .. (msg and (": " .. msg) or "")) end
end

-- Fake world: players 0 (sponsor/human), 1 (proxy AI), 2 (target), 3 (other)
local function makeWorld(o)
	o = o or {}
	local w = {}
	local function key(a, b) return a .. ">" .. b end
	local states = o.states or {}
	local wars = o.wars or {}
	function w.isAliveMajor(id) return not (o.dead and o.dead[id]) end
	function w.isHuman(id) return id == 0 or (o.humans and o.humans[id]) or false end
	function w.hasMet(a, b) return not (o.unmet and (o.unmet[key(a, b)] or o.unmet[key(b, a)])) end
	function w.isAtWar(a, b) return wars[key(a, b)] or wars[key(b, a)] or false end
	function w.canDeclareWar(a, b) return not (o.blocked and o.blocked[key(a, b)]) end
	function w.stateType(a, b) return states[key(a, b)] or "DIPLO_STATE_NEUTRAL" end
	function w.grievances(a, b) return (o.grievances and o.grievances[key(a, b)]) or 0 end
	function w.militaryStrength(id) return (o.strength and o.strength[id]) or 100 end
	function w.otherWarCount(a, exclude)
		local n = 0
		for id = 0, 3 do if id ~= a and id ~= exclude and w.isAtWar(a, id) then n = n + 1 end end
		return n
	end
	function w.capitalDistance(a, b)
		local d = o.dist and (o.dist[key(a, b)] or o.dist[key(b, a)])
		if d == false then return nil end
		return d or 5   -- default: neighbours
	end
	function w.score(id) return (o.score and o.score[id]) or 100 end
	function w.majors() return o.majors or { 0, 1, 2, 3 } end
	function w.gold(id) return (o.gold and o.gold[id]) or 1000 end
	function w.normalizedTurn() return o.turn or 50 end
	return w
end

local function ev(o) return ProxyWar.Evaluate(makeWorld(o), 0, 1, 2) end

-- Baseline: neutral everything, turn 50 -> 100 + 4*50 = 300
do
	local r = ev()
	check("baseline ok", r.ok, tostring(r.reason))
	check("baseline price", r.price == 300, tostring(r.price))
end

-- Refusals
check("same player", ProxyWar.Evaluate(makeWorld(), 0, 1, 1).reason == R.SAME_PLAYER)
check("sponsor as target", ProxyWar.Evaluate(makeWorld(), 0, 1, 0).reason == R.SAME_PLAYER)
check("dead target", ev{ dead = { [2] = true } }.reason == R.NOT_ALIVE)
check("human proxy", ev{ humans = { [1] = true } }.reason == R.PROXY_IS_HUMAN)
check("unmet proxy", ev{ unmet = { ["0>1"] = true } }.reason == R.NOT_MET_PROXY)
check("unmet target", ev{ unmet = { ["0>2"] = true } }.reason == R.NOT_MET_TARGET)
check("proxy unmet target", ev{ unmet = { ["1>2"] = true } }.reason == R.PROXY_NOT_MET_TARGET)
check("at war w/ sponsor", ev{ wars = { ["0>1"] = true } }.reason == R.SPONSOR_AT_WAR_WITH_PROXY)
check("already at war", ev{ wars = { ["1>2"] = true } }.reason == R.ALREADY_AT_WAR)
check("allied", ev{ states = { ["1>2"] = "DIPLO_STATE_ALLIED" } }.reason == R.ALLIED_TO_TARGET)
check("treaty", ev{ blocked = { ["1>2"] = true } }.reason == R.CANNOT_DECLARE)
check("hates sponsor", ev{ states = { ["1>0"] = "DIPLO_STATE_DENOUNCED" } }.reason == R.HATES_SPONSOR)
check("too weak", ev{ strength = { [1] = 40, [2] = 100 } }.reason == R.TOO_WEAK)
check("too busy", ev{ wars = { ["1>3"] = true, ["1>0"] = false } }.ok) -- 1 war is fine

-- Too busy needs > MAX_OTHER_WARS other wars; widen the fake world.
do
	local w = makeWorld()
	w.otherWarCount = function() return 3 end
	check("too busy (3 wars)", ProxyWar.Evaluate(w, 0, 1, 2).reason == R.TOO_BUSY)
end

-- Pricing direction: bad relations are cheaper, good are pricier
do
	local base = ev().price
	local hate = ev{ states = { ["1>2"] = "DIPLO_STATE_DENOUNCED" } }.price
	local unf  = ev{ states = { ["1>2"] = "DIPLO_STATE_UNFRIENDLY" } }.price
	local fr   = ev{ states = { ["1>2"] = "DIPLO_STATE_FRIENDLY" } }.price
	local df   = ev{ states = { ["1>2"] = "DIPLO_STATE_DECLARED_FRIEND" } }.price
	check("denounced < unfriendly < neutral < friendly < declared friend",
		hate < unf and unf < base and base < fr and fr < df,
		string.format("%d %d %d %d %d", hate, unf, base, fr, df))
	check("denounced price", hate == 105, tostring(hate))  -- 300 * 0.35
end

do
	local g0  = ev().price
	local g50 = ev{ grievances = { ["1>2"] = 50 } }.price
	local g1k = ev{ grievances = { ["1>2"] = 1000 } }.price
	local neg = ev{ grievances = { ["1>2"] = -80 } }.price
	check("grievances discount", g50 < g0, g50 .. " vs " .. g0)
	check("grievance discount capped at 50%", g1k == 150, tostring(g1k))
	check("negative grievances ignored", neg == g0, tostring(neg))
end

do
	local friend = ev{ states = { ["1>0"] = "DIPLO_STATE_DECLARED_FRIEND" } }.price
	local unf    = ev{ states = { ["1>0"] = "DIPLO_STATE_UNFRIENDLY" } }.price
	check("likes sponsor => cheaper", friend < 300, tostring(friend))
	check("dislikes sponsor => pricier", unf > 300, tostring(unf))
end

do
	local strong = ev{ strength = { [1] = 400, [2] = 100 } }.price
	local even   = ev().price
	local weakish = ev{ strength = { [1] = 60, [2] = 100 } }.price
	check("strength ordering", strong < even and even < weakish, strong .. " " .. even .. " " .. weakish)
	check("strength floor 0.6", strong == 180, tostring(strong))
	local zero = ev{ strength = { [1] = 0, [2] = 0 } }
	check("zero strength no div-by-zero", zero.ok and zero.price == 300, tostring(zero.price))
end

do
	local busy = ev{ wars = { ["1>3"] = true } }.price
	check("one other war +50%", busy == 450, tostring(busy))
end

do
	check("price scales with turn", ev{ turn = 0 }.price == 100 and ev{ turn = 200 }.price == 900)
	local r = ev{ states = { ["1>2"] = "DIPLO_STATE_DENOUNCED" }, grievances = { ["1>2"] = 1000 },
		strength = { [1] = 1000, [2] = 1 }, turn = 0 }
	check("price never below ROUND_TO", r.price >= ProxyWar.Config.ROUND_TO and r.price % 5 == 0, tostring(r.price))
end

do
	local w = makeWorld{ gold = { [0] = 299 } }
	check("cannot afford", not ProxyWar.CanAfford(w, 0, 300))
	check("can afford exact", ProxyWar.CanAfford(makeWorld{ gold = { [0] = 300 } }, 0, 300))
	check("nil price not affordable", not ProxyWar.CanAfford(w, 0, nil))
end

-- ---------------------------------------------------------------------------
-- AI sponsors: expected-value model. Sponsor is AI player 1; 0 is the human.
-- Defaults: turn 50 => basePrice 300, equal strength => strengthShare 0.5,
-- capitals 5 tiles apart => proximity 1, no other wars => pileOn 1.
-- So value = hostility * 0.5 * 300 = 150 * hostility.
-- ---------------------------------------------------------------------------
local function choose(o, sponsor) return ProxyWar.ChooseAIDeal(makeWorld(o), sponsor or 1) end
local function near(a, b, eps) return math.abs(a - b) < (eps or 1e-6) end

check("AI: no hostility => no deal", choose{} == nil)

do
	-- Proximity curve
	check("prox near", ProxyWar.Proximity(3) == 1)
	check("prox far", near(ProxyWar.Proximity(100), 0.1))
	check("prox mid", near(ProxyWar.Proximity(25), 0.55), tostring(ProxyWar.Proximity(25)))
	check("prox unknown", ProxyWar.Proximity(nil) == 0.5)
end

do
	-- Denounced human 0 (H=2) => value 300. Proxy 2 also denounced 0 => price 105, profit 195.
	-- Proxy 3 neutral => price 300, profit 0 (not > 0).
	local d = choose{ states = { ["1>0"] = "DIPLO_STATE_DENOUNCED", ["2>0"] = "DIPLO_STATE_DENOUNCED" } }
	check("AI: targets the human it hates", d and d.target == 0, d and (d.proxy .. ">" .. d.target))
	check("AI: picks the proxy that hates the target", d and d.proxy == 2)
	check("AI: value/profit math", d and near(d.value, 300) and near(d.profit, 195),
		d and (d.value .. " " .. d.profit))
end

do
	-- Unfriendly (H=1) => value 150 < neutral proxy price 300 => not worth it.
	check("AI: unprofitable => no deal", choose{ states = { ["1>3"] = "DIPLO_STATE_UNFRIENDLY" } } == nil)
	-- At war (H=3). The sponsor's own war also counts as pile-on (a second
	-- front), so value = 3 * 0.5 * 1.25 * 300 = 562.5; neutral proxy 300 => profit 262.5.
	local d = choose{ wars = { ["1>3"] = true } }
	check("AI: war target worth a neutral proxy", d and d.target == 3 and near(d.profit, 262.5),
		d and tostring(d.profit))
end

do
	-- Never uses a human as proxy.
	local d = choose{ states = { ["1>3"] = "DIPLO_STATE_DENOUNCED", ["0>3"] = "DIPLO_STATE_DENOUNCED" } }
	check("AI: never picks human proxy", d == nil or d.proxy ~= 0, d and tostring(d.proxy))
end

do
	-- Budget: war target, neutral proxy, price 300. 1000 gold => budget 500 ok;
	-- 500 gold => budget 250 too small; 50 gold => reserve.
	local o = { wars = { ["1>3"] = true } }
	check("AI: affordable deal found", choose(o) ~= nil)
	o.gold = { [1] = 500 };  check("AI: respects spend fraction", choose(o) == nil)
	o.gold = { [1] = 50 };   check("AI: respects reserve", choose(o) == nil)
end

do
	-- Proximity: two proxies hate target 0 equally; 2 is far, 3 is near.
	local o = { states = { ["1>0"] = "DIPLO_STATE_DENOUNCED",
	                       ["2>0"] = "DIPLO_STATE_DENOUNCED", ["3>0"] = "DIPLO_STATE_DENOUNCED" },
	            dist = { ["2>0"] = 60, ["3>0"] = 8 } }
	local d = choose(o)
	check("AI: prefers the nearby proxy", d and d.proxy == 3, d and tostring(d.proxy))
	-- Only the far one available => value 2*0.5*0.1*300 = 30 < 105 => no deal.
	o.states["3>0"] = nil
	check("AI: far-away proxy not worth it", choose(o) == nil)
end

do
	-- Pile-on: sponsor denounced both 2 and 3; proxy pool is the other one.
	-- Add a 4th civ fighting target 3 => pileOn 1.25 for target 3.
	local o = { majors = { 0, 1, 2, 3, 4 },
	            states = { ["1>2"] = "DIPLO_STATE_DENOUNCED", ["1>3"] = "DIPLO_STATE_DENOUNCED",
	                       ["4>2"] = "DIPLO_STATE_DENOUNCED", ["4>3"] = "DIPLO_STATE_DENOUNCED" },
	            wars = { ["0>3"] = true } }
	local d = choose(o)
	check("AI: piles on target already at war", d and d.target == 3 and near(d.pileOn, 1.25),
		d and (d.target .. " " .. d.pileOn))
end

do
	-- Strength share feeds value: a much stronger proxy is worth more.
	local o = { states = { ["1>0"] = "DIPLO_STATE_DENOUNCED", ["2>0"] = "DIPLO_STATE_DENOUNCED" },
	            strength = { [2] = 300, [0] = 100 } }
	local d = choose(o)
	check("AI: strength share", d and near(d.strengthShare, 0.75), d and tostring(d.strengthShare))
end

do
	-- Leader targeting: OFF by default => score ignored.
	local o = { states = { ["1>2"] = "DIPLO_STATE_DENOUNCED", ["1>3"] = "DIPLO_STATE_DENOUNCED",
	                       ["0>2"] = "DIPLO_STATE_DENOUNCED", ["0>3"] = "DIPLO_STATE_DENOUNCED" },
	            majors = { 0, 1, 2, 3, 4 }, score = { [3] = 400 } }
	-- proxies: 4 (neutral both) or the other target; make 2 and 3 hate each other
	o.states["2>3"] = "DIPLO_STATE_DENOUNCED"; o.states["3>2"] = "DIPLO_STATE_DENOUNCED"
	local off = choose(o)
	check("AI: leader off => lowest id wins tie", off and off.target == 2 and off.leader == 1,
		off and (off.target .. " " .. off.leader))
	ProxyWar.Config.AI_TARGET_LEADER = true
	local on = choose(o)
	ProxyWar.Config.AI_TARGET_LEADER = false
	-- avg = (100*4+400)/5 = 160; rel = 2.5 => 1 + 1.5 = 2.5 capped at 2.0
	check("AI: leader on => targets the score leader", on and on.target == 3 and near(on.leader, 2.0),
		on and (on.target .. " " .. on.leader))
end

do
	local o = { states = { ["1>2"] = "DIPLO_STATE_DENOUNCED", ["1>3"] = "DIPLO_STATE_DENOUNCED",
	                       ["2>3"] = "DIPLO_STATE_DENOUNCED", ["3>2"] = "DIPLO_STATE_DENOUNCED" } }
	local a, b = choose(o), choose(o)
	check("AI: deterministic", a and b and a.proxy == b.proxy and a.target == b.target and a.price == b.price)
end

-- Every reason has a LOC string
do
	local f = io.open("mods/ProxyWar/Text/en_US/ProxyWar_Text.xml"):read("*a")
	for _, reason in pairs(R) do
		check("LOC for " .. reason, f:find('Tag="LOC_PROXYWAR_REASON_' .. reason .. '"', 1, true) ~= nil)
	end
end

print(string.format("%d passed, %d failed", passed, failed))
os.exit(failed == 0 and 0 or 1)
