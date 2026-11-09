#!/usr/bin/env bash
# Copyright (C) 2026 Dvip Patel
# SPDX-License-Identifier: GPL-3.0-or-later
# Static checks for the mod. Run from repo root: tests/validate.sh
set -u
MOD=mods/ProxyWar
fail=0
err() { echo "FAIL: $*"; fail=1; }

# 1. XML well-formed
for f in "$MOD"/ProxyWar.modinfo "$MOD"/UI/*.xml "$MOD"/Text/en_US/*.xml; do
  xmllint --noout "$f" || err "malformed $f"
done

# 2. Every file in modinfo exists (case-sensitive, matters on Linux/Proton)
grep -oP '(?<=<File>)[^<]+' "$MOD/ProxyWar.modinfo" | sort -u | while read -r p; do
  [ -f "$MOD/$p" ] || { echo "FAIL: modinfo references missing $p"; exit 1; }
done || fail=1

# 3. Lua compiles
for f in "$MOD"/Scripts/*.lua "$MOD"/UI/*.lua; do
  luajit -bl "$f" >/dev/null || err "lua syntax $f"
done

# 4. Every LOC_PROXYWAR_* used in Lua/XML is defined in the text file
used=$(grep -rhoE 'LOC_(PROXYWAR|WARHIST)_[A-Z0-9_]+' "$MOD"/UI "$MOD"/Scripts | sed 's/_$//' | sort -u)
defined=$(grep -oE 'Tag="LOC_(PROXYWAR|WARHIST)_[A-Z0-9_]+"' "$MOD"/Text/en_US/*.xml | grep -oE 'LOC_[A-Z0-9_]+' | sort -u)
for k in $used; do
  case "$k" in LOC_PROXYWAR_REASON|LOC_WARHIST_ORDINAL|LOC_WARHIST_OUTCOME) continue;; esac  # dynamic prefixes, covered by run_tests.lua
  echo "$defined" | grep -qx "$k" || err "undefined text key $k"
done

# 5. Text file loads into a LocalizedText-shaped table without duplicate tags
dups=$(echo "$defined" | uniq -d; grep -oE 'Tag="[^"]+"' "$MOD"/Text/en_US/*.xml | sort | uniq -d)
[ -z "$dups" ] || err "duplicate text tags: $dups"

# 6. Control IDs referenced as Controls.X exist in the panel XML
for id in $(grep -oE 'Controls\.[A-Za-z]+' "$MOD/UI/ProxyWarPanel.lua" | cut -d. -f2 | sort -u); do
  grep -q "ID=\"$id\"" "$MOD/UI/ProxyWarPanel.xml" || err "Controls.$id not in XML"
done
# Instance members (inst.X) exist in the XML
for id in $(grep -oE 'inst\.[A-Za-z]+' "$MOD/UI/ProxyWarPanel.lua" | cut -d. -f2 | sort -u); do
  grep -q "ID=\"$id\"" "$MOD/UI/ProxyWarPanel.xml" || err "inst.$id not in XML"
done

# 7. Logic unit tests
luajit tests/run_tests.lua || fail=1
luajit tests/run_history_tests.lua || fail=1

[ $fail -eq 0 ] && echo "ALL CHECKS PASSED" || { echo "SOME CHECKS FAILED"; exit 1; }
