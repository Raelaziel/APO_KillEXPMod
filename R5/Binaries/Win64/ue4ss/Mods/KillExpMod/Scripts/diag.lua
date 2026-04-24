-- diag.lua
-- Logging, localisation, and diagnostic statistics.
-- Initialise with: local Diag = dofile("...diag.lua")
-- Then call Diag.init(cfg) once config is loaded to apply settings.

local M = {}

-- Minimal fallback table used before the external localisation file is loaded.
M.LOG_TEXT = {
    en = { unknown = "unknown" },
    pl = { unknown = "nieznany" },
}

local MOD_NAME = "KillExpMod"
local LOG_LANGUAGE = "en"
local DIAGNOSTIC_LOGGING = false
local VERBOSE_COMBAT_DIAGNOSTICS = false
local DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS = 0

M.stats = {
    KillEvents = 0,
    NonKillEvents = 0,
    GrantAttempts = 0,
    Granted = 0,
    Duplicates = 0,
    CapBlocked = 0,
    Errors = 0,
}

local nextDiagnosticSummaryAt = 0

-- Apply settings loaded from config.
function M.init(cfg)
    MOD_NAME = cfg.MOD_NAME or MOD_NAME
    LOG_LANGUAGE = cfg.LOG_LANGUAGE or LOG_LANGUAGE
    DIAGNOSTIC_LOGGING = cfg.DIAGNOSTIC_LOGGING or DIAGNOSTIC_LOGGING
    VERBOSE_COMBAT_DIAGNOSTICS = cfg.VERBOSE_COMBAT_DIAGNOSTICS or VERBOSE_COMBAT_DIAGNOSTICS
    DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS = cfg.DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS or DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS
    if cfg.LOG_TEXT ~= nil then
        M.LOG_TEXT = cfg.LOG_TEXT
    end
end

function M.log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

function M.loc(key, ...)
    local langTable = M.LOG_TEXT[LOG_LANGUAGE] or M.LOG_TEXT.pl
    local fallbackTable = M.LOG_TEXT.pl
    local template = langTable[key] or fallbackTable[key] or tostring(key)

    if select("#", ...) > 0 then
        return string.format(template, ...)
    end

    return template
end

local function resolveMessage(message)
    if type(message) == "function" then
        local ok, built = pcall(message)
        if ok then
            return built
        end
        return "diag builder error: " .. tostring(built)
    end

    return message
end

function M.diagnosticLog(message)
    if not DIAGNOSTIC_LOGGING then
        return
    end

    M.log("[diag] " .. tostring(resolveMessage(message)))
end

function M.diagnosticCombatLog(message)
    if not DIAGNOSTIC_LOGGING or not VERBOSE_COMBAT_DIAGNOSTICS then
        return
    end

    M.log("[diag] " .. tostring(resolveMessage(message)))
end

function M.bumpStat(key)
    local value = M.stats[key]
    if value ~= nil then
        M.stats[key] = value + 1
    end
end

function M.maybeLogSummary(nowSeconds)
    if not DIAGNOSTIC_LOGGING or DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS <= 0 then
        return
    end

    if nextDiagnosticSummaryAt == 0 then
        nextDiagnosticSummaryAt = nowSeconds + DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS
        return
    end

    if nowSeconds < nextDiagnosticSummaryAt then
        return
    end

    nextDiagnosticSummaryAt = nowSeconds + DIAGNOSTIC_SUMMARY_INTERVAL_SECONDS

    local s = M.stats
    M.diagnosticLog(function()
        return M.loc(
            "diag_summary",
            s.KillEvents,
            s.NonKillEvents,
            s.GrantAttempts,
            s.Granted,
            s.Duplicates,
            s.CapBlocked,
            s.Errors
        )
    end)
end

return M
