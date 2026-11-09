#!/usr/bin/env bash
# Copyright (C) 2026 Dvip Patel
# SPDX-License-Identifier: GPL-3.0-or-later
# After running Civ VI with the mod enabled, summarise what the logs say.
L="$HOME/.local/share/Steam/steamapps/compatdata/289070/pfx/drive_c/users/steamuser/AppData/Local/Firaxis Games/Sid Meier's Civilization VI/Logs"

echo "== Modding.log: ProxyWar components applied"
grep -E "Applying Component - ProxyWar" "$L/Modding.log" | tail -5 || true

echo "== Lua.log: ProxyWar lines"
grep -E "ProxyWar" "$L/Lua.log" | tail -30 || true

echo "== Lua.log: errors near ProxyWar"
grep -nE -A3 "ProxyWar.*(Runtime Error|failed|attempt to)|(Runtime Error|Syntax Error).*ProxyWar" "$L/Lua.log" | tail -30 || true

echo "== Database.log errors (all mods)"
grep -E "ERROR" "$L/Database.log" | tail -10 || true

echo
echo "Expected on a working load:"
echo "  ProxyWar[gameplay]: loaded"
echo "  ProxyWar[ui]: loaded"
echo "  ProxyWar[gameplay]: history: N wars on record"
echo "  ProxyWar[ui]: hook button added"
echo "and NO lines like: history: cannot hook ..."
echo "AI activity (any time after turn 40):"
echo "  ProxyWar[gameplay]: AI N (Civ) buying proxy war: A -> B for P"
echo "and after paying:"
echo "  ProxyWar[ui]: requesting ..."
echo "  ProxyWar[gameplay]: SUCCESS sponsor S paid P gold: proxy X now at war with Y ..."
