# Notes: how far can Civ VI's AI be modded?

These are background notes from development, not features of this mod.

## What is closed
The core AI (tactical moves, diplomacy decisions, the behaviour-tree engine) is C++ inside the game DLL. There is no SDK source, so the algorithms themselves cannot be replaced.

## What is open
- **Data:** `BehaviorTrees`, `TreeData`, `AiOperationDefs`, `AiFavoredItems`, `PseudoYields`, `Strategies`, and `AiListTypes` can all be changed with SQL/XML. That tunes *what* the AI values, not *how* it thinks.
- **Lua:** gameplay scripts can make decisions themselves and act through the gameplay API (`DeclareWarOn`, treasury, units, and so on). This mod's AI sponsors do exactly that: an expected-value model in `ProxyWar_Logic.lua` runs at each AI's turn start.

## Idea (not built): an external "brain"
A program on the host machine could make the decisions and push them into the game. Possible channels:
- **FireTuner:** the debug protocol that lets you run Lua in a live game.
- **Logs out:** the mod writes state to `Lua.log`; an external tool reads it.

Limits:
- It would be single-player / debug only.
- It is outside normal mod distribution.
- It would desync multiplayer.
