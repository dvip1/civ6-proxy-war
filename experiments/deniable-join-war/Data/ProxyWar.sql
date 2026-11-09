-- Deniable Proxy War -- experiment 1, data only.
--
-- Vanilla row (DLC/Expansion1/Data/Expansion1_DiplomaticActions.xml:27):
--   WarmongerPercent="100" CaptureWarmongerPercent="100" RazeWarmongerPercent="300"
--
-- So the sponsor of a third-party war eats the same diplomatic blame as if they
-- had declared it personally, and 3x if the proxy razes a city. Zero it out and
-- the agreement becomes what the name suggests: someone else's war.
--
-- HYPOTHESIS UNDER TEST: that these three columns are what Gathering Storm's
-- Grievance system reads. The columns predate GS (they drove the old warmonger
-- score), and the C++ appears to reuse them, but that is inference -- if the
-- target's grievances against you still climb after this loads, the assumption
-- is wrong and deniability has to be done in Lua instead.

UPDATE DiplomaticActions
SET WarmongerPercent        = 0,   -- blame at the moment war is declared
    CaptureWarmongerPercent = 0,   -- blame per city your proxy captures
    RazeWarmongerPercent    = 0    -- blame per city your proxy burns (was 300)
WHERE DiplomaticActionType = 'DIPLOACTION_THIRD_PARTY_WAR';

-- Deliberately NOT changed in this version, to keep one variable:
--   InitiatorPrereqCivic (CIVIC_FOREIGN_TRADE) -- already early enough
--   Duration (30)                              -- proxy's obligation length
--   DiplomaticActionStates Worth/Cost (all 0)  -- unknown AI-valuation semantics
--   SHARE_WAR_GRIEVANCES_ALLY / _DECLARED_FRIENDS -- global, would affect AI vs AI
