# Windrose KillExpMod

UE4SS Lua mod for Windrose that grants player EXP after killing enemies, wildlife, undead, pirates, bosses, and hostile ships.

The mod is built to be editable without Lua knowledge. EXP values and target rules live in a separate JSON config file.

## Status

Current build:

```text
2026-04-19-config-json
```

What works:

- Grants EXP after a valid kill.
- Uses Windrose's own EXP reward path, so the normal in-game EXP notification can appear.
- Reads mob and ship EXP values from `Config/exp_rules.json`.
- Supports friendly/player-owned exclusions by setting EXP to `0`.
- Prevents duplicate EXP from the same killed actor.
- Works without `UEHelpers`, which helps with the regular player UE4SS package.

Expected behavior:

- After killing a configured target, the game should show an EXP notification.
- If a target is configured with `exp: 0`, no EXP is granted.
- If a target is not configured, the mod may log a limited `Brak reguly EXP` message.
- Changes to `exp_rules.json` require a full game restart.

## Install

Install the mod into the active UE4SS folder used by the game:

```text
Windrose/R5/Binaries/Win64/ue4ss/Mods/KillExpMod/
```

Expected file layout:

```text
KillExpMod/
  README.md
  Config/
    exp_rules.json
  Scripts/
    main.lua
    kill_exp_config.lua
```

Do not install the mod into a backup UE4SS folder such as `BAK_ue4ss`. The active folder must be named `ue4ss`.

## Editing EXP Values

Open this file with Notepad:

```text
KillExpMod/Config/exp_rules.json
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

Example disabled rule:

```json
{ "group": "Wildlife", "pattern": "BP_Mob_Wolf_C", "exp": 45, "note": "Wolf", "enabled": false }
```

Rule order matters. Put more specific patterns above general fallback patterns.

Good:

```json
{ "group": "Ships", "pattern": "BP_AIShip_Frigate_BlackbeardLeader_C", "exp": 700, "note": "Blackbeard leader frigate" },
{ "group": "Ships", "pattern": "BP_AIShip_Frigate_", "exp": 450, "note": "AI frigate fallback" }
```

Bad:

```json
{ "group": "Ships", "pattern": "BP_AIShip_Frigate_", "exp": 450, "note": "AI frigate fallback" },
{ "group": "Ships", "pattern": "BP_AIShip_Frigate_BlackbeardLeader_C", "exp": 700, "note": "Blackbeard leader frigate" }
```

The bad order would make the generic frigate rule match first.

## Settings

The top of `exp_rules.json` contains:

```json
"settings": {
  "hide_exp_notification": false,
  "dedupe_ttl_seconds": 30,
  "prewarm_delay_ms": 2000,
  "no_match_log_limit": 5
}
```

Settings:

- `hide_exp_notification`: set to `true` only if you want to suppress the extra EXP notification path.
- `dedupe_ttl_seconds`: how long a killed actor stays in the duplicate protection cache.
- `prewarm_delay_ms`: delay after load before the mod prewarms the EXP reward path.
- `no_match_log_limit`: max number of missing-rule logs per session.

For normal use, leave these values unchanged.

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

Log says the config was not loaded:

- Check that `Config/exp_rules.json` exists.
- Check that the JSON is valid.
- Restore the original file if needed.

EXP works for some enemies but not others:

- The missing target probably has no matching `pattern`.
- Add a new rule with the Blueprint/class fragment from the log.

Wrong EXP amount:

- A more general rule may be matching before a specific one.
- Move the specific rule above the fallback rule.

EXP appears twice:

- Increase `dedupe_ttl_seconds`.
- Report the target name and logs, because the game may be firing separate kill callbacks for related actors.

Small stutter on first EXP after loading:

- The mod prewarms the reward path after load, but the game can still stream or initialize assets.
- Later kills should be smoother than the first one.

## Notes For Modders

The main logic is in:

```text
Scripts/main.lua
```

The config loader is in:

```text
Scripts/kill_exp_config.lua
```

Most users should only edit:

```text
Config/exp_rules.json
```

The JSON loader accepts normal JSON and also tolerates `//` and `/* */` comments, but release files should stay clean JSON for compatibility with editors and validators.

## Safety

This is an unofficial mod. Back up your saves before testing new EXP tables. Use it in local or private modded sessions only.
