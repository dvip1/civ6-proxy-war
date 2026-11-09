# Installing

## Requirements
- Civilization VI with **Gathering Storm** or **Rise and Fall** (the base game should work too; the grievance discount needs GS).
- Works in single player and multiplayer (the human action goes through `EXECUTE_SCRIPT`, and the AI uses only synced RNG).

## Install
Copy (or symlink) `mods/ProxyWar` into the game's Mods folder:

| Platform | Mods folder |
|---|---|
| Windows | `Documents\My Games\Sid Meier's Civilization VI\Mods\` |
| Linux, Steam + Proton | `~/.local/share/Steam/steamapps/compatdata/289070/pfx/drive_c/users/steamuser/Documents/My Games/Sid Meier's Civilization VI/Mods/` |
| Linux native / macOS | `~/.local/share/aspyr-media/Sid Meier's Civilization VI/Mods/` or `~/Library/Application Support/Sid Meier's Civilization VI/Mods/` |

Symlinking from a git checkout is handy while developing:
```
ln -s "$PWD/mods/ProxyWar" "<Mods folder>/ProxyWar"
```
Then enable **Proxy War & War History** under *Additional Content*.

`AffectsSavedGames` is 0, so you can turn the mod on for an existing save.

## Troubleshooting: "the mod is enabled but doesn't load"
A **saved game setup** (`*.Civ6Cfg`, e.g. a saved Earth TSL configuration) stores its own list of enabled mods.
That list overrides what you have ticked under *Additional Content*.
- Load the setup, check the mod is ticked, then **save the setup again** (or delete the old `.Civ6Cfg`).
- To confirm: `Logs/Modding.log` lists the enabled mods for each game start. Proxy War should be in that list.

Log folder (Proton): `.../pfx/drive_c/users/steamuser/AppData/Local/Firaxis Games/Sid Meier's Civilization VI/Logs/`.
