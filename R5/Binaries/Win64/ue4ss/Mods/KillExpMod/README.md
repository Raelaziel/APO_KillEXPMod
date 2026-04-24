# Windrose APO KillEXPMod

UE4SS Lua mod for Windrose that grants player EXP after killing enemies, wildlife, undead, pirates, bosses, and hostile ships.

The mod is built to be editable without Lua knowledge. EXP values, target rules, and basic caps live in `Config/exp_rules.json`.

## Status

Current build:

```text
2026-04-24-i18n-diag
```

What works:

- Grants EXP after a valid kill.
- Uses Windrose's own EXP reward path, so the normal in-game EXP notification can appear.
- Reads mob and ship EXP values from `Config/exp_rules.json`.
- Ships with 69 default target rules split into wildlife, undead, pirates, corrupted enemies, bosses, and ships.
- Supports friendly/player-owned exclusions by setting EXP to `0`.
- Supports configurable level and talent point caps for kill EXP.
- Prevents duplicate EXP from the same killed actor.
- Works without `UEHelpers`, which helps with the regular player UE4SS package.
- Correctly grants EXP after player death and respawn (stale UE object cache is now invalidated on pawn change).
- Optional diagnostic logging and periodic summary counters for troubleshooting.
- Log language configurable to `en` or `pl`.

## Changelog

### 2026-04-24-i18n-diag

- **Respawn fix**: EXP was silently skipped after the player died and respawned. Root cause was stale cached UE objects (`PlayerCharacter`, `PlayerState`, `ScenarioComponent`) surviving the respawn. The mod now detects pawn and state changes mid-session and resets its internal caches, so EXP resumes correctly on the first kill after respawn.
- **Diagnostic logging system**: New optional logging controlled by `diagnostic_logging` in settings. When enabled, the mod prints detailed lines for every grant attempt, duplicate skip, cap block, and error. Defaults to `false`.
- **Verbose combat diagnostics**: New `verbose_combat_diagnostics` flag. When enabled alongside `diagnostic_logging`, every damage event received by the hooks is logged, not only kill events. Defaults to `false`.
- **Periodic diagnostic summary**: New `diagnostic_summary_interval_seconds` setting. When set to a positive integer, the mod prints a running counter summary (kills seen, grants attempted, grants successful, duplicates, cap blocks, errors) at that interval. Set to `0` to disable. Defaults to `0`.
- **Hook toggles**: Four new settings let individual UE4SS hooks be disabled without editing Lua: `enable_hook_damage_ui`, `enable_hook_client_damage_dealt`, `enable_hook_net_multicast_damage_dealt`, `enable_hook_death_component`. All default to `true`.
- **Localization**: Log messages now support Polish (`pl`) and English (`en`). Set `log_language` in settings. Defaults to `en`. Translation strings live in `Config/log_localization.lua` and can be edited independently of the main script.
- **Bug fix**: Internal Lua function ordering caused a `nil` call crash in `objectDebugName()` under certain early-load conditions. Fixed by forward-declaring the affected local before use.

Expected behavior:

- After killing a configured target, the game should show an EXP notification.
- If a target is configured with `exp: 0`, no EXP is granted.
- If the level table patch is installed, the hero level table contains 100 levels.
- If the player is at `level_cap` or above, kill EXP is skipped.
- If the loaded talent progression VM reports at least `talent_points_cap`, kill EXP is skipped.
- If a target is not configured, the mod may log a limited `Brak reguly EXP` message.
- Changes to `exp_rules.json` require a full game restart.

## Install

This release is meant to be installed under the Windrose game folder. The active runtime paths should be:

```text
Windrose/R5/Binaries/Win64/dwmapi.dll
Windrose/R5/Binaries/Win64/ue4ss/UE4SS.dll
Windrose/R5/Binaries/Win64/ue4ss/Mods/KillExpMod/
Windrose/R5/Content/Paks/pakchunk99-KillExpMod_HeroLevels_P.pak
```

Expected mod folder layout:

```text
KillExpMod/
  README.md
  Config/
    exp_rules.json
    log_localization.lua
  Scripts/
    main.lua
    kill_exp_config.lua
```

Do not install the mod into a backup UE4SS folder such as `BAK_ue4ss`. The active folder must be named `ue4ss`.

The Lua mod can grant kill EXP without the pak patch, but the game only has 15 hero level entries by default. The pak patch extends `DA_HeroLevels.json` to 100 entries and should be installed for the level 100 / 300 talent point setup.

## Release Files

A complete release should include these paths:

```text
R5/Binaries/Win64/dwmapi.dll
R5/Binaries/Win64/ue4ss/
R5/Content/Paks/pakchunk99-KillExpMod_HeroLevels_P.pak
```

The UE4SS folder is responsible for kill EXP rules and runtime hooks. The pak file is responsible for the level 100 table.

## Editing EXP Values

Open this file with Notepad:

```text
R5/Binaries/Win64/ue4ss/Mods/KillExpMod/Config/exp_rules.json
```

Each rule looks like this:

```json
{ "group": "Small wildlife", "pattern": "BP_Mob_Dodo_C", "exp": 25, "note": "Dodo" }
```

Fields:

- `group` is only for readability.
- `pattern` is a fragment of the target Blueprint/class name.
- `exp` is the amount of EXP granted.
- `note` is only for readability.
- `enabled: false` can be added to disable a rule without deleting it.

Rule order matters. Put more specific patterns above general fallback patterns.

Current default table:

- 69 rules.
- EXP range is `0` to `700`.
- `0` EXP entries are used for friendly/player-owned actors that should not reward EXP.
- Rule groups include wildlife, undead, human enemies, Senkamati corrupted, bosses, and ships.

## Settings

The top of `exp_rules.json` contains:

```json
"settings": {
  "log_language": "en",
  "hide_exp_notification": false,
  "diagnostic_logging": false,
  "verbose_combat_diagnostics": false,
  "diagnostic_summary_interval_seconds": 0,
  "enable_hook_damage_ui": true,
  "enable_hook_client_damage_dealt": true,
  "enable_hook_net_multicast_damage_dealt": true,
  "enable_hook_death_component": true,
  "dedupe_ttl_seconds": 30,
  "prewarm_delay_ms": 2000,
  "no_match_log_limit": 5,
  "cap_log_limit": 5,
  "level_cap": 100,
  "talent_points_cap": 300,
  "cap_cache_window_ms": 5000,
  "cap_cache_window_far_ms": 30000,
  "cap_near_level_margin": 5,
  "cap_near_talent_margin": 15
}
```

Settings:

- `log_language`: language for mod log messages. Accepted values: `"en"` (English) or `"pl"` (Polish).
- `hide_exp_notification`: set to `true` only if you want to suppress the extra EXP notification path.
- `diagnostic_logging`: set to `true` to enable verbose diagnostic output in the UE4SS log. Useful for troubleshooting missing EXP.
- `verbose_combat_diagnostics`: set to `true` to also log every damage event, not just kill events. Requires `diagnostic_logging: true`.
- `diagnostic_summary_interval_seconds`: print a running counter summary (kills, grants, duplicates, cap blocks, errors) every N seconds. Set to `0` to disable.
- `enable_hook_damage_ui`: set to `false` to disable the damage UI hook without editing Lua.
- `enable_hook_client_damage_dealt`: set to `false` to disable the client-side damage-dealt hook.
- `enable_hook_net_multicast_damage_dealt`: set to `false` to disable the net multicast damage-dealt hook.
- `enable_hook_death_component`: set to `false` to disable the death component hook.
- `dedupe_ttl_seconds`: how long a killed actor stays in the duplicate protection cache.
- `prewarm_delay_ms`: delay after load before the mod prewarms the EXP reward path.
- `no_match_log_limit`: max number of missing-rule logs per session.
- `cap_log_limit`: max number of cap-related logs per session.
- `level_cap`: kill EXP is skipped once the player is at this level or above.
- `talent_points_cap`: kill EXP is skipped if the loaded talent UI/progression VM reports this many available talent points or more.
- `cap_cache_window_ms`: how long level/talent cap data stays cached when the player is near a cap.
- `cap_cache_window_far_ms`: how long level/talent cap data stays cached when the player is comfortably below the caps.
- `cap_near_level_margin`: how many levels below `level_cap` counts as near-cap behavior.
- `cap_near_talent_margin`: how many talent points below `talent_points_cap` counts as near-cap behavior.

For normal use, leave these values unchanged.

## Level Table Patch

The optional pak patch overrides:

```text
R5/Plugins/R5BusinessRules/Content/EntityProgression/DA_HeroLevels.json
```

Patch contents:

- 100 hero level entries.
- First 15 levels are copied from the base game.
- Total `TalentPointsReward` from level 1 to 100 is exactly `300`.
- Levels 16-100 grant `2` stat points each.
- The level 100 EXP threshold is `1558103`.

Without this pak, `level_cap: 100` only acts as a Lua safety limit. It does not create missing game levels.

## Multiplayer Note

This mod is not guaranteed to be pure server-side. It relies on UE4SS runtime hooks such as damage UI callbacks and replicated death data, so behavior can differ between host, client, and dedicated server setups.

Recommended setup:

- Singleplayer: install both the UE4SS mod folder and the pak patch locally.
- Co-op/listen server: install the same files on the host and clients for consistent behavior.
- If duplicated EXP appears in multiplayer, test host-only installation and disable the UE4SS mod on clients.

## Adding New Enemies

If a killed enemy does not grant EXP:

1. Check the UE4SS/game log for a line containing `Brak reguly EXP`.
2. Copy the useful Blueprint/class fragment from that line.
3. Add a new rule to `Config/exp_rules.json`.
4. Restart the game.
5. Kill that enemy again and check the EXP notification.

Example:

```json
{ "group": "Custom enemies", "pattern": "BP_Mob_NewEnemy_C", "exp": 75, "note": "New enemy" }
```

Keep the JSON valid:

- Use double quotes.
- Separate rules with commas.
- Do not forget the closing `]` and `}`.

## Troubleshooting

No logs and no EXP:

- The mod is probably in the wrong UE4SS folder.
- Verify this exact path exists:

```text
Windrose/R5/Binaries/Win64/ue4ss/Mods/KillExpMod/Scripts/main.lua
```

- Verify `Windrose/R5/Binaries/Win64/ue4ss/Mods/mods.txt` contains `KillExpMod : 1`.
- Verify `Windrose/R5/Binaries/Win64/ue4ss/Mods/mods.json` has `"mod_enabled": true` for `KillExpMod`.

Wrong EXP amount:

- A more general rule may be matching before a specific one.
- Move the specific rule above the fallback rule.

EXP stops at high level:

- Check `level_cap` and `talent_points_cap` in `Config/exp_rules.json`.
- Check that `pakchunk99-KillExpMod_HeroLevels_P.pak` is installed in `R5/Content/Paks`.

Small stutter on first EXP after loading:

- The mod prewarms the reward path after load, but the game can still stream or initialize assets.
- Later kills should be smoother than the first one.

## Notes For Modders

Most users should only edit:

```text
R5/Binaries/Win64/ue4ss/Mods/KillExpMod/Config/exp_rules.json
```

Main logic:

```text
R5/Binaries/Win64/ue4ss/Mods/KillExpMod/Scripts/main.lua
```

Config loader:

```text
R5/Binaries/Win64/ue4ss/Mods/KillExpMod/Scripts/kill_exp_config.lua
```

Log localization strings:

```text
R5/Binaries/Win64/ue4ss/Mods/KillExpMod/Config/log_localization.lua
```

This is an unofficial mod. Back up your saves before testing new EXP tables.
