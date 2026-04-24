-- main.lua
-- Entry point for KillExpMod.
-- Loads modules, applies config, registers UE4SS hooks.

-- ── Module loading ────────────────────────────────────────────────────────────

local MODULE_PATHS = {
    "Mods/KillExpMod/Scripts/",
    "ue4ss/Mods/KillExpMod/Scripts/",
}

local function loadModule(name)
    for _, base in ipairs(MODULE_PATHS) do
        local ok, result = pcall(dofile, base .. name)
        if ok and result ~= nil then
            return result
        end
    end
    error("KillExpMod: could not load module " .. name)
end

local UU                                     = loadModule("ue_util.lua")
local Diag                                   = loadModule("diag.lua")
local makeCache                              = loadModule("player_cache.lua")
local makeGrant                              = loadModule("exp_grant.lua")

-- ── Path lists ────────────────────────────────────────────────────────────────

local CONFIG_LOADER_PATHS                    = {
    "Mods/KillExpMod/Scripts/kill_exp_config.lua",
    "ue4ss/Mods/KillExpMod/Scripts/kill_exp_config.lua",
}

local CONFIG_PATHS                           = {
    "Mods/KillExpMod/Config/exp_rules.json",
    "ue4ss/Mods/KillExpMod/Config/exp_rules.json",
}

local LOCALIZATION_PATHS                     = {
    "Mods/KillExpMod/Config/log_localization.lua",
    "ue4ss/Mods/KillExpMod/Config/log_localization.lua",
}

-- ── Settings defaults ─────────────────────────────────────────────────────────

local MOD_NAME                               = "KillExpMod"
local MOD_BUILD                              = "2026-04-24-modular"
local LOG_LANGUAGE                           = "en"

local HIDE_EXP_NOTIFICATION                  = false
local DIAGNOSTIC_LOGGING                     = false
local VERBOSE_COMBAT_DIAGNOSTICS             = false
local DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS    = 0
local ENABLE_HOOK_DAMAGE_UI                  = true
local ENABLE_HOOK_CLIENT_DAMAGE_DEALT        = true
local ENABLE_HOOK_NET_MULTICAST_DAMAGE_DEALT = true
local ENABLE_HOOK_DEATH_COMPONENT            = true
local DEDUPE_TTL_SECONDS                     = 30
local PREWARM_DELAY_MS                       = 2000
local NO_MATCH_LOG_LIMIT                     = 5
local CAP_LOG_LIMIT                          = 5
local LEVEL_CAP                              = 100
local TALENT_POINTS_CAP                      = 300
local CAP_CACHE_WINDOW_MS                    = 5000
local CAP_CACHE_WINDOW_FAR_MS                = 30000
local CAP_NEAR_LEVEL_MARGIN                  = 5
local CAP_NEAR_TALENT_MARGIN                 = 15
local SCENARIO_CONTEXT_RETRY_SECONDS         = 5

-- ── Config helpers ────────────────────────────────────────────────────────────

local function loadScriptFromPaths(paths)
    local lastError = nil
    for _, path in ipairs(paths) do
        local ok, moduleOrError = pcall(dofile, path)
        if ok and moduleOrError ~= nil then
            return moduleOrError, path
        end
        lastError = moduleOrError
    end
    return nil, tostring(lastError)
end

local function settingBool(settings, key, fallback)
    local value = settings[key]
    if value == nil then return fallback end
    if value == true or value == false then return value end
    local text = string.lower(tostring(value))
    return text == "true" or text == "1" or text == "yes"
end

local function settingInt(settings, key, fallback)
    local value = tonumber(tostring(settings[key]))
    if value == nil then return fallback end
    return math.floor(value)
end

local function settingString(settings, key, fallback)
    local value = settings[key]
    if value == nil then return fallback end
    return tostring(value)
end

-- ── Bootstrap ────────────────────────────────────────────────────────────────

-- Optional UEHelpers.
local okUEHelpers, UEHelpers = pcall(require, "UEHelpers")
if not okUEHelpers then UEHelpers = nil end

-- Localization (minimal fallback is already in Diag).
local locTable, locPathOrErr = loadScriptFromPaths(LOCALIZATION_PATHS)
if type(locTable) == "table" then
    Diag.LOG_TEXT = locTable
else
    print(string.format("[%s] Localization not loaded, using fallback: %s\n",
        MOD_NAME, tostring(locPathOrErr)))
end

-- Config.
local loader, loaderPath = loadScriptFromPaths(CONFIG_LOADER_PATHS)
if loader == nil or type(loader.load) ~= "function" then
    print(string.format("[%s] Config loader not found at: %s\n", MOD_NAME, tostring(loaderPath)))
else
    local config, configErr = loader.load(CONFIG_PATHS)
    if config == nil then
        print(string.format("[%s] Config load failed: %s\n", MOD_NAME, tostring(configErr)))
    else
        local s                                = config.Settings or {}

        local lang                             = string.lower(settingString(s, "log_language", LOG_LANGUAGE))
        LOG_LANGUAGE                           = (Diag.LOG_TEXT[lang] ~= nil) and lang or "en"

        HIDE_EXP_NOTIFICATION                  = settingBool(s, "hide_exp_notification", HIDE_EXP_NOTIFICATION)
        DIAGNOSTIC_LOGGING                     = settingBool(s, "diagnostic_logging", DIAGNOSTIC_LOGGING)
        VERBOSE_COMBAT_DIAGNOSTICS             = settingBool(s, "verbose_combat_diagnostics", VERBOSE_COMBAT_DIAGNOSTICS)
        DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS    = settingInt(s, "diagnostic_summary_interval_seconds",
            DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS)
        ENABLE_HOOK_DAMAGE_UI                  = settingBool(s, "enable_hook_damage_ui", ENABLE_HOOK_DAMAGE_UI)
        ENABLE_HOOK_CLIENT_DAMAGE_DEALT        = settingBool(s, "enable_hook_client_damage_dealt",
            ENABLE_HOOK_CLIENT_DAMAGE_DEALT)
        ENABLE_HOOK_NET_MULTICAST_DAMAGE_DEALT = settingBool(s, "enable_hook_net_multicast_damage_dealt",
            ENABLE_HOOK_NET_MULTICAST_DAMAGE_DEALT)
        ENABLE_HOOK_DEATH_COMPONENT            = settingBool(s, "enable_hook_death_component",
            ENABLE_HOOK_DEATH_COMPONENT)
        DEDUPE_TTL_SECONDS                     = settingInt(s, "dedupe_ttl_seconds", DEDUPE_TTL_SECONDS)
        PREWARM_DELAY_MS                       = settingInt(s, "prewarm_delay_ms", PREWARM_DELAY_MS)
        NO_MATCH_LOG_LIMIT                     = settingInt(s, "no_match_log_limit", NO_MATCH_LOG_LIMIT)
        CAP_LOG_LIMIT                          = settingInt(s, "cap_log_limit", CAP_LOG_LIMIT)
        LEVEL_CAP                              = settingInt(s, "level_cap", LEVEL_CAP)
        TALENT_POINTS_CAP                      = settingInt(s, "talent_points_cap", TALENT_POINTS_CAP)
        CAP_CACHE_WINDOW_MS                    = settingInt(s, "cap_cache_window_ms", CAP_CACHE_WINDOW_MS)
        CAP_CACHE_WINDOW_FAR_MS                = settingInt(s, "cap_cache_window_far_ms", CAP_CACHE_WINDOW_FAR_MS)
        CAP_NEAR_LEVEL_MARGIN                  = settingInt(s, "cap_near_level_margin", CAP_NEAR_LEVEL_MARGIN)
        CAP_NEAR_TALENT_MARGIN                 = settingInt(s, "cap_near_talent_margin", CAP_NEAR_TALENT_MARGIN)

        -- Push settings into Diag now so loc() works for the remaining startup messages.
        Diag.init({
            MOD_NAME                            = MOD_NAME,
            LOG_LANGUAGE                        = LOG_LANGUAGE,
            DIAGNOSTIC_LOGGING                  = DIAGNOSTIC_LOGGING,
            VERBOSE_COMBAT_DIAGNOSTICS          = VERBOSE_COMBAT_DIAGNOSTICS,
            DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS = DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS,
            LOG_TEXT                            = Diag.LOG_TEXT,
        })

        local loc = Diag.loc
        local dlog = Diag.diagnosticLog

        Diag.log(loc("rules_loaded", #(config.Rules or {}), tostring(config.Path)))
        dlog(loc("diag_enabled"))
        dlog(loc("combat_diag_state",
            VERBOSE_COMBAT_DIAGNOSTICS and loc("state_enabled") or loc("state_disabled")))
        dlog(loc("summary_diag_state",
            DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS,
            DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS > 0 and loc("state_enabled") or loc("state_disabled")))

        for _, warning in ipairs(config.Warnings or {}) do
            Diag.log(loc("config_warning", tostring(warning)))
        end

        -- Initialise submodules.
        local Cache = makeCache(UU, Diag)
        Cache.init({
            UEHelpers                      = UEHelpers,
            SCENARIO_CONTEXT_RETRY_SECONDS = SCENARIO_CONTEXT_RETRY_SECONDS,
            LEVEL_CAP                      = LEVEL_CAP,
            TALENT_POINTS_CAP              = TALENT_POINTS_CAP,
            CAP_CACHE_WINDOW_MS            = CAP_CACHE_WINDOW_MS,
            CAP_CACHE_WINDOW_FAR_MS        = CAP_CACHE_WINDOW_FAR_MS,
            CAP_NEAR_LEVEL_MARGIN          = CAP_NEAR_LEVEL_MARGIN,
            CAP_NEAR_TALENT_MARGIN         = CAP_NEAR_TALENT_MARGIN,
            CAP_LOG_LIMIT                  = CAP_LOG_LIMIT,
        })

        local Grant = makeGrant(UU, Diag, Cache)
        Grant.init({
            HIDE_EXP_NOTIFICATION = HIDE_EXP_NOTIFICATION,
            DEDUPE_TTL_SECONDS    = DEDUPE_TTL_SECONDS,
            NO_MATCH_LOG_LIMIT    = NO_MATCH_LOG_LIMIT,
            RULES                 = config.Rules or {},
        })

        -- ── Prewarm ───────────────────────────────────────────────────────────

        if type(ExecuteWithDelay) == "function" then
            pcall(function()
                ExecuteWithDelay(PREWARM_DELAY_MS, function()
                    Grant.addExpTaskClass()
                    Cache.primaryWorldContext()
                    Cache.currentProgressionObserver()
                    Cache.currentEntityProgressionVM()
                    Cache.currentTalentTreeVM()
                    Cache.currentScenarioExecutor()
                    Cache.currentScenarioGraph()
                    Cache.currentCapState()
                end)
            end)
        end

        -- ── Hook registration ─────────────────────────────────────────────────

        local function registerHookSafe(path, callback)
            local ok, err = pcall(RegisterHook, path, callback)
            if ok then
                Diag.log(loc("hook_active", path))
            else
                Diag.log(loc("hook_unavailable", path, tostring(err)))
            end
        end

        local function registerHookOptional(path, enabled, callback)
            if enabled then
                registerHookSafe(path, callback)
            else
                dlog(loc("hook_disabled", path))
            end
        end

        -- Handles both raw target+kill-flag and damage-instance forms.
        -- Pass damageInstanceParam=nil when calling with a direct target+kill pair.
        local function handleDamage(targetParam, killParam, sourceName, damageInstanceParam)
            local now = os.time()

            if damageInstanceParam ~= nil then
                local damageInstance = UU.unwrap(damageInstanceParam)
                targetParam          = UU.safeRead(damageInstance, "Target")
                killParam            = UU.safeRead(damageInstance, "bIsKillDamage")

                Diag.diagnosticCombatLog(function()
                    return loc("damage_instance", tostring(sourceName),
                        UU.objectDebugName(targetParam),
                        tostring(UU.unwrap(killParam)))
                end)
            end

            if not UU.isTrue(killParam) then
                Diag.bumpStat("NonKillEvents")
                Diag.diagnosticCombatLog(loc("non_kill_ignored", tostring(sourceName)))
                Diag.maybeLogSummary(now)
                return
            end

            Diag.bumpStat("KillEvents")
            dlog(function()
                return loc("kill_received", tostring(sourceName), UU.objectDebugName(targetParam))
            end)

            Grant.awardExpForTarget(UU.unwrap(targetParam), sourceName)
            Diag.maybeLogSummary(now)
        end

        local function handleDeathComponent(context)
            local component = UU.unwrap(context)
            if not UU.isValid(component) then
                return
            end

            dlog(function()
                return loc("death_component_update",
                    UU.objectDebugName(Grant.ownerFromComponent(component)))
            end)
            Cache.resetPlayerRuntimeCache("OnRep_DeathEventData")

            local deathEventData = UU.safeRead(component, "DeathEventData")
            if not UU.isTrue(UU.safeRead(deathEventData, "bDead")) then
                dlog(loc("death_component_ignored"))
                return
            end

            Grant.awardExpForTarget(Grant.ownerFromComponent(component), "DeathComponent")
        end

        registerHookOptional(
            "/Script/R5.R5DamageUIComponent:OnASCDamageDealt",
            ENABLE_HOOK_DAMAGE_UI,
            function(context, targetActor, incomingDamage, dealtDamage, armorReduction, isKillDamage, effectSpec)
                handleDamage(targetActor, isKillDamage, "DamageUI", nil)
            end)

        registerHookOptional(
            "/Script/R5.R5DamageUIComponent:ClientDamageDealt",
            ENABLE_HOOK_CLIENT_DAMAGE_DEALT,
            function(context, damageInstance)
                handleDamage(nil, nil, "ClientDamageDealt", damageInstance)
            end)

        registerHookOptional(
            "/Script/R5.R5DamageUIComponent:NetMulticastDamageDealt",
            ENABLE_HOOK_NET_MULTICAST_DAMAGE_DEALT,
            function(context, damageInstance)
                handleDamage(nil, nil, "NetMulticastDamageDealt", damageInstance)
            end)

        registerHookOptional(
            "/Script/R5.R5DeathComponent:OnRep_DeathEventData",
            ENABLE_HOOK_DEATH_COMPONENT,
            function(context)
                handleDeathComponent(context)
            end)

        Diag.log(loc("build_loaded", MOD_BUILD))
        dlog(loc("diag_ready"))
    end
end
