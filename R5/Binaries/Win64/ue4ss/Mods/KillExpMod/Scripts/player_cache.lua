-- player_cache.lua
-- Tracks the live UE player objects (controller, pawn, state, scenario chain)
-- and the cap/level state needed for EXP gating.
-- Returns a factory: local Cache = dofile("...player_cache.lua")(UU, Diag, cfg)

local function makeCache(UU, Diag)
    local isValid                        = UU.isValid
    local safeRead                       = UU.safeRead
    local safeCall                       = UU.safeCall
    local safeNumberCall                 = UU.safeNumberCall
    local safeFindFirst                  = UU.safeFindFirst
    local sameObject                     = UU.sameObject
    local objectDebugName                = UU.objectDebugName
    local unwrap                         = UU.unwrap

    local log                            = Diag.log
    local loc                            = Diag.loc
    local dlog                           = Diag.diagnosticLog

    -- Runtime config (overwritten by init).
    local UEHelpers                      = nil
    local SCENARIO_CONTEXT_RETRY_SECONDS = 5
    local LEVEL_CAP                      = 100
    local TALENT_POINTS_CAP              = 300
    local CAP_CACHE_WINDOW_MS            = 5000
    local CAP_CACHE_WINDOW_FAR_MS        = 30000
    local CAP_NEAR_LEVEL_MARGIN          = 5
    local CAP_NEAR_TALENT_MARGIN         = 15
    local CAP_LOG_LIMIT                  = 5

    local capLogs                        = 0

    -- Object caches.
    local cachedPlayerController         = nil
    local cachedPlayerCharacter          = nil
    local cachedPlayerState              = nil
    local cachedScenarioComponent        = nil
    local cachedProgressionObserver      = nil
    local cachedEntityProgressionVM      = nil
    local cachedTalentTreeVM             = nil
    local cachedScenarioExecutor         = nil
    local cachedScenarioGraph            = nil
    local nextScenarioExecutorLookupAt   = 0
    local nextScenarioGraphLookupAt      = 0

    local cachedCapState                 = {
        ExpiresAt = 0,
        Level = nil,
        ExpToNextLevel = nil,
        TalentPoints = nil,
        TalentPointsKind = nil,
    }

    local M                              = {}

    function M.init(cfg)
        UEHelpers = cfg.UEHelpers
        SCENARIO_CONTEXT_RETRY_SECONDS = cfg.SCENARIO_CONTEXT_RETRY_SECONDS or SCENARIO_CONTEXT_RETRY_SECONDS
        LEVEL_CAP = cfg.LEVEL_CAP or LEVEL_CAP
        TALENT_POINTS_CAP = cfg.TALENT_POINTS_CAP or TALENT_POINTS_CAP
        CAP_CACHE_WINDOW_MS = cfg.CAP_CACHE_WINDOW_MS or CAP_CACHE_WINDOW_MS
        CAP_CACHE_WINDOW_FAR_MS = cfg.CAP_CACHE_WINDOW_FAR_MS or CAP_CACHE_WINDOW_FAR_MS
        CAP_NEAR_LEVEL_MARGIN = cfg.CAP_NEAR_LEVEL_MARGIN or CAP_NEAR_LEVEL_MARGIN
        CAP_NEAR_TALENT_MARGIN = cfg.CAP_NEAR_TALENT_MARGIN or CAP_NEAR_TALENT_MARGIN
        CAP_LOG_LIMIT = cfg.CAP_LOG_LIMIT or CAP_LOG_LIMIT
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

    function M.resetScenarioRuntimeCache(reason)
        cachedScenarioComponent      = nil
        cachedScenarioExecutor       = nil
        cachedScenarioGraph          = nil
        nextScenarioExecutorLookupAt = 0
        nextScenarioGraphLookupAt    = 0

        if reason ~= nil then
            dlog(loc("cache_refresh_scenario", tostring(reason)))
        end
    end

    function M.resetPlayerRuntimeCache(reason)
        cachedPlayerCharacter     = nil
        cachedPlayerState         = nil
        cachedProgressionObserver = nil
        cachedEntityProgressionVM = nil
        cachedTalentTreeVM        = nil
        cachedCapState            = {
            ExpiresAt = 0,
            Level = nil,
            ExpToNextLevel = nil,
            TalentPoints = nil,
            TalentPointsKind = nil,
        }

        M.resetScenarioRuntimeCache(reason)

        if reason ~= nil then
            dlog(loc("cache_refresh_player", tostring(reason)))
        end
    end

    function M.currentPlayerController()
        if isValid(cachedPlayerController) then
            return cachedPlayerController
        end

        local ok, controller = false, nil

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

    function M.currentPlayerCharacter()
        local controller = M.currentPlayerController()
        local freshCharacter = nil

        if isValid(controller) then
            local liveController = unwrap(controller)
            local ok, character = false, nil

            if liveController ~= nil then
                ok, character = pcall(function()
                    return liveController:GetR5PlayerCharacter()
                end)
            end

            if ok and isValid(character) then
                freshCharacter = character
            else
                character = safeRead(controller, "Pawn")
                if isValid(character) then
                    freshCharacter = character
                end
            end
        end

        if isValid(freshCharacter) then
            if isValid(cachedPlayerCharacter) and not sameObject(cachedPlayerCharacter, freshCharacter) then
                dlog(function()
                    return loc("pawn_changed",
                        objectDebugName(cachedPlayerCharacter),
                        objectDebugName(freshCharacter))
                end)
                M.resetPlayerRuntimeCache(loc("reason_new_pawn"))
            end

            cachedPlayerCharacter = freshCharacter
            return freshCharacter
        end

        if isValid(cachedPlayerCharacter) then
            return cachedPlayerCharacter
        end

        return nil
    end

    function M.currentPlayerState()
        local controller = M.currentPlayerController()
        local freshState = nil

        local playerState = safeRead(controller, "PlayerState")
        if isValid(playerState) then
            freshState = playerState
        else
            local character = M.currentPlayerCharacter()
            local ok, state = safeCall(character, "GetR5PlayerState")
            if ok and isValid(state) then
                freshState = state
            end
        end

        if isValid(freshState) then
            if isValid(cachedPlayerState) and not sameObject(cachedPlayerState, freshState) then
                dlog(function()
                    return loc("player_state_changed",
                        objectDebugName(cachedPlayerState),
                        objectDebugName(freshState))
                end)
                M.resetPlayerRuntimeCache(loc("reason_new_player_state"))
            end

            cachedPlayerState = freshState
            return freshState
        end

        if isValid(cachedPlayerState) then
            return cachedPlayerState
        end

        return nil
    end

    function M.currentScenarioComponent()
        local playerState = M.currentPlayerState()
        local component = safeRead(playerState, "ScenarioComponent")
        if isValid(component) then
            if isValid(cachedScenarioComponent) and not sameObject(cachedScenarioComponent, component) then
                dlog(function()
                    return loc("scenario_component_changed",
                        objectDebugName(cachedScenarioComponent),
                        objectDebugName(component))
                end)
                M.resetScenarioRuntimeCache(loc("reason_new_scenario_component"))
            end

            cachedScenarioComponent = component
            return component
        end

        if isValid(cachedScenarioComponent) then
            return cachedScenarioComponent
        end

        return nil
    end

    function M.currentProgressionObserver()
        if isValid(cachedProgressionObserver) then
            return cachedProgressionObserver
        end

        cachedProgressionObserver = safeFindFirst("R5SC_ProgressionObserver")
        return cachedProgressionObserver
    end

    function M.currentTalentTreeVM()
        if isValid(cachedTalentTreeVM) then
            return cachedTalentTreeVM
        end

        cachedTalentTreeVM = safeFindFirst("R5UITalentTreeVM")
        return cachedTalentTreeVM
    end

    function M.currentEntityProgressionVM()
        if isValid(cachedEntityProgressionVM) then
            return cachedEntityProgressionVM
        end

        local talentTreeVM = M.currentTalentTreeVM()
        local ok, vm = safeCall(talentTreeVM, "GetEntityProgressionVM")
        if ok and isValid(vm) then
            cachedEntityProgressionVM = vm
            return vm
        end

        cachedEntityProgressionVM = safeFindFirst("R5EntityProgressionVM")
        return cachedEntityProgressionVM
    end

    local EXECUTOR_PROPS   = { "Executor", "ScenarioExecutor", "NodeExecutor", "CurrentExecutor" }
    local EXECUTOR_METHODS = { "GetExecutor", "GetScenarioExecutor", "GetNodeExecutor", "GetCurrentExecutor" }
    local GRAPH_PROPS      = { "BaseGraph", "Graph", "ScenarioGraph", "CurrentGraph", "OwningGraph" }
    local GRAPH_METHODS    = { "GetBaseGraph", "GetGraph", "GetScenarioGraph", "GetCurrentGraph", "GetOwningGraph" }

    function M.currentScenarioExecutor()
        local scenarioComponent = M.currentScenarioComponent()
        if isValid(scenarioComponent) then
            local freshExecutor = select(1, firstValidProperty(scenarioComponent, EXECUTOR_PROPS))
            if not isValid(freshExecutor) then
                freshExecutor = select(1, firstValidMethodResult(scenarioComponent, EXECUTOR_METHODS))
            end

            if isValid(freshExecutor) then
                if isValid(cachedScenarioExecutor) and not sameObject(cachedScenarioExecutor, freshExecutor) then
                    dlog(function()
                        return loc("scenario_executor_changed",
                            objectDebugName(cachedScenarioExecutor),
                            objectDebugName(freshExecutor))
                    end)
                    cachedScenarioGraph = nil
                    nextScenarioGraphLookupAt = 0
                end

                cachedScenarioExecutor = freshExecutor
                nextScenarioExecutorLookupAt = 0
                return freshExecutor
            end
        end

        if isValid(cachedScenarioExecutor) then
            return cachedScenarioExecutor
        end

        local now = os.time()
        if now < nextScenarioExecutorLookupAt then
            return nil
        end

        nextScenarioExecutorLookupAt = now + SCENARIO_CONTEXT_RETRY_SECONDS

        local executor = select(1, firstValidProperty(scenarioComponent, EXECUTOR_PROPS))
        if not isValid(executor) then
            executor = select(1, firstValidMethodResult(scenarioComponent, EXECUTOR_METHODS))
        end

        if isValid(executor) then
            cachedScenarioExecutor = executor
            nextScenarioExecutorLookupAt = 0
            return executor
        end

        return nil
    end

    function M.currentScenarioGraph()
        local scenarioComponent = M.currentScenarioComponent()
        if isValid(scenarioComponent) then
            local freshGraph = select(1, firstValidProperty(scenarioComponent, GRAPH_PROPS))
            if not isValid(freshGraph) then
                freshGraph = select(1, firstValidMethodResult(scenarioComponent, GRAPH_METHODS))
            end

            if isValid(freshGraph) then
                if isValid(cachedScenarioGraph) and not sameObject(cachedScenarioGraph, freshGraph) then
                    dlog(function()
                        return loc("scenario_graph_changed",
                            objectDebugName(cachedScenarioGraph),
                            objectDebugName(freshGraph))
                    end)
                end

                cachedScenarioGraph = freshGraph
                nextScenarioGraphLookupAt = 0
                return freshGraph
            end
        end

        if isValid(cachedScenarioGraph) then
            return cachedScenarioGraph
        end

        local now = os.time()
        if now < nextScenarioGraphLookupAt then
            return nil
        end

        nextScenarioGraphLookupAt = now + SCENARIO_CONTEXT_RETRY_SECONDS

        local graph = select(1, firstValidProperty(scenarioComponent, GRAPH_PROPS))
        if not isValid(graph) then
            graph = select(1, firstValidMethodResult(scenarioComponent, GRAPH_METHODS))
        end

        if not isValid(graph) then
            local executor = M.currentScenarioExecutor()
            graph = select(1, firstValidProperty(executor, GRAPH_PROPS))
            if not isValid(graph) then
                graph = select(1, firstValidMethodResult(executor, GRAPH_METHODS))
            end
        end

        if isValid(graph) then
            cachedScenarioGraph = graph
            nextScenarioGraphLookupAt = 0
            return graph
        end

        return nil
    end

    function M.currentPlayerLevel()
        local level = safeNumberCall(M.currentProgressionObserver(), "GetPlayerCurrentLevel")
        if level ~= nil then
            return level
        end
        return safeNumberCall(M.currentEntityProgressionVM(), "GetCurrentLevel")
    end

    function M.currentExpToNextLevel()
        return safeNumberCall(M.currentEntityProgressionVM(), "GetExpToNextLevel")
    end

    function M.currentTalentPoints()
        local talentTreeVM = M.currentTalentTreeVM()
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
        local levelIsNearCap  = LEVEL_CAP > 0 and level ~= nil
            and level >= (LEVEL_CAP - CAP_NEAR_LEVEL_MARGIN)
        local talentIsNearCap = TALENT_POINTS_CAP > 0 and talentPoints ~= nil
            and talentPoints >= (TALENT_POINTS_CAP - CAP_NEAR_TALENT_MARGIN)

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

    function M.currentCapState()
        local nowSeconds = os.time()
        if nowSeconds < cachedCapState.ExpiresAt then
            return cachedCapState
        end

        local level = nil
        local expToNextLevel = nil
        if LEVEL_CAP > 0 then
            level = M.currentPlayerLevel()
            if level ~= nil and level == LEVEL_CAP - 1 then
                expToNextLevel = M.currentExpToNextLevel()
            end
        end

        local talentPoints, talentPointsKind = nil, nil
        if TALENT_POINTS_CAP > 0 then
            talentPoints, talentPointsKind = M.currentTalentPoints()
        end

        local cacheWindowMs = capWindowForState(level, talentPoints)
        cachedCapState = {
            ExpiresAt        = nowSeconds + math.max(1, math.floor(cacheWindowMs / 1000)),
            Level            = level,
            ExpToNextLevel   = expToNextLevel,
            TalentPoints     = talentPoints,
            TalentPointsKind = talentPointsKind,
        }

        return cachedCapState
    end

    function M.adjustExpForCaps(amount, reason)
        local adjustedAmount = amount
        local capState = M.currentCapState()

        if LEVEL_CAP > 0 then
            local currentLevel = capState.Level
            if currentLevel ~= nil then
                if currentLevel >= LEVEL_CAP then
                    logCap(loc("cap_level_reached", LEVEL_CAP, currentLevel))
                    return 0
                end

                if currentLevel == LEVEL_CAP - 1 then
                    local expToNext = capState.ExpToNextLevel
                    if expToNext ~= nil and expToNext > 0 and adjustedAmount > expToNext then
                        logCap(loc("cap_level_cut", LEVEL_CAP, adjustedAmount, expToNext,
                            tostring(reason or loc("unknown"))))
                        adjustedAmount = expToNext
                    end
                end
            end
        end

        if TALENT_POINTS_CAP > 0 then
            local talentPoints = capState.TalentPoints
            if talentPoints ~= nil and talentPoints >= TALENT_POINTS_CAP then
                logCap(loc("cap_talent_reached", TALENT_POINTS_CAP, talentPoints,
                    tostring(capState.TalentPointsKind or loc("unknown"))))
                return 0
            end
        end

        return adjustedAmount
    end

    -- Returns true when the objects that are most expensive to cold-look-up via
    -- FindFirstOf (ProgressionObserver, TalentTreeVM, ScenarioExecutor) are all
    -- cached, meaning the prewarm succeeded and the first kill will be hitch-free.
    function M.isWarmed()
        return isValid(cachedProgressionObserver)
            and isValid(cachedTalentTreeVM)
            and isValid(cachedScenarioExecutor)
    end

    function M.primaryWorldContext()
        local candidates = {
            M.currentScenarioComponent,
            M.currentPlayerCharacter,
            M.currentPlayerState,
            M.currentPlayerController,
        }

        for _, getter in ipairs(candidates) do
            local obj = getter()
            if isValid(obj) then
                return obj
            end
        end

        local ok, gameInstance = false, nil

        if UEHelpers ~= nil and type(UEHelpers.GetGameInstance) == "function" then
            ok, gameInstance = pcall(function()
                return UEHelpers.GetGameInstance()
            end)
        end

        if ok and isValid(gameInstance) then
            return gameInstance
        end

        ok, gameInstance = pcall(FindFirstOf, "R5GameInstance")
        if ok and isValid(gameInstance) then
            return gameInstance
        end

        return nil
    end

    return M
end

return makeCache
