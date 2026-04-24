-- ue_util.lua
-- Pure UE4SS object helpers. No game-specific or mod-specific logic.
-- Returns a table of functions. Call with: local UU = dofile("...ue_util.lua")

local unpackArgs = table.unpack or unpack

local M = {}

local function isUnrealParam(value)
    return value ~= nil and string.find(tostring(value), "UnrealParam", 1, true) ~= nil
end

function M.unwrap(value)
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

local unwrap = M.unwrap

function M.isObjectLike(value)
    local raw = unwrap(value)
    if raw == nil then
        return false
    end

    local valueType = type(raw)
    return valueType == "userdata" or valueType == "table"
end

function M.isValid(value)
    local raw = unwrap(value)
    if raw == nil or not M.isObjectLike(raw) then
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

local isValid = M.isValid

function M.safeRead(object, field)
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

function M.safeCall(object, method, ...)
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

function M.safeRawCall(raw, method)
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

function M.isTrue(value)
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

function M.asNumber(value)
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

function M.safeNumberCall(object, method)
    local ok, result = M.safeCall(object, method)
    if ok then
        return M.asNumber(result)
    end

    return nil
end

function M.safeStaticFind(path)
    local ok, object = pcall(StaticFindObject, path)
    if ok and object ~= nil and isValid(object) then
        return object
    end

    return nil
end

function M.safeFindFirst(className)
    local ok, object = pcall(FindFirstOf, className)
    if ok and object ~= nil and isValid(object) then
        return object
    end

    return nil
end

function M.rawObjectAddress(raw)
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

function M.objectAddress(object)
    local raw = unwrap(object)
    if raw == nil or not isValid(raw) then
        return nil
    end

    return M.rawObjectAddress(raw)
end

function M.sameObject(left, right)
    local leftAddress = M.objectAddress(left)
    local rightAddress = M.objectAddress(right)

    if leftAddress ~= nil and rightAddress ~= nil then
        return leftAddress == rightAddress
    end

    return unwrap(left) == unwrap(right)
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

function M.objectText(object)
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

function M.objectDebugName(object)
    local address = M.objectAddress(object)
    local text = M.objectText(object)

    if address ~= nil and text ~= nil and text ~= "" then
        return tostring(text) .. " @" .. tostring(address)
    end

    if text ~= nil and text ~= "" then
        return tostring(text)
    end

    if address ~= nil and address ~= "" then
        return "@" .. tostring(address)
    end

    return "<nil>"
end

return M
