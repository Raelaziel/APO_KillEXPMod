-- Player packages may not include UEHelpers, so keep the mod loadable without it.
local okUEHelpers, UEHelpers = pcall(require, "UEHelpers")
if not okUEHelpers then
    UEHelpers = nil
end

local CONFIG_LOADER_PATHS = {
    "Mods/KillExpMod/Scripts/kill_exp_config.lua",
    "ue4ss/Mods/KillExpMod/Scripts/kill_exp_config.lua",
}

local CONFIG_PATHS = {
    "Mods/KillExpMod/Config/exp_rules.json",
    "ue4ss/Mods/KillExpMod/Config/exp_rules.json",
}

local MOD_NAME = "KillExpMod"
local MOD_BUILD = "2026-04-19-caps-config"
local HIDE_EXP_NOTIFICATION = false
local DEDUPE_TTL_SECONDS = 30
local PREWARM_DELAY_MS = 2000
local NO_MATCH_LOG_LIMIT = 5
local CAP_LOG_LIMIT = 5
local LEVEL_CAP = 100
local TALENT_POINTS_CAP = 300
local CAP_CACHE_WINDOW_MS = 5000
local CAP_CACHE_WINDOW_FAR_MS = 30000
local CAP_NEAR_LEVEL_MARGIN = 5
local CAP_NEAR_TALENT_MARGIN = 15
local SCENARIO_CONTEXT_RETRY_SECONDS = 5

local EXP_BY_TARGET = {}
local MATCH_RULES = {}
local MATCH_RESULTS_BY_CLASS = {}
local MATCH_RESULT_NONE = {}

local unpackArgs = table.unpack or unpack
local awardedKills = {}
local nextAwardCacheCleanupAt = 0
local noMatchLogs = 0
local capLogs = 0
local cachedPlayerController = nil
local cachedPlayerCharacter = nil
local cachedPlayerState = nil
local cachedScenarioComponent = nil
local cachedAddExpTaskClass = nil
local cachedProgressionObserver = nil
local cachedEntityProgressionVM = nil
local cachedTalentTreeVM = nil
local cachedScenarioExecutor = nil
local cachedScenarioGraph = nil
local nextScenarioExecutorLookupAt = 0
local nextScenarioGraphLookupAt = 0
local cachedCapState = {
    ExpiresAt = 0,
    Level = nil,
    ExpToNextLevel = nil,
    TalentPoints = nil,
    TalentPointsKind = nil,
}

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, tostring(message)))
end

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
    if value == nil then
        return fallback
    end

    if value == true or value == false then
        return value
    end

    local text = string.lower(tostring(value))
    return text == "true" or text == "1" or text == "yes"
end

local function settingInt(settings, key, fallback)
    local value = tonumber(tostring(settings[key]))
    if value == nil then
        return fallback
    end

    return math.floor(value)
end

local function loadExpConfig()
    local loader, loaderPath = loadScriptFromPaths(CONFIG_LOADER_PATHS)
    if loader == nil or type(loader.load) ~= "function" then
        log("EXP config loader was not found: " .. tostring(loaderPath))
        return
    end

    local config, errorMessage = loader.load(CONFIG_PATHS)
    if config == nil then
        log("EXP config was not loaded: " .. tostring(errorMessage))
        return
    end

    EXP_BY_TARGET = config.Rules or {}
    MATCH_RULES = {}
    MATCH_RESULTS_BY_CLASS = {}
    for _, rule in ipairs(EXP_BY_TARGET) do
        if rule.Pattern ~= nil and rule.Pattern ~= "" then
            MATCH_RULES[#MATCH_RULES + 1] = {
                Exp = rule.Exp,
                Pattern = rule.Pattern,
                PatternLower = string.lower(rule.Pattern),
            }
        end
    end

    HIDE_EXP_NOTIFICATION = settingBool(config.Settings, "hide_exp_notification", HIDE_EXP_NOTIFICATION)
    DEDUPE_TTL_SECONDS = settingInt(config.Settings, "dedupe_ttl_seconds", DEDUPE_TTL_SECONDS)
    PREWARM_DELAY_MS = settingInt(config.Settings, "prewarm_delay_ms", PREWARM_DELAY_MS)
    NO_MATCH_LOG_LIMIT = settingInt(config.Settings, "no_match_log_limit", NO_MATCH_LOG_LIMIT)
    CAP_LOG_LIMIT = settingInt(config.Settings, "cap_log_limit", CAP_LOG_LIMIT)
    LEVEL_CAP = settingInt(config.Settings, "level_cap", LEVEL_CAP)
    TALENT_POINTS_CAP = settingInt(config.Settings, "talent_points_cap", TALENT_POINTS_CAP)
    CAP_CACHE_WINDOW_MS = settingInt(config.Settings, "cap_cache_window_ms", CAP_CACHE_WINDOW_MS)
    CAP_CACHE_WINDOW_FAR_MS = settingInt(config.Settings, "cap_cache_window_far_ms", CAP_CACHE_WINDOW_FAR_MS)
    CAP_NEAR_LEVEL_MARGIN = settingInt(config.Settings, "cap_near_level_margin", CAP_NEAR_LEVEL_MARGIN)
    CAP_NEAR_TALENT_MARGIN = settingInt(config.Settings, "cap_near_talent_margin", CAP_NEAR_TALENT_MARGIN)

    log(string.format(
        "Loaded %d EXP rules from %s.",
        #EXP_BY_TARGET,
        tostring(config.Path)
    ))

    for _, warning in ipairs(config.Warnings or {}) do
        log("Config warning: " .. tostring(warning))
    end
end

loadExpConfig()

local function isUnrealParam(value)
    return value ~= nil and string.find(tostring(value), "UnrealParam", 1, true) ~= nil
end

local function unwrap(value)
    if value == nil then
        return nil
    end

    if isUnrealParam(value) then
        local ok, result = pcall(function()
            return value:get()
        end)

        if ok then
            return result
        end
    end

    return value
end

local function isObjectLike(value)
    local raw = unwrap(value)
    if raw == nil then
        return false
    end

    local valueType = type(raw)
    return valueType == "userdata" or valueType == "table"
end

local function isValid(value)
    local raw = unwrap(value)
    if raw == nil or not isObjectLike(raw) then
        return false
    end

    local okFn, fn = pcall(function()
        return raw.IsValid
    end)

    if okFn and type(fn) == "function" then
        local ok, result = pcall(function()
            return fn(raw)
        end)

        if ok then
            return result == true
        end
    end

    return true
end

local function safeRead(object, field)
    local raw = unwrap(object)
    if raw == nil then
        return nil
    end

    local ok, result = pcall(function()
        return raw[field]
    end)

    if ok then
        return result
    end

    return nil
end

local function safeCall(object, method, ...)
    local raw = unwrap(object)
    if raw == nil or not isValid(raw) then
        return false, nil
    end

    local okFn, fn = pcall(function()
        return raw[method]
    end)

    if not okFn or fn == nil then
        return false, nil
    end

    local args = { ... }
    return pcall(function()
        return fn(raw, unpackArgs(args))
    end)
end

local function isTrue(value)
    local raw = unwrap(value)
    if raw == true then
        return true
    end

    if type(raw) == "number" then
        return raw ~= 0
    end

    local text = string.lower(tostring(raw))
    return text == "true" or text == "1"
end

local function asNumber(value)
    local raw = unwrap(value)
    if type(raw) == "number" then
        return math.floor(raw)
    end

    local number = tonumber(tostring(raw))
    if number == nil then
        return nil
    end

    return math.floor(number)
end

local function safeNumberCall(object, method)
    local ok, result = safeCall(object, method)
    if ok then
        return asNumber(result)
    end

    return nil
end

local function safeStaticFind(path)
    local ok, object = pcall(StaticFindObject, path)
    if ok and object ~= nil and isValid(object) then
        return object
    end

    return nil
end

local function safeFindFirst(className)
    local ok, object = pcall(FindFirstOf, className)
    if ok and object ~= nil and isValid(object) then
        return object
    end

    return nil
end

local function safeRawCall(raw, method)
    if raw == nil then
        return false, nil
    end

    local okFn, fn = pcall(function()
        return raw[method]
    end)

    if not okFn or fn == nil then
        return false, nil
    end

    return pcall(function()
        return fn(raw)
    end)
end

local function rawObjectAddress(raw)
    if raw == nil then
        return nil
    end

    local ok, address = pcall(function()
        return raw:GetAddress()
    end)

    if ok and address ~= nil then
        return tostring(address)
    end

    return nil
end

local function objectAddress(object)
    local raw = unwrap(object)
    if raw == nil or not isValid(raw) then
        return nil
    end

    return rawObjectAddress(raw)
end

local function appendObjectText(parts, object, callback)
    local raw = unwrap(object)
    if raw == nil or not isValid(raw) then
        return
    end

    local ok, result = pcall(callback, raw)
    if ok and result ~= nil then
        parts[#parts + 1] = tostring(result)
    end
end

local function objectText(object)
    local parts = {}

    appendObjectText(parts, object, function(raw)
        return raw:GetFullName()
    end)

    appendObjectText(parts, object, function(raw)
        return raw:GetName()
    end)

    appendObjectText(parts, object, function(raw)
        local class = raw:GetClass()
        if class == nil then
            return nil
        end
        return class:GetFullName()
    end)

    appendObjectText(parts, object, function(raw)
        local class = raw:GetClass()
        if class == nil then
            return nil
        end
        return class:GetName()
    end)

    return table.concat(parts, " ")
end

local function targetMatchText(targetActor)
    local raw = unwrap(targetActor)
    if raw == nil or not isValid(raw) then
        return nil, nil
    end

    local okClass, classObject = safeRawCall(raw, "GetClass")
    local classKey = nil

    local className = ""
    local classFullName = ""

    if okClass and isValid(classObject) then
        classKey = rawObjectAddress(classObject)

        local okClassName, classNameValue = safeRawCall(classObject, "GetName")
        if okClassName and classNameValue ~= nil then
            className = tostring(classNameValue)
        end

        local okClassFullName, classFullNameValue = safeRawCall(classObject, "GetFullName")
        if okClassFullName and classFullNameValue ~= nil then
            classFullName = tostring(classFullNameValue)
        end
    end

    if classKey == nil or classKey == "" then
        if classFullName ~= "" then
            classKey = classFullName
        elseif className ~= "" then
            classKey = className
        end
    end

    if className == "" and classFullName == "" then
        local actorName = ""
        local okActorName, actorNameValue = safeRawCall(raw, "GetName")
        if okActorName and actorNameValue ~= nil then
            actorName = tostring(actorNameValue)
        end

        local actorFullName = ""
        local okActorFullName, actorFullNameValue = safeRawCall(raw, "GetFullName")
        if okActorFullName and actorFullNameValue ~= nil then
            actorFullName = tostring(actorFullNameValue)
        end

        if actorName == "" and actorFullName == "" then
            return classKey, nil
        end

        return classKey, string.lower(table.concat({
            actorName,
            actorFullName,
        }, " "))
    end

    return classKey, string.lower(table.concat({
        className,
        classFullName,
    }, " "))
end

local function expForTarget(targetActor)
    if not isValid(targetActor) then
        return nil, nil
    end

    local classKey, text = targetMatchText(targetActor)
    if classKey ~= nil and classKey ~= "" then
        local cachedRule = MATCH_RESULTS_BY_CLASS[classKey]
        if cachedRule == MATCH_RESULT_NONE then
            return nil, nil
        end

        if cachedRule ~= nil then
            return cachedRule.Exp, cachedRule.Pattern
        end
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

local function currentPlayerController()
    if isValid(cachedPlayerController) then
        return cachedPlayerController
    end

    local ok = false
    local controller = nil

    if UEHelpers ~= nil and type(UEHelpers.GetPlayerController) == "function" then
        ok, controller = pcall(function()
            return UEHelpers.GetPlayerController()
        end)
    end

    if ok and isValid(controller) then
        cachedPlayerController = controller
        return controller
    end

    ok, controller = pcall(FindFirstOf, "R5PlayerController")
    if ok and isValid(controller) then
        cachedPlayerController = controller
        return controller
    end

    return nil
end

local function currentPlayerCharacter()
    if isValid(cachedPlayerCharacter) then
        return cachedPlayerCharacter
    end

    local controller = currentPlayerController()
    if not isValid(controller) then
        return nil
    end

    local okCharacter, character = pcall(function()
        return controller:GetR5PlayerCharacter()
    end)

    if okCharacter and isValid(character) then
        cachedPlayerCharacter = character
        return character
    end

    character = safeRead(controller, "Pawn")
    if isValid(character) then
        cachedPlayerCharacter = character
        return character
    end

    return nil
end

local function currentPlayerState()
    if isValid(cachedPlayerState) then
        return cachedPlayerState
    end

    local controller = currentPlayerController()
    local playerState = safeRead(controller, "PlayerState")
    if isValid(playerState) then
        cachedPlayerState = playerState
        return playerState
    end

    local character = currentPlayerCharacter()
    local okState, state = safeCall(character, "GetR5PlayerState")
    if okState and isValid(state) then
        cachedPlayerState = state
        return state
    end

    return nil
end

local function currentScenarioComponent()
    if isValid(cachedScenarioComponent) then
        return cachedScenarioComponent
    end

    local playerState = currentPlayerState()
    local component = safeRead(playerState, "ScenarioComponent")
    if isValid(component) then
        cachedScenarioComponent = component
        return component
    end

    return nil
end

local function currentProgressionObserver()
    if isValid(cachedProgressionObserver) then
        return cachedProgressionObserver
    end

    cachedProgressionObserver = safeFindFirst("R5SC_ProgressionObserver")
    return cachedProgressionObserver
end

local function currentTalentTreeVM()
    if isValid(cachedTalentTreeVM) then
        return cachedTalentTreeVM
    end

    cachedTalentTreeVM = safeFindFirst("R5UITalentTreeVM")
    return cachedTalentTreeVM
end

local function currentEntityProgressionVM()
    if isValid(cachedEntityProgressionVM) then
        return cachedEntityProgressionVM
    end

    local talentTreeVM = currentTalentTreeVM()
    local okVM, vm = safeCall(talentTreeVM, "GetEntityProgressionVM")
    if okVM and isValid(vm) then
        cachedEntityProgressionVM = vm
        return vm
    end

    cachedEntityProgressionVM = safeFindFirst("R5EntityProgressionVM")
    return cachedEntityProgressionVM
end

local function firstValidProperty(object, names)
    for _, name in ipairs(names) do
        local value = safeRead(object, name)
        if isValid(value) then
            return value, name
        end
    end

    return nil, nil
end

local function firstValidMethodResult(object, methods)
    for _, method in ipairs(methods) do
        local ok, value = safeCall(object, method)
        if ok and isValid(value) then
            return value, method
        end
    end

    return nil, nil
end

local function currentScenarioExecutor()
    if isValid(cachedScenarioExecutor) then
        return cachedScenarioExecutor
    end

    local now = os.time()
    if now < nextScenarioExecutorLookupAt then
        return nil
    end

    nextScenarioExecutorLookupAt = now + SCENARIO_CONTEXT_RETRY_SECONDS

    local scenarioComponent = currentScenarioComponent()
    local executor = nil

    executor = select(1, firstValidProperty(scenarioComponent, {
        "Executor",
        "ScenarioExecutor",
        "NodeExecutor",
        "CurrentExecutor",
    }))

    if not isValid(executor) then
        executor = select(1, firstValidMethodResult(scenarioComponent, {
            "GetExecutor",
            "GetScenarioExecutor",
            "GetNodeExecutor",
            "GetCurrentExecutor",
        }))
    end

    if isValid(executor) then
        cachedScenarioExecutor = executor
        nextScenarioExecutorLookupAt = 0
        return executor
    end

    return nil
end

local function currentScenarioGraph()
    if isValid(cachedScenarioGraph) then
        return cachedScenarioGraph
    end

    local now = os.time()
    if now < nextScenarioGraphLookupAt then
        return nil
    end

    nextScenarioGraphLookupAt = now + SCENARIO_CONTEXT_RETRY_SECONDS

    local scenarioComponent = currentScenarioComponent()
    local graph = nil

    graph = select(1, firstValidProperty(scenarioComponent, {
        "BaseGraph",
        "Graph",
        "ScenarioGraph",
        "CurrentGraph",
        "OwningGraph",
    }))

    if not isValid(graph) then
        graph = select(1, firstValidMethodResult(scenarioComponent, {
            "GetBaseGraph",
            "GetGraph",
            "GetScenarioGraph",
            "GetCurrentGraph",
            "GetOwningGraph",
        }))
    end

    if isValid(graph) then
        cachedScenarioGraph = graph
        nextScenarioGraphLookupAt = 0
        return graph
    end

    local executor = currentScenarioExecutor()
    graph = select(1, firstValidProperty(executor, {
        "BaseGraph",
        "Graph",
        "ScenarioGraph",
        "CurrentGraph",
        "OwningGraph",
    }))

    if not isValid(graph) then
        graph = select(1, firstValidMethodResult(executor, {
            "GetBaseGraph",
            "GetGraph",
            "GetScenarioGraph",
            "GetCurrentGraph",
            "GetOwningGraph",
        }))
    end

    if isValid(graph) then
        cachedScenarioGraph = graph
        nextScenarioGraphLookupAt = 0
        return graph
    end

    return nil
end

local function currentPlayerLevel()
    local observer = currentProgressionObserver()
    local level = safeNumberCall(observer, "GetPlayerCurrentLevel")
    if level ~= nil then
        return level
    end

    local progressionVM = currentEntityProgressionVM()
    return safeNumberCall(progressionVM, "GetCurrentLevel")
end

local function currentExpToNextLevel()
    local progressionVM = currentEntityProgressionVM()
    return safeNumberCall(progressionVM, "GetExpToNextLevel")
end

local function currentTalentPoints()
    local talentTreeVM = currentTalentTreeVM()
    local points = safeNumberCall(talentTreeVM, "GetAvailableTalentPoints")
    if points ~= nil then
        return points, "available"
    end

    points = safeNumberCall(talentTreeVM, "GetFreeTalentPoints")
    if points ~= nil then
        return points, "free"
    end

    return nil, nil
end

local function capWindowForState(level, talentPoints)
    local levelIsNearCap = false
    local talentIsNearCap = false

    if LEVEL_CAP > 0 and level ~= nil then
        levelIsNearCap = level >= (LEVEL_CAP - CAP_NEAR_LEVEL_MARGIN)
    end

    if TALENT_POINTS_CAP > 0 and talentPoints ~= nil then
        talentIsNearCap = talentPoints >= (TALENT_POINTS_CAP - CAP_NEAR_TALENT_MARGIN)
    end

    if levelIsNearCap or talentIsNearCap then
        return CAP_CACHE_WINDOW_MS
    end

    return CAP_CACHE_WINDOW_FAR_MS
end

local function logCap(message)
    capLogs = capLogs + 1
    if capLogs <= CAP_LOG_LIMIT then
        log(message)
    end
end

local function currentCapState()
    local nowSeconds = os.time()
    if nowSeconds < cachedCapState.ExpiresAt then
        return cachedCapState
    end

    local level = nil
    local expToNextLevel = nil
    if LEVEL_CAP > 0 then
        level = currentPlayerLevel()
        if level ~= nil and level == LEVEL_CAP - 1 then
            expToNextLevel = currentExpToNextLevel()
        end
    end

    local talentPoints = nil
    local talentPointsKind = nil
    if TALENT_POINTS_CAP > 0 then
        talentPoints, talentPointsKind = currentTalentPoints()
    end

    local cacheWindowMs = capWindowForState(level, talentPoints)
    local expiresAt = nowSeconds + math.max(1, math.floor(cacheWindowMs / 1000))

    cachedCapState = {
        ExpiresAt = expiresAt,
        Level = level,
        ExpToNextLevel = expToNextLevel,
        TalentPoints = talentPoints,
        TalentPointsKind = talentPointsKind,
    }

    return cachedCapState
end

local function adjustExpForCaps(amount, reason)
    local adjustedAmount = amount
    local capState = currentCapState()

    if LEVEL_CAP > 0 then
        local currentLevel = capState.Level
        if currentLevel ~= nil then
            if currentLevel >= LEVEL_CAP then
                logCap(string.format(
                    "EXP pominiety: level cap %d osiagniety (%d).",
                    LEVEL_CAP,
                    currentLevel
                ))
                return 0
            end

            if currentLevel == LEVEL_CAP - 1 then
                local expToNext = capState.ExpToNextLevel
                if expToNext ~= nil and expToNext > 0 and adjustedAmount > expToNext then
                    logCap(string.format(
                        "EXP uciety do level cap %d: %d -> %d za %s.",
                        LEVEL_CAP,
                        adjustedAmount,
                        expToNext,
                        tostring(reason or "kill")
                    ))
                    adjustedAmount = expToNext
                end
            end
        end
    end

    if TALENT_POINTS_CAP > 0 then
        local talentPoints = capState.TalentPoints
        local pointsKind = capState.TalentPointsKind
        if talentPoints ~= nil and talentPoints >= TALENT_POINTS_CAP then
            logCap(string.format(
                "EXP pominiety: talent cap %d osiagniety (%d %s).",
                TALENT_POINTS_CAP,
                talentPoints,
                tostring(pointsKind or "points")
            ))
            return 0
        end
    end

    return adjustedAmount
end

local function primaryWorldContext()
    local scenarioComponent = currentScenarioComponent()
    if isValid(scenarioComponent) then
        return scenarioComponent
    end

    local character = currentPlayerCharacter()
    if isValid(character) then
        return character
    end

    local playerState = currentPlayerState()
    if isValid(playerState) then
        return playerState
    end

    local controller = currentPlayerController()
    if isValid(controller) then
        return controller
    end

    local okGameInstance = false
    local gameInstance = nil

    if UEHelpers ~= nil and type(UEHelpers.GetGameInstance) == "function" then
        okGameInstance, gameInstance = pcall(function()
            return UEHelpers.GetGameInstance()
        end)
    end

    if okGameInstance and isValid(gameInstance) then
        return gameInstance
    end

    okGameInstance, gameInstance = pcall(FindFirstOf, "R5GameInstance")
    if okGameInstance and isValid(gameInstance) then
        return gameInstance
    end

    return nil
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

local function setTaskExp(task, amount)
    local ok, err = pcall(function()
        task.exp = amount
    end)

    if not ok then
        log("Nie ustawiono pola exp w UR5ScenarioTask_AddExp: " .. tostring(err))
        return false
    end

    return true
end

local function setTaskField(task, field, value)
    if not isValid(task) or not isValid(value) then
        return false
    end

    local ok = pcall(function()
        task[field] = value
    end)

    return ok
end

local function prepareScenarioTask(task)
    local scenarioGraph = currentScenarioGraph()
    local scenarioExecutor = currentScenarioExecutor()

    local taskGraph = safeRead(task, "BaseGraph")
    if not isValid(taskGraph) and isValid(scenarioGraph) then
        setTaskField(task, "BaseGraph", scenarioGraph)
        setTaskField(task, "Graph", scenarioGraph)
        setTaskField(task, "OwningGraph", scenarioGraph)
    end

    local taskExecutor = safeRead(task, "Executor")
    if not isValid(taskExecutor) and isValid(scenarioExecutor) then
        setTaskField(task, "Executor", scenarioExecutor)
        setTaskField(task, "NodeExecutor", scenarioExecutor)
        setTaskField(task, "ScenarioExecutor", scenarioExecutor)
        setTaskField(task, "CurrentExecutor", scenarioExecutor)
    end

    return isValid(safeRead(task, "BaseGraph")) or isValid(safeRead(task, "Graph")),
        isValid(safeRead(task, "Executor")) or isValid(safeRead(task, "NodeExecutor"))
end

local function targetAwardKey(targetActor)
    local key = objectAddress(targetActor)
    if key ~= nil and key ~= "" then
        return key
    end

    return objectText(targetActor)
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

local function grantExpThroughScenarioTask(amount, reason)
    local worldContext = primaryWorldContext()
    if not isValid(worldContext) then
        log("UR5ScenarioTask_AddExp: brak world context.")
        return false
    end

    local taskClass = addExpTaskClass()
    if not isValid(taskClass) then
        log("UR5ScenarioTask_AddExp: brak klasy taska.")
        return false
    end

    local okConstruct, task = pcall(function()
        return StaticConstructObject(taskClass, worldContext)
    end)

    if not okConstruct or not isValid(task) then
        log("UR5ScenarioTask_AddExp: StaticConstructObject nie utworzyl taska.")
        return false
    end

    if not setTaskExp(task, amount) then
        return false
    end

    pcall(function()
        task.bHideNotification = HIDE_EXP_NOTIFICATION
    end)

    local character = currentPlayerCharacter()
    if isValid(character) then
        pcall(function()
            task.Target = character
        end)
    end

    prepareScenarioTask(task)

    safeCall(task, "OnNodeCreated")

    local okInit, initErr = safeCall(task, "OnInit")
    if not okInit then
        log("UR5ScenarioTask_AddExp: OnInit nie powiodlo sie: " .. tostring(initErr))
        return false
    end

    local okExec, execErr = safeCall(task, "OnExec")
    if not okExec then
        log("UR5ScenarioTask_AddExp: OnExec nie powiodlo sie: " .. tostring(execErr))
        return false
    end

    log(string.format("EXP: +%d za %s.", amount, tostring(reason or "kill")))
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

local function awardExpForTarget(targetActor, sourceName)
    if not isValid(targetActor) then
        return false
    end

    local now = os.time()
    local key = objectAddress(targetActor)
    if isAwardKeyActive(key, now) then
        return false
    end

    local amount, matchedPattern = expForTarget(targetActor)
    if amount == nil or amount <= 0 then
        if amount == nil and noMatchLogs < NO_MATCH_LOG_LIMIT then
            noMatchLogs = noMatchLogs + 1
            log("Brak reguly EXP dla " .. tostring(sourceName) .. ": " .. objectText(targetActor))
        end
        return false
    end

    amount = adjustExpForCaps(amount, matchedPattern)
    if amount == nil or amount <= 0 then
        return false
    end

    cleanAwardCache(now)

    if key == nil then
        key = targetAwardKey(targetActor)
    end

    if isAwardKeyActive(key, now) then
        return false
    end

    if key ~= nil and key ~= "" then
        awardedKills[key] = now
    end

    local ok, result = pcall(function()
        return grantExpThroughScenarioTask(amount, matchedPattern)
    end)

    if not ok then
        if key ~= nil and key ~= "" then
            awardedKills[key] = nil
        end
        log("Blad podczas dodawania EXP przez " .. tostring(sourceName) .. ": " .. tostring(result))
        return false
    end

    if result ~= true then
        if key ~= nil and key ~= "" then
            awardedKills[key] = nil
        end
        return false
    end

    return true
end

local function ownerFromComponent(component)
    local okOwner, owner = safeCall(component, "GetOwner")
    if okOwner and isValid(owner) then
        return owner
    end

    owner = safeRead(component, "Owner")
    if isValid(owner) then
        return owner
    end

    owner = safeRead(component, "OwnerPrivate")
    if isValid(owner) then
        return owner
    end

    return nil
end

local function handleKillDamage(targetParam, killParam, sourceName)
    if not isTrue(killParam) then
        return
    end

    awardExpForTarget(unwrap(targetParam), sourceName)
end

local function handleDamageInstance(damageInstanceParam, sourceName)
    local damageInstance = unwrap(damageInstanceParam)
    local targetActor = safeRead(damageInstance, "Target")
    local isKillDamage = safeRead(damageInstance, "bIsKillDamage")

    handleKillDamage(targetActor, isKillDamage, sourceName)
end

local function handleDeathComponent(context)
    local component = unwrap(context)
    if not isValid(component) then
        return
    end

    local deathEventData = safeRead(component, "DeathEventData")
    if not isTrue(safeRead(deathEventData, "bDead")) then
        return
    end

    awardExpForTarget(ownerFromComponent(component), "DeathComponent")
end

local function registerHookSafe(path, callback)
    local ok, err = pcall(function()
        RegisterHook(path, callback)
    end)

    if ok then
        log("Hook aktywny: " .. path)
    else
        log("Hook niedostepny: " .. path .. " / " .. tostring(err))
    end
end

if type(ExecuteWithDelay) == "function" then
    pcall(function()
        ExecuteWithDelay(PREWARM_DELAY_MS, function()
            addExpTaskClass()
            primaryWorldContext()
            currentProgressionObserver()
            currentEntityProgressionVM()
            currentTalentTreeVM()
            currentScenarioExecutor()
            currentScenarioGraph()
            currentCapState()
        end)
    end)
end

registerHookSafe("/Script/R5.R5DamageUIComponent:OnASCDamageDealt",
    function(context, targetActor, incomingDamage, dealtDamage, armorReduction, isKillDamage, effectSpec)
        handleKillDamage(targetActor, isKillDamage, "DamageUI")
    end)

registerHookSafe("/Script/R5.R5DamageUIComponent:ClientDamageDealt", function(context, damageInstance)
    handleDamageInstance(damageInstance, "ClientDamageDealt")
end)

registerHookSafe("/Script/R5.R5DamageUIComponent:NetMulticastDamageDealt", function(context, damageInstance)
    handleDamageInstance(damageInstance, "NetMulticastDamageDealt")
end)

registerHookSafe("/Script/R5.R5DeathComponent:OnRep_DeathEventData", function(context)
    handleDeathComponent(context)
end)

log("Build " .. MOD_BUILD .. " zaladowany.")
