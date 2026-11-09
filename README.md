# Civ VI: Proxy War & War History

Pay an AI civ (A) to declare war on another civ (B). You are not a party to the war.

The mod is in `mods/ProxyWar/`. It is symlinked into the game's Mods folder:
`<Proton prefix>/Documents/My Games/Sid Meier's Civilization VI/Mods/ProxyWar`.

## Install
Copy or symlink `mods/ProxyWar` into your Civ VI `Mods` folder, then enable it under *Additional Content*.
See [docs/INSTALL.md](docs/INSTALL.md) for folder paths and the "enabled but not loading" fix.

## Docs
- [docs/INSTALL.md](docs/INSTALL.md): install paths and troubleshooting
- [docs/TESTING.md](docs/TESTING.md): offline tests and an in-game checklist
- [docs/AI_NOTES.md](docs/AI_NOTES.md): what Civ VI's AI does and doesn't let you mod

## How it works
- **UI** (`UI/ProxyWarPanel.*`): a button in the top-right hook bar (next to City-States / Trade) opens the panel. You pick the attacker and the target, see the price, and pay.
- **Network**: `UI.RequestPlayerOperation(..., EXECUTE_SCRIPT, {OnStart="ProxyWar_Instigate"})`, so it works in multiplayer.
- **Gameplay** (`Scripts/ProxyWar_Gameplay.lua`): re-runs the evaluation (the gameplay side has the final say), calls `DeclareWarOn` (a formal war if A is allowed one, otherwise a surprise war), then moves the gold. If the war doesn't happen, no gold moves.
- **Logic** (`Scripts/ProxyWar_Logic.lua`): one pure pricing function, shared by both sides and unit-tested.

## Pricing
`price = (100 + 4·turn) × target-relation × sponsor-relation × strength × busy × grievance`
(the turn is normalised to Standard speed; the multipliers are in `ProxyWar.Config`).

| Factor | Effect |
|---|---|
| A's state toward B | Denounced ×0.35, Unfriendly ×0.6, Neutral ×1, Friendly ×1.75, Declared Friend ×3, Allied = refuses |
| A's state toward you | Allied ×0.7 … Unfriendly ×1.4, Denounced = refuses |
| Grievances A holds vs B (GS) | −0.4% per point, capped at −50% |
| Strength A/B | ×1/ratio, clamped to 0.6–2.5; refuses if A is under half B's strength |
| Other wars A is fighting | +50% each; refuses above 2 |

## AI sponsors
AIs buy proxy wars too (`AI_ENABLED` in `ProxyWar.Config`). At each AI major's turn start:
- skip before turn 40 (normalised), and for 20 turns after the AI last bought one;
- 25% chance it considers a deal at all (synced `Game.GetRandNum`), which spreads purchases out;
- candidate targets: civs it is at war with (hostility 3), has denounced (2) or is unfriendly to (1). That includes you;
- each (attacker, target) pair is scored by **expected value**:

```
damage = strengthShare x proximity x pileOn x leader
  strengthShare = attacker / (attacker + target) military strength
  proximity     = 1 if capitals <= 10 tiles apart, fading to 0.1 at 40+
  pileOn        = 1 + 0.25 per other war the target is in (max 2)
  leader        = 1, unless AI_TARGET_LEADER (off by default): favours score leaders
value  = hostility x damage x basePrice        (gold the war is worth to the AI)
profit = value - price
```
- it buys the highest-profit deal if profit > 0, spending at most 50% of its gold and keeping 100 in reserve;
- humans are never used as attackers. A human target gets a notification, and there is a 50% chance it names the sponsor;
- every purchase is logged with its full breakdown (`value=… profit=… dist=… pileOn=…`) in Lua.log.

## War History tab
The second tab of the War Room panel lists every war between major civs you have met, e.g. *"First England–Norway War"*:
- start and end turn, duration, and who declared it;
- cities captured and units destroyed by each side;
- result: **Decisive victory / Victory for X**, **Stalemate**, or **X was destroyed by Y**.
  Score = 3 per city captured + 1 per unit destroyed; margin `(a-b)/(a+b)` ≥ 0.5 is decisive, ≥ 0.15 a victory,
  less (or fewer than 2 points in total) a stalemate (`WarHistory.Config`);
- proxy wars show who paid only to the sponsor, or to the target if the sponsor was revealed.

How it's recorded (`Scripts/WarHistory_Logic.lua`, driven by `ProxyWar_Gameplay.lua`):
- events: war declared, `GameEvents.CityConquered`, `GameEvents.OnCombatOccurred` (dead-unit check);
- an end-of-turn reconcile catches peace, eliminations, and anything the events missed;
- stored in the save as a `Game` property (`WARHIST_DATA_V1`), so history survives save/load;
- wars already running when the mod is first enabled are listed as "began before records".
  Earlier, finished wars can't be recovered.

## Testing
```
tests/validate.sh          # XML, modinfo files, Lua syntax, text keys, control IDs + both unit-test suites
tests/check_ingame_log.sh  # after playing: summarises Lua.log / Modding.log
```

## experiments/
`deniable-join-war/` is the earlier, data-only attempt. It zeroed the warmonger values on the vanilla
`DIPLOACTION_THIRD_PARTY_WAR`. That agreement is really "Join Ongoing War": the engine only offers
targets you are already at war with, so it could never keep you out of the war.

## License
Copyright (C) 2026 Dvip Patel

This program is free software: you can redistribute it and/or modify it under the terms of the
GNU General Public License as published by the Free Software Foundation, either version 3 of the
License, or (at your option) any later version. See [LICENSE](LICENSE).
