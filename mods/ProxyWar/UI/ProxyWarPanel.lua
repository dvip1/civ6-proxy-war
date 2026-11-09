-- Copyright (C) 2026 Dvip Patel
-- SPDX-License-Identifier: GPL-3.0-or-later
-- ===========================================================================
-- ProxyWarPanel.lua  (UI context, AddUserInterfaces / InGame)
--
-- Popup where the local player picks a proxy civ (A) and a target civ (B),
-- sees A's asking price, and pays. The actual war + gold transfer happens in
-- the gameplay script via a networked EXECUTE_SCRIPT player operation, so it
-- is multiplayer safe.
-- ===========================================================================
include("InstanceManager");
include("ProxyWar_Logic");
include("WarHistory_Logic");

local HOOK_BAR_PATH = "/InGame/PartialScreenHooks/ButtonStack";

local m_ProxyIM  = InstanceManager:new("CivRowInstance", "Button", Controls.ProxyStack);
local m_TargetIM = InstanceManager:new("CivRowInstance", "Button", Controls.TargetStack);
local m_HookIM   = nil;
local m_WarIM    = InstanceManager:new("WarEntryInstance", "Root", Controls.HistoryStack);
local m_Tab      = "proxy";   -- "proxy" | "history"

local m_Proxy    = -1;
local m_Target   = -1;
local m_Eval     = nil;
local m_Pending  = nil;   -- { proxy, target, price } awaiting DiplomacyDeclareWar

local function Log(msg) print("ProxyWar[ui]: " .. msg) end

local function CivName(id)
	local cfg = PlayerConfigurations[id];
	return Locale.Lookup("LOC_PROXYWAR_CIV_NAME",
		Locale.Lookup(cfg:GetLeaderName()), Locale.Lookup(cfg:GetCivilizationShortDescription()));
end

local function StateName(stateType)
	local row = stateType and GameInfo.DiplomaticStates[stateType];
	return row and Locale.Lookup(row.Name) or tostring(stateType);
end

-- ---------------------------------------------------------------------------
local function RefreshVerdict()
	local me = Game.GetLocalPlayer();
	Controls.DetailLabel:SetText("");
	Controls.PayButton:SetDisabled(true);
	m_Eval = nil;

	if m_Proxy < 0 or m_Target < 0 then
		Controls.VerdictLabel:LocalizeAndSetText("LOC_PROXYWAR_PICK_BOTH");
		return;
	end

	local world = ProxyWar.GameWorld();
	local eval  = ProxyWar.Evaluate(world, me, m_Proxy, m_Target);
	m_Eval = eval;

	if not eval.ok then
		Controls.VerdictLabel:SetText(Locale.Lookup("LOC_PROXYWAR_REFUSES", CivName(m_Proxy))
			.. "[NEWLINE]" .. Locale.Lookup("LOC_PROXYWAR_REASON_" .. eval.reason));
		return;
	end

	local f = eval.factors;
	Controls.VerdictLabel:SetText(Locale.Lookup("LOC_PROXYWAR_ASKS", CivName(m_Proxy), eval.price, CivName(m_Target)));
	Controls.DetailLabel:SetText(Locale.Lookup("LOC_PROXYWAR_DETAIL",
		StateName(f.toTarget), StateName(f.toSponsor),
		string.format("%.2f", f.ratio), f.grievances, f.otherWars));

	if ProxyWar.CanAfford(world, me, eval.price) then
		Controls.PayButton:SetDisabled(false);
		Controls.PayButton:SetText(Locale.Lookup("LOC_PROXYWAR_PAY_AMOUNT", eval.price));
	else
		Controls.PayButton:SetText(Locale.Lookup("LOC_PROXYWAR_PAY"));
		Controls.DetailLabel:SetText(Controls.DetailLabel:GetText() .. "[NEWLINE][COLOR_Red]"
			.. Locale.Lookup("LOC_PROXYWAR_REASON_NOT_ENOUGH_GOLD") .. "[ENDCOLOR]");
	end
end

-- ---------------------------------------------------------------------------
local function PopulateLists()
	local me = Game.GetLocalPlayer();
	local pMe = Players[me];
	m_ProxyIM:ResetInstances();
	m_TargetIM:ResetInstances();

	for _, id in ipairs(PlayerManager.GetAliveMajorIDs()) do
		if id ~= me and pMe:GetDiplomacy():HasMet(id) then
			-- Proxy list: AI only.
			if not Players[id]:IsHuman() then
				local inst = m_ProxyIM:GetInstance();
				inst.Name:SetText(CivName(id));
				inst.Button:SetSelected(id == m_Proxy);
				inst.Button:RegisterCallback(Mouse.eLClick, function()
					m_Proxy = id; UI.PlaySound("Play_UI_Click"); PopulateLists();
				end);
			end
			local inst = m_TargetIM:GetInstance();
			inst.Name:SetText(CivName(id));
			inst.Button:SetSelected(id == m_Target);
			inst.Button:RegisterCallback(Mouse.eLClick, function()
				m_Target = id; UI.PlaySound("Play_UI_Click"); PopulateLists();
			end);
		end
	end

	Controls.ProxyStack:CalculateSize();  Controls.ProxyScroll:CalculateSize();
	Controls.TargetStack:CalculateSize(); Controls.TargetScroll:CalculateSize();
	RefreshVerdict();
end

-- ---------------------------------------------------------------------------
-- War History tab
-- ---------------------------------------------------------------------------
local function CivShort(id)
	return Locale.Lookup(PlayerConfigurations[id]:GetCivilizationShortDescription());
end

local function Ordinal(n)
	if n >= 1 and n <= 10 then return Locale.Lookup("LOC_WARHIST_ORDINAL_" .. n) end
	return Locale.Lookup("LOC_WARHIST_ORDINAL_N", n);
end

local function CanSee(me, w)
	if w.a == me or w.b == me then return true end
	local d = Players[me]:GetDiplomacy();
	return d:HasMet(w.a) and d:HasMet(w.b);
end

local function SponsorVisible(me, w)
	return w.sp >= 0 and (me == w.sp or (me == w.b and w.rv == 1));
end

local function PopulateHistory()
	local me = Game.GetLocalPlayer();
	if me < 0 then return end
	local now = Game.GetCurrentGameTurn();
	local mineOnly = Controls.MineOnlyCheck:IsChecked();
	local state = WarHistory.Deserialize(Game:GetProperty(WarHistory.PROPERTY_KEY));
	local list = WarHistory.Sorted(state, function(w)
		if not CanSee(me, w) then return false end
		if mineOnly then return w.a == me or w.b == me or (w.sp == me) end
		return true;
	end);

	m_WarIM:ResetInstances();
	local ongoing = 0;
	for _, w in ipairs(list) do
		local inst = m_WarIM:GetInstance();
		local A, B = CivShort(w.a), CivShort(w.b);

		inst.WarName:SetText(Locale.Lookup("LOC_WARHIST_NAME", Ordinal(w.n), A, B));

		local dates;
		if w.en == WarHistory.END_ONGOING then
			ongoing = ongoing + 1;
			if w.st < 0 then dates = Locale.Lookup("LOC_WARHIST_DATES_ONGOING_UNKNOWN");
			else dates = Locale.Lookup("LOC_WARHIST_DATES_ONGOING", w.st, now - w.st) end
		else
			if w.st < 0 then dates = Locale.Lookup("LOC_WARHIST_DATES_ENDED_UNKNOWN", w.et);
			else dates = Locale.Lookup("LOC_WARHIST_DATES_ENDED", w.st, w.et, w.et - w.st) end
		end
		if w.ag == 1 then dates = dates .. "  " .. Locale.Lookup("LOC_WARHIST_DECLARED_BY", A) end
		inst.WarDates:SetText(dates);

		inst.WarStats:SetText(Locale.Lookup("LOC_WARHIST_STATS", A, w.ca, B, w.cb, w.ka, w.kb));

		if SponsorVisible(me, w) then
			local key = (me == w.sp) and "LOC_WARHIST_PROXY_YOU" or "LOC_WARHIST_PROXY_REVEALED";
			inst.WarProxy:SetText(Locale.Lookup(key, CivShort(w.sp)));
			inst.WarProxy:SetHide(false);
		else
			inst.WarProxy:SetHide(true);
		end

		local code, winner = WarHistory.GetOutcome(w);
		local result;
		if code == WarHistory.Outcome.CONQUEST then
			result = Locale.Lookup("LOC_WARHIST_OUTCOME_CONQUEST", CivShort(w.el), CivShort(winner));
		elseif winner ~= nil then
			result = Locale.Lookup("LOC_WARHIST_OUTCOME_" .. code, CivShort(winner));
		else
			result = Locale.Lookup("LOC_WARHIST_OUTCOME_" .. code);
		end
		inst.WarResult:SetText(result);

		inst.Lines:CalculateSize();
		inst.Root:DoAutoSize();
	end

	Controls.HistorySummary:SetText(Locale.Lookup("LOC_WARHIST_SUMMARY", #list, ongoing));
	Controls.HistoryEmpty:SetHide(#list > 0);
	Controls.HistoryStack:CalculateSize();
	Controls.HistoryScroll:CalculateSize();
end

local function ShowTab(tab)
	m_Tab = tab;
	local isProxy = (tab == "proxy");
	Controls.ProxyTab:SetHide(not isProxy);
	Controls.HistoryTab:SetHide(isProxy);
	Controls.TabProxyButton:SetSelected(isProxy);
	Controls.TabHistoryButton:SetSelected(not isProxy);
	if isProxy then PopulateLists() else PopulateHistory() end
	Controls.WindowStack:CalculateSize();
	Controls.Window:DoAutoSize();
	Controls.WindowContainer:DoAutoSize();
end

-- ---------------------------------------------------------------------------
local function Open()
	if Game.GetLocalPlayer() < 0 then return end
	ShowTab(m_Tab);
	UIManager:QueuePopup(ContextPtr, PopupPriority.Current);
end

local function Close()
	UIManager:DequeuePopup(ContextPtr);
end

local function Toggle()
	if ContextPtr:IsHidden() then Open() else Close() end
end

local function OnPay()
	if m_Eval == nil or not m_Eval.ok then return end
	local kParameters = {
		OnStart = ProxyWar.EVENT_NAME,
		Proxy   = m_Proxy,
		Target  = m_Target,
		Offer   = m_Eval.price,
	};
	m_Pending = { proxy = m_Proxy, target = m_Target, price = m_Eval.price };
	Log(string.format("requesting proxy=%d target=%d offer=%d", m_Proxy, m_Target, m_Eval.price));
	UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT, kParameters);
	Controls.PayButton:SetDisabled(true);
	Controls.VerdictLabel:LocalizeAndSetText("LOC_PROXYWAR_SENT");
end

-- Confirmation comes back as an ordinary war declaration event.
local function OnDiplomacyDeclareWar(actingPlayer, reactingPlayer)
	if m_Pending and actingPlayer == m_Pending.proxy and reactingPlayer == m_Pending.target then
		local msg = Locale.Lookup("LOC_PROXYWAR_SUCCESS", CivName(actingPlayer), CivName(reactingPlayer), m_Pending.price);
		Log(msg);
		m_Pending = nil;
		if not ContextPtr:IsHidden() then
			PopulateLists();
			Controls.VerdictLabel:SetText(msg);
		end
	elseif not ContextPtr:IsHidden() then
		if m_Tab == "history" then PopulateHistory() else RefreshVerdict() end
	end
end

local function OnMakePeace()
	if not ContextPtr:IsHidden() and m_Tab == "history" then PopulateHistory() end
end

-- ---------------------------------------------------------------------------
local function AddHookButton()
	if m_HookIM ~= nil then return end
	local bar = ContextPtr:LookUpControl(HOOK_BAR_PATH);
	if bar == nil then
		Log("hook bar not found at " .. HOOK_BAR_PATH .. "; panel is still reachable via LuaEvents.ProxyWar_Toggle()");
		return;
	end
	m_HookIM = InstanceManager:new("HookInstance", "HookStack", bar);
	local inst = m_HookIM:GetInstance();
	local x, y, sheet = IconManager:FindIconAtlas("ICON_DIPLOACTION_THIRD_PARTY_WAR", 38);
	if sheet ~= nil then
		inst.HookIcon:SetTexture(x, y, sheet);
	else
		inst.HookIcon:SetTexture("LaunchBar_Hook_CityStates");
	end
	inst.HookButton:RegisterCallback(Mouse.eLClick, Toggle);
	inst.HookButton:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over") end);
	bar:CalculateSize();
	Log("hook button added");
end

local function OnInput(pInputStruct)
	if pInputStruct:GetMessageType() == KeyEvents.KeyUp and pInputStruct:GetKey() == Keys.VK_ESCAPE then
		Close(); return true;
	end
	return false;
end

local function OnLocalPlayerTurnEnd()
	if not ContextPtr:IsHidden() then Close() end
end

local function Initialize()
	ContextPtr:SetHide(true);
	ContextPtr:SetInputHandler(OnInput, true);
	Controls.PayButton:RegisterCallback(Mouse.eLClick, OnPay);
	Controls.CloseButton:RegisterCallback(Mouse.eLClick, Close);
	Controls.TabProxyButton:RegisterCallback(Mouse.eLClick, function() ShowTab("proxy") end);
	Controls.TabHistoryButton:RegisterCallback(Mouse.eLClick, function() ShowTab("history") end);
	Controls.MineOnlyCheck:RegisterCheckHandler(function() PopulateHistory() end);
	Events.DiplomacyMakePeace.Add(OnMakePeace);

	Events.LoadScreenClose.Add(AddHookButton);
	Events.DiplomacyDeclareWar.Add(OnDiplomacyDeclareWar);
	Events.LocalPlayerTurnEnd.Add(OnLocalPlayerTurnEnd);
	LuaEvents.ProxyWar_Toggle.Add(Toggle);
	Log("loaded");
end
Initialize();
