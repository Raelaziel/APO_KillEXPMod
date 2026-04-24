-- exp_grant.lua
-- EXP rule matching, duplicate protection, and scenario task execution.
-- Returns a factory: local Grant = dofile("...exp_grant.lua")(UU, Diag, Cache, cfg)

local function makeGrant(UU, Diag, Cache)
    local isValid                 = UU.isValid
    local safeRead                = UU.safeRead
    local safeCall                = UU.safeCall
    local safeStaticFind          = UU.safeStaticFind
    local objectAddress           = UU.objectAddress
    local objectText              = UU.objectText
    local objectDebugName         = UU.objectDebugName
    local rawObjectAddress        = UU.rawObjectAddress
    local unwrap                  = UU.unwrap
    local safeRawCall             = UU.safeRawCall

    local log                     = Diag.log
    local loc                     = Diag.loc
    local dlog                    = Diag.diagnosticLog
    local dclog                   = Diag.diagnosticCombatLog
    local bump                    = Diag.bumpStat
    local maybeLogSummary         = Diag.maybeLogSummary

    -- Runtime config.
    local HIDE_EXP_NOTIFICATION   = false
    local DEDUPE_TTL_SECONDS      = 30
    local NO_MATCH_LOG_LIMIT      = 5

    local MATCH_RULES             = {}
    local MATCH_RESULTS_BY_CLASS  = {}
    local MATCH_RESULT_NONE       = {}

    local awardedKills            = {}
    local nextAwardCacheCleanupAt = 0
    local noMatchLogs             = 0

    local cachedAddExpTaskClass   = nil

    local M                       = {}

    function M.init(cfg)
        if cfg.HIDE_EXP_NOTIFICATION ~= nil then
            HIDE_EXP_NOTIFICATION = cfg.HIDE_EXP_NOTIFICATION
        end
        if cfg.DEDUPE_TTL_SECONDS ~= nil then
            DEDUPE_TTL_SECONDS = cfg.DEDUPE_TTL_SECONDS
        end
        if cfg.NO_MATCH_LOG_LIMIT ~= nil then
            NO_MATCH_LOG_LIMIT = cfg.NO_MATCH_LOG_LIMIT
        end
        noMatchLogs            = 0

        MATCH_RULES            = {}
        MATCH_RESULTS_BY_CLASS = {}

        for _, rule in ipairs(cfg.RULES or {}) do
            if rule.Pattern ~= nil and rule.Pattern ~= "" then
                MATCH_RULES[#MATCH_RULES + 1] = {
                    Exp = rule.Exp,
                    Pattern = rule.Pattern,
                    PatternLower = string.lower(rule.Pattern),
                }
            end
        end
    end

    local function targetMatchText(targetActor)
        local raw = unwrap(targetActor)
        if raw == nil or not isValid(raw) then
            return nil, nil
        end

        local okClass, classObject = safeRawCall(raw, "GetClass")
        local classKey = nil
        local className, classFullName = "", ""

        if okClass and isValid(classObject) then
            classKey = rawObjectAddress(classObject)

            local ok, val = safeRawCall(classObject, "GetName")
            if ok and val ~= nil then
                className = tostring(val)
            end

            ok, val = safeRawCall(classObject, "GetFullName")
            if ok and val ~= nil then
                classFullName = tostring(val)
            end
        end

        if classKey == nil or classKey == "" then
            classKey = classFullName ~= "" and classFullName or className
        end

        if className == "" and classFullName == "" then
            local actorName, actorFullName = "", ""
            local ok, val = safeRawCall(raw, "GetName")
            if ok and val ~= nil then actorName = tostring(val) end
            ok, val = safeRawCall(raw, "GetFullName")
            if ok and val ~= nil then actorFullName = tostring(val) end

            if actorName == "" and actorFullName == "" then
                return classKey, nil
            end

            return classKey, string.lower(actorName .. " " .. actorFullName)
        end

        return classKey, string.lower(className .. " " .. classFullName)
    end

    function M.expForTarget(targetActor)
        if not isValid(targetActor) then
            return nil, nil
        end

        local classKey, text = targetMatchText(targetActor)
        if classKey ~= nil and classKey ~= "" then
            local cached = MATCH_RESULTS_BY_CLASS[classKey]
            if cached == MATCH_RESULT_NONE then return nil, nil end
            if cached ~= nil then return cached.Exp, cached.Pattern end
        end

        if text == nil or text == "" then
            return nil, nil
        end

        for _, rule in ipairs(MATCH_RULES) do
            if string.find(text, rule.PatternLower, 1, true) ~= nil then
                if classKey ~= nil and classKey ~= "" then
                    MATCH_RESULTS_BY_CLASS[classKey] = rule
                end
                return rule.Exp, rule.Pattern
            end
        end

        if classKey ~= nil and classKey ~= "" then
            MATCH_RESULTS_BY_CLASS[classKey] = MATCH_RESULT_NONE
        end

        return nil, nil
    end

    local function addExpTaskClass()
        if isValid(cachedAddExpTaskClass) then
            return cachedAddExpTaskClass
        end

        for _, path in ipairs({
            "/Script/R5.R5ScenarioTask_AddExp",
            "/Script/R5Scenario.R5ScenarioTask_AddExp",
        }) do
            local taskClass = safeStaticFind(path)
            if isValid(taskClass) then
                cachedAddExpTaskClass = taskClass
                return taskClass
            end
        end

        return nil
    end

    -- Expose for prewarm.
    M.addExpTaskClass = addExpTaskClass

    local function setTaskField(task, field, value)
        if not isValid(task) or not isValid(value) then
            return false
        end
        return pcall(function()
            task[field] = value
        end)
    end

    local function prepareScenarioTask(task)
        local scenarioGraph    = Cache.currentScenarioGraph()
        local scenarioExecutor = Cache.currentScenarioExecutor()

        if not isValid(safeRead(task, "BaseGraph")) and isValid(scenarioGraph) then
            setTaskField(task, "BaseGraph", scenarioGraph)
            setTaskField(task, "Graph", scenarioGraph)
            setTaskField(task, "OwningGraph", scenarioGraph)
        end

        if not isValid(safeRead(task, "Executor")) and isValid(scenarioExecutor) then
            setTaskField(task, "Executor", scenarioExecutor)
            setTaskField(task, "NodeExecutor", scenarioExecutor)
            setTaskField(task, "ScenarioExecutor", scenarioExecutor)
            setTaskField(task, "CurrentExecutor", scenarioExecutor)
        end

        return isValid(safeRead(task, "BaseGraph")) or isValid(safeRead(task, "Graph")),
            isValid(safeRead(task, "Executor")) or isValid(safeRead(task, "NodeExecutor"))
    end

    local function grantExpThroughScenarioTask(amount, reason)
        bump("GrantAttempts")

        local worldContext = Cache.primaryWorldContext()
        dlog(function()
            return loc("grant_request", tostring(amount), tostring(reason),
                objectDebugName(worldContext))
        end)

        if not isValid(worldContext) then
            Cache.resetPlayerRuntimeCache(loc("reason_missing_world_context"))
            worldContext = Cache.primaryWorldContext()
            dlog(function()
                return loc("world_context_retry", objectDebugName(worldContext))
            end)
        end

        if not isValid(worldContext) then
            bump("Errors")
            log(loc("missing_world_context"))
            return false
        end

        local taskClass = addExpTaskClass()
        if not isValid(taskClass) then
            bump("Errors")
            log(loc("missing_task_class"))
            return false
        end

        dlog(function()
            return loc("using_task_class", objectDebugName(taskClass))
        end)

        local liveTaskClass    = unwrap(taskClass)
        local liveWorldContext = unwrap(worldContext)
        if liveTaskClass == nil or liveWorldContext == nil then
            bump("Errors")
            log(loc("missing_live_context"))
            return false
        end

        local okConstruct, task = pcall(function()
            return StaticConstructObject(liveTaskClass, liveWorldContext)
        end)

        if not okConstruct or not isValid(task) then
            bump("Errors")
            log(loc("task_construct_failed"))
            return false
        end

        local okExp, expErr = pcall(function()
            task.exp = amount
        end)
        if not okExp then
            log(loc("exp_field_failed", tostring(expErr)))
            return false
        end

        pcall(function()
            task.bHideNotification = HIDE_EXP_NOTIFICATION
        end)

        local character = Cache.currentPlayerCharacter()
        if isValid(character) then
            pcall(function()
                task.Target = character
            end)
        end

        dlog(function()
            return loc("prepared_task",
                objectDebugName(character),
                objectDebugName(Cache.currentScenarioGraph()),
                objectDebugName(Cache.currentScenarioExecutor()))
        end)

        prepareScenarioTask(task)

        safeCall(task, "OnNodeCreated")

        local okInit, initErr = safeCall(task, "OnInit")
        if not okInit then
            Cache.resetPlayerRuntimeCache(loc("reason_oninit_failed"))
            bump("Errors")
            log(loc("oninit_failed", tostring(initErr)))
            return false
        end

        local okExec, execErr = safeCall(task, "OnExec")
        if not okExec then
            Cache.resetPlayerRuntimeCache(loc("reason_onexec_failed"))
            bump("Errors")
            log(loc("onexec_failed", tostring(execErr)))
            return false
        end

        bump("Granted")
        log(loc("exp_awarded", amount, tostring(reason or loc("unknown"))))
        return true
    end

    local function isAwardKeyActive(key, now)
        if key == nil or key == "" then
            return false
        end

        local awardedAt = awardedKills[key]
        if awardedAt == nil then
            return false
        end

        if now - awardedAt > DEDUPE_TTL_SECONDS then
            awardedKills[key] = nil
            return false
        end

        return true
    end

    local function cleanAwardCache(now)
        if now < nextAwardCacheCleanupAt then
            return
        end

        nextAwardCacheCleanupAt = now + DEDUPE_TTL_SECONDS
        for key, timestamp in pairs(awardedKills) do
            if now - timestamp > DEDUPE_TTL_SECONDS then
                awardedKills[key] = nil
            end
        end
    end

    function M.awardExpForTarget(targetActor, sourceName)
        if not isValid(targetActor) then
            dlog(loc("skip_invalid_target", tostring(sourceName)))
            return false
        end

        local now = os.time()
        local key = objectAddress(targetActor)

        if isAwardKeyActive(key, now) then
            bump("Duplicates")
            dlog(function()
                return loc("skip_duplicate", tostring(sourceName), objectDebugName(targetActor))
            end)
            return false
        end

        local amount, matchedPattern = M.expForTarget(targetActor)
        if amount == nil or amount <= 0 then
            local shouldLogNoMatch = NO_MATCH_LOG_LIMIT <= 0 or noMatchLogs < NO_MATCH_LOG_LIMIT
            if amount == nil and shouldLogNoMatch then
                if NO_MATCH_LOG_LIMIT > 0 then
                    noMatchLogs = noMatchLogs + 1
                end
                log(loc("no_rule", tostring(sourceName), objectText(targetActor)))
            end

            dlog(function()
                return loc("no_exp_awarded", tostring(sourceName), objectDebugName(targetActor),
                    tostring(matchedPattern), tostring(amount))
            end)
            return false
        end

        dlog(function()
            return loc("matched_rule", tostring(sourceName), objectDebugName(targetActor),
                tostring(matchedPattern), amount)
        end)

        amount = Cache.adjustExpForCaps(amount, matchedPattern)
        if amount == nil or amount <= 0 then
            bump("CapBlocked")
            dlog(function()
                return loc("blocked_by_caps", tostring(sourceName), objectDebugName(targetActor),
                    tostring(matchedPattern))
            end)
            return false
        end

        cleanAwardCache(now)

        if key == nil then
            key = objectAddress(targetActor) or objectText(targetActor)
        end

        if isAwardKeyActive(key, now) then
            bump("Duplicates")
            dlog(loc("skip_duplicate_fallback", tostring(sourceName), tostring(key)))
            return false
        end

        if key ~= nil and key ~= "" then
            awardedKills[key] = now
        end

        local ok, result = pcall(grantExpThroughScenarioTask, amount, matchedPattern)

        if not ok or result ~= true then
            if key ~= nil and key ~= "" then
                awardedKills[key] = nil
            end
            bump("Errors")
            if not ok then
                log(loc("add_exp_error", tostring(sourceName), tostring(result)))
            end
            return false
        end

        maybeLogSummary(now)
        return true
    end

    function M.ownerFromComponent(component)
        local ok, owner = safeCall(component, "GetOwner")
        if ok and isValid(owner) then return owner end

        owner = safeRead(component, "Owner")
        if isValid(owner) then return owner end

        owner = safeRead(component, "OwnerPrivate")
        if isValid(owner) then return owner end

        return nil
    end

    return M
end

return makeGrant
