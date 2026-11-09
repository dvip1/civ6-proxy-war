# Testing

## Offline (no game needed)
Requires `luajit` and `xmllint`.
```
tests/validate.sh
```
This runs:
- XML well-formedness checks;
- a check that every modinfo file exists (case-sensitive);
- Lua syntax checks;
- checks that every `LOC_` key is defined, with no duplicates;
- checks that every `Controls.X` / `inst.X` ID exists in the XML;
- both unit-test suites (`tests/run_tests.lua` for pricing and the AI, `tests/run_history_tests.lua` for war history).

The game logic lives in pure modules (`ProxyWar_Logic.lua`, `WarHistory_Logic.lua`). They talk to the game through a small "world" adapter, so the tests run them against fakes.

## In game
1. Enable the mod and start a game, or load a save. If you start from a saved game setup, see [INSTALL.md](INSTALL.md#troubleshooting-the-mod-is-enabled-but-doesnt-load).
2. **Proxy war (human):** open the War Room button in the top-right hook bar. Pick an attacker and a target, check the price, and click Pay. The attacker should declare war and the gold should move.
3. **Proxy war (AI):** AIs consider deals from turn 40 (normalised). For a quick test, lower `AI_MIN_TURN` and raise `AI_TRY_CHANCE_PCT` in `ProxyWar.Config`.
4. **War History:** switch to the second tab. Current wars should be listed. Play a few turns: captures and kills should update the stats, and peace or elimination should produce a result.
5. Then run:
   ```
   tests/check_ingame_log.sh
   ```
   Expect `ProxyWar[gameplay]: loaded`, `ProxyWar[ui]: hook button added`, and `history: N wars on record`.
   There should be no `cannot hook` lines and no Lua errors mentioning ProxyWar.

Enable Lua logging if `Lua.log` is empty: set `EnableTuner 1` / `LoggingEnabled 1` in `AppOptions.txt`.
