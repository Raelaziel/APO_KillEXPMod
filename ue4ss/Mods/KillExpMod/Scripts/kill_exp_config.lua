local Config = {}

local function stripJsonComments(text)
    local out = {}
    local i = 1
    local len = #text
    local inString = false
    local escaped = false

    while i <= len do
        local c = string.sub(text, i, i)
        local nextChar = string.sub(text, i + 1, i + 1)

        if inString then
            out[#out + 1] = c
            if escaped then
                escaped = false
            elseif c == "\\" then
                escaped = true
            elseif c == "\"" then
                inString = false
            end
            i = i + 1
        elseif c == "\"" then
            inString = true
            out[#out + 1] = c
            i = i + 1
        elseif c == "/" and nextChar == "/" then
            i = i + 2
            while i <= len do
                c = string.sub(text, i, i)
                if c == "\n" or c == "\r" then
                    out[#out + 1] = c
                    break
                end
                i = i + 1
            end
        elseif c == "/" and nextChar == "*" then
            i = i + 2
            while i <= len do
                c = string.sub(text, i, i)
                nextChar = string.sub(text, i + 1, i + 1)
                if c == "\n" or c == "\r" then
                    out[#out + 1] = c
                end
                if c == "*" and nextChar == "/" then
                    i = i + 2
                    break
                end
                i = i + 1
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end

    return table.concat(out)
end

local Json = {}
Json.__index = Json

local function newJsonParser(text)
    local cleaned = stripJsonComments(text or "")
    return setmetatable({
        text = cleaned,
        index = 1,
        length = #cleaned,
    }, Json)
end

function Json:peek()
    return string.sub(self.text, self.index, self.index)
end

function Json:next()
    local c = self:peek()
    self.index = self.index + 1
    return c
end

function Json:error(message)
    error(string.format("%s at character %d", message, self.index), 0)
end

function Json:skipWhitespace()
    while self.index <= self.length do
        local c = self:peek()
        if c ~= " " and c ~= "\t" and c ~= "\n" and c ~= "\r" then
            return
        end
        self.index = self.index + 1
    end
end

function Json:expectLiteral(literal, value)
    if string.sub(self.text, self.index, self.index + #literal - 1) ~= literal then
        self:error("Expected '" .. literal .. "'")
    end
    self.index = self.index + #literal
    return value
end

function Json:parseString()
    if self:next() ~= "\"" then
        self:error("Expected string")
    end

    local out = {}
    while self.index <= self.length do
        local c = self:next()
        if c == "\"" then
            return table.concat(out)
        end

        if c == "\\" then
            local escape = self:next()
            if escape == "\"" or escape == "\\" or escape == "/" then
                out[#out + 1] = escape
            elseif escape == "b" then
                out[#out + 1] = "\b"
            elseif escape == "f" then
                out[#out + 1] = "\f"
            elseif escape == "n" then
                out[#out + 1] = "\n"
            elseif escape == "r" then
                out[#out + 1] = "\r"
            elseif escape == "t" then
                out[#out + 1] = "\t"
            elseif escape == "u" then
                local hex = string.sub(self.text, self.index, self.index + 3)
                if not string.match(hex, "^%x%x%x%x$") then
                    self:error("Invalid unicode escape")
                end
                local code = tonumber(hex, 16)
                self.index = self.index + 4
                out[#out + 1] = code and code < 128 and string.char(code) or "?"
            else
                self:error("Invalid escape sequence")
            end
        else
            out[#out + 1] = c
        end
    end

    self:error("Unterminated string")
end

function Json:parseNumber()
    local startIndex = self.index
    local c = self:peek()

    if c == "-" then
        self.index = self.index + 1
    end

    while string.match(self:peek(), "%d") do
        self.index = self.index + 1
    end

    if self:peek() == "." then
        self.index = self.index + 1
        while string.match(self:peek(), "%d") do
            self.index = self.index + 1
        end
    end

    c = self:peek()
    if c == "e" or c == "E" then
        self.index = self.index + 1
        c = self:peek()
        if c == "+" or c == "-" then
            self.index = self.index + 1
        end
        while string.match(self:peek(), "%d") do
            self.index = self.index + 1
        end
    end

    local raw = string.sub(self.text, startIndex, self.index - 1)
    local number = tonumber(raw)
    if number == nil then
        self:error("Invalid number")
    end

    return number
end

function Json:parseArray()
    self:next()
    local result = {}
    self:skipWhitespace()

    if self:peek() == "]" then
        self:next()
        return result
    end

    while true do
        result[#result + 1] = self:parseValue()
        self:skipWhitespace()

        local c = self:next()
        if c == "]" then
            return result
        end

        if c ~= "," then
            self:error("Expected ',' or ']'")
        end

        self:skipWhitespace()
        if self:peek() == "]" then
            self:next()
            return result
        end
    end
end

function Json:parseObject()
    self:next()
    local result = {}
    self:skipWhitespace()

    if self:peek() == "}" then
        self:next()
        return result
    end

    while true do
        self:skipWhitespace()
        if self:peek() ~= "\"" then
            self:error("Expected object key")
        end

        local key = self:parseString()
        self:skipWhitespace()
        if self:next() ~= ":" then
            self:error("Expected ':'")
        end

        result[key] = self:parseValue()
        self:skipWhitespace()

        local c = self:next()
        if c == "}" then
            return result
        end

        if c ~= "," then
            self:error("Expected ',' or '}'")
        end

        self:skipWhitespace()
        if self:peek() == "}" then
            self:next()
            return result
        end
    end
end

function Json:parseValue()
    self:skipWhitespace()
    local c = self:peek()

    if c == "\"" then
        return self:parseString()
    elseif c == "{" then
        return self:parseObject()
    elseif c == "[" then
        return self:parseArray()
    elseif c == "t" then
        return self:expectLiteral("true", true)
    elseif c == "f" then
        return self:expectLiteral("false", false)
    elseif c == "n" then
        return self:expectLiteral("null", nil)
    elseif c == "-" or string.match(c, "%d") then
        return self:parseNumber()
    end

    self:error("Unexpected value")
end

local function decodeJson(text)
    local parser = newJsonParser(text)
    local value = parser:parseValue()
    parser:skipWhitespace()

    if parser.index <= parser.length then
        parser:error("Unexpected trailing data")
    end

    return value
end

local function readTextFile(path)
    local file = io.open(path, "rb")
    if file == nil then
        return nil
    end

    local text = file:read("*a")
    file:close()
    return text
end

local function readFirst(paths)
    for _, path in ipairs(paths) do
        local text = readTextFile(path)
        if text ~= nil then
            return path, text
        end
    end

    return nil, nil
end

local function asNumber(value)
    if type(value) == "number" then
        return value
    end
    return tonumber(tostring(value))
end

local function normalizeRule(rawRule, index)
    if type(rawRule) ~= "table" then
        return nil, string.format("Rule #%d is not an object.", index)
    end

    if rawRule.enabled == false then
        return nil, nil
    end

    local pattern = rawRule.pattern or rawRule.Pattern
    local exp = asNumber(rawRule.exp or rawRule.Exp)

    if type(pattern) ~= "string" or pattern == "" then
        return nil, string.format("Rule #%d is missing a pattern.", index)
    end

    if exp == nil then
        return nil, string.format("Rule #%d is missing a numeric exp value.", index)
    end

    return {
        Pattern = pattern,
        Exp = math.floor(exp),
        Note = rawRule.note or rawRule.name or rawRule.group,
    }, nil
end

local function normalizeConfig(data, path)
    if type(data) ~= "table" then
        return nil, "Config root must be an object."
    end

    local rawRules = data.rules or data.exp_rules
    if type(rawRules) ~= "table" then
        return nil, "Config must contain a 'rules' array."
    end

    local rules = {}
    local warnings = {}

    for index, rawRule in ipairs(rawRules) do
        local rule, warning = normalizeRule(rawRule, index)
        if rule ~= nil then
            rules[#rules + 1] = rule
        elseif warning ~= nil then
            warnings[#warnings + 1] = warning
        end
    end

    return {
        Path = path,
        Settings = data.settings or {},
        Rules = rules,
        Warnings = warnings,
    }, nil
end

function Config.load(paths)
    local path, text = readFirst(paths)
    if path == nil then
        return nil, "Could not find exp_rules.json."
    end

    local ok, dataOrError = pcall(decodeJson, text)
    if not ok then
        return nil, "Could not parse " .. path .. ": " .. tostring(dataOrError)
    end

    local config, errorMessage = normalizeConfig(dataOrError, path)
    if config == nil then
        return nil, errorMessage
    end

    return config, nil
end

return Config
