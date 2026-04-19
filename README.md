# Windrose APO KillEXPMod

UE4SS Lua mod for Windrose that grants player EXP after killing enemies, wildlife, undead, pirates, bosses, and hostile ships.

The mod is built to be editable without Lua knowledge. EXP values and target rules live in a separate JSON config file.

## Installation

- Unpack the content to `\steamapps\common\Windrose\`
- Mod (.lua) should be located in `\steamapps\common\Windrose\`
- UE4SS-RE after unpack should be in root folder at `Win64` like `\steamapps\common\Windrose\`
- .pak Mod file called `pakchunk99-KillExpMod_HeroLevels_P.pak` needs to be in `\steamapps\common\Windrose\R5\Content\Paks`
The mod is built to be editable without Lua knowledge. EXP values, target rules, and basic caps live in `Config/exp_rules.json`.

## Status

Current build:

```text
2026-04-19-caps-config
```

What works:

- Grants EXP after a valid kill.
- Uses Windrose's own EXP reward path, so the normal in-game EXP notification can appear.
- Reads mob and ship EXP values from `Config/exp_rules.json`.
- Ships with 69 target rules split into wildlife, undead, pirates, corrupted enemies, bosses, and ships.
- Supports friendly/player-owned exclusions by setting EXP to `0`.
- Supports configurable level and talent point caps for kill EXP.
- Prevents duplicate EXP from the same killed actor.
- Works without `UEHelpers`, which helps with the regular player UE4SS package.

Expected behavior:

- After killing a configured target, the game should show an EXP notification.
- If a target is configured with `exp: 0`, no EXP is granted.
- If the level table patch is installed, the hero level table contains 100 levels.
- If the player is at `level_cap` or above, kill EXP is skipped.
- If the loaded talent progression VM reports at least `talent_points_cap`, kill EXP is skipped.
- If a target is not configured, the mod may log a limited `Brak reguly EXP` message.
- Changes to `exp_rules.json` require a full game restart.

## Install

This repository is laid out like the Windrose game folder. Copy or extract the release contents into the Windrose install directory, so the files land under `Windrose/...`.

Expected installed layout:

```text
Windrose/
  R5/
    Binaries/
      Win64/
        dwmapi.dll
        ue4ss/
          UE4SS.dll
          UE4SS-settings.ini
          Mods/
            mods.json
            mods.txt
            KillExpMod/
              README.md
              Config/
                exp_rules.json
              Scripts/
                main.lua
                kill_exp_config.lua
    Content/
      Paks/
        pakchunk99-KillExpMod_HeroLevels_P.pak
```

Do not install the mod into a backup UE4SS folder such as `BAK_ue4ss`. The active folder must be named `ue4ss`.

The Lua mod can grant kill EXP without the pak patch, but the game only has 15 hero level entries by default. The pak patch extends `DA_HeroLevels.json` to 100 entries and should be installed for the level 100 / 300 talent point setup.

## Release Files

The current repository structure contains these runtime paths:

```text
R5/Binaries/Win64/dwmapi.dll
R5/Binaries/Win64/ue4ss/
R5/Content/Paks/pakchunk99-KillExpMod_HeroLevels_P.pak
```

The UE4SS files handle runtime kill EXP. The pak file handles the level 100 table. Release archives should preserve this `R5/...` layout.

## Editing EXP Values

Open this file with Notepad:

```text
R5/Binaries/Win64/ue4ss/Mods/KillExpMod/Config/exp_rules.json
```

Each rule looks like this:

```json
{ "group": "Custom enemies", "pattern": "BP_Mob_NewEnemy_C", "exp": 75, "note": "New enemy" }
```

Fields:

- `group` is only for readability.
- `pattern` is a fragment of the target Blueprint/class name.
- `exp` is the amount of EXP granted.
- `note` is only for readability.
- `enabled: false` can be added to disable a rule without deleting it.

Rule order matters. Put more specific patterns above general fallback patterns.

Current default config:

- 69 rules.
- EXP range is `0` to `700`.
- `0` EXP entries are used for friendly/player-owned actors that should not reward EXP.
- Rule groups include wildlife, undead, human enemies, Senkamati corrupted, bosses, and ships.

## Settings

The top of `exp_rules.json` contains:

```json
"settings": {
  "hide_exp_notification": false,
  "dedupe_ttl_seconds": 30,
  "prewarm_delay_ms": 2000,
  "no_match_log_limit": 5,
  "cap_log_limit": 5,
  "level_cap": 100,
  "talent_points_cap": 300
}
```

Settings:

- `hide_exp_notification`: set to `true` only if you want to suppress the extra EXP notification path.
- `dedupe_ttl_seconds`: how long a killed actor stays in the duplicate protection cache.
- `prewarm_delay_ms`: delay after load before the mod prewarms the EXP reward path.
- `no_match_log_limit`: max number of missing-rule logs per session.
- `cap_log_limit`: max number of cap-related logs per session.
- `level_cap`: kill EXP is skipped once the player is at this level or above.
- `talent_points_cap`: kill EXP is skipped if the loaded talent UI/progression VM reports this many available talent points or more.

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

- Singleplayer: install both the UE4SS mod files and the pak patch locally.
- Co-op/listen server: use the same files and config on host and clients for consistent behavior.
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
- No UE4SS exist at all
- Verify this exact path exists:

```text
Windrose/R5/Binaries/Win64/ue4ss/Mods/KillExpMod/Scripts/main.lua
```

Log says the config was not loaded:

- Check that `Config/exp_rules.json` exists.
- Check that the JSON is valid.
- Restore the original file if needed.

EXP works for some enemies but not others:

- The missing target probably has no matching `pattern`.
- Add a new rule with the Blueprint/class fragment from the log.
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

This is an unofficial mod. Back up your saves before testing new EXP tables.
