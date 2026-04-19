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
local MOD_BUILD = "2026-04-19-config-json"
local HIDE_EXP_NOTIFICATION = false
local DEDUPE_TTL_SECONDS = 30
local PREWARM_DELAY_MS = 2000
local NO_MATCH_LOG_LIMIT = 5
local CAP_LOG_LIMIT = 5
local LEVEL_CAP = 100
local TALENT_POINTS_CAP = 300

local EXP_BY_TARGET = {}

local unpackArgs = table.unpack or unpack
local awardedKills = {}
local awardEvents = 0
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
    HIDE_EXP_NOTIFICATION = settingBool(config.Settings, "hide_exp_notification", HIDE_EXP_NOTIFICATION)
    DEDUPE_TTL_SECONDS = settingInt(config.Settings, "dedupe_ttl_seconds", DEDUPE_TTL_SECONDS)
    PREWARM_DELAY_MS = settingInt(config.Settings, "prewarm_delay_ms", PREWARM_DELAY_MS)
    NO_MATCH_LOG_LIMIT = settingInt(config.Settings, "no_match_log_limit", NO_MATCH_LOG_LIMIT)
    CAP_LOG_LIMIT = settingInt(config.Settings, "cap_log_limit", CAP_LOG_LIMIT)
    LEVEL_CAP = settingInt(config.Settings, "level_cap", LEVEL_CAP)
    TALENT_POINTS_CAP = settingInt(config.Settings, "talent_points_cap", TALENT_POINTS_CAP)

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

local function objectAddress(object)
    local raw = unwrap(object)
    if raw == nil or not isValid(raw) then
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

local function expForTarget(targetActor)
    if not isValid(targetActor) then
        return nil, nil
    end

    local text = objectText(targetActor)
    if text == "" then
        return nil, nil
    end

    local lowerText = string.lower(text)
    for _, rule in ipairs(EXP_BY_TARGET) do
        if string.find(lowerText, string.lower(rule.Pattern), 1, true) ~= nil then
            return rule.Exp, rule.Pattern
        end
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

local function logCap(message)
    capLogs = capLogs + 1
    if capLogs <= CAP_LOG_LIMIT then
        log(message)
    end
end

local function adjustExpForCaps(amount, reason)
    local adjustedAmount = amount

    if LEVEL_CAP > 0 then
        local currentLevel = currentPlayerLevel()
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
                local expToNext = currentExpToNextLevel()
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
        local talentPoints, pointsKind = currentTalentPoints()
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

local function cleanAwardCache()
    awardEvents = awardEvents + 1
    if awardEvents % 10 ~= 0 then
        return
    end

    local now = os.time()
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

    cleanAwardCache()

    local key = objectAddress(targetActor)
    if key == nil then
        key = objectText(targetActor)
    end

    if key ~= nil and key ~= "" and awardedKills[key] ~= nil then
        return false
    end

    if key ~= nil and key ~= "" then
        awardedKills[key] = os.time()
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
        end)
    end)
end

registerHookSafe("/Script/R5.R5DamageUIComponent:OnASCDamageDealt", function(context, targetActor, incomingDamage, dealtDamage, armorReduction, isKillDamage, effectSpec)
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
