-- =========================================================
-- FS25_StateLedger - StateLedgerXML
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Generic Lua-table <-> XML serialization over the FS25 XMLFile
-- object API (XMLFile.create / XMLFile.load, xml:setString / getString /
-- setBool / getBool / save / delete).
--
-- A companion module hands StateLedger a plain Lua table from its
-- serialize() callback. We must round-trip ANY such table (nested,
-- mixed string/number keys, arrays, scalars) back to an identical table
-- for deserialize(). We do NOT know the shape ahead of time, so instead
-- of a fixed schema we write a self-describing entry list:
--
--   <basePath n="3">
--     <e k="nitrogen" kt="s" t="num" v="42.5"/>
--     <e k="1"        kt="n" t="str" v="wheat"/>
--     <e k="fields"   kt="s" t="table" n="2"> ... nested e(i) ... </e>
--   </basePath>
--
-- Numbers are stored as %.17g strings so a Lua double round-trips
-- exactly (Lua 5.1 has no int/float split; every number is a double).
-- Key type (kt) is preserved so a number key 5 and a string key "5"
-- stay distinct. Booleans and strings use their own type tags.
-- =========================================================

StateLedgerXML = {}

-- Guard against pathological input. Plain state tables are shallow;
-- anything past this depth is almost certainly a cycle or a bug.
StateLedgerXML.MAX_DEPTH = 64

local VALUE_TYPES = { num = true, str = true, bool = true, table = true }

-- Format a Lua number as a string that reconstructs to the exact same
-- double. Non-finite values (NaN / +-inf) cannot survive a round-trip,
-- so they are coerced to 0 and reported by the caller-visible warning.
local function numberToString(n)
    if n ~= n or n == math.huge or n == -math.huge then
        return nil -- signal non-finite to the caller
    end
    return string.format("%.17g", n)
end

-- Recursively write `tbl` as an entry list under `basePath`.
-- `visited` guards against cyclic references; `depth` bounds nesting.
-- Returns the number of entries written.
function StateLedgerXML._writeTable(xml, basePath, tbl, visited, depth)
    if depth > StateLedgerXML.MAX_DEPTH then
        SLLogger.warning("serialize: max depth %d exceeded at '%s', truncating",
            StateLedgerXML.MAX_DEPTH, basePath)
        xml:setInt(basePath .. "#n", 0)
        return 0
    end
    if visited[tbl] then
        SLLogger.warning("serialize: cyclic table reference at '%s', truncating", basePath)
        xml:setInt(basePath .. "#n", 0)
        return 0
    end
    visited[tbl] = true

    local index = 0
    for k, v in pairs(tbl) do
        local keyType = type(k)
        local valType = type(v)
        local writable = (keyType == "string" or keyType == "number")
            and (valType == "string" or valType == "number"
                 or valType == "boolean" or valType == "table")

        if not writable then
            SLLogger.warning("serialize: skipping unsupported entry (key %s, value %s) at '%s'",
                keyType, valType, basePath)
        else
            local ePath = string.format("%s.e(%d)", basePath, index)
            xml:setString(ePath .. "#k", tostring(k))
            xml:setString(ePath .. "#kt", keyType == "number" and "n" or "s")

            if valType == "table" then
                xml:setString(ePath .. "#t", "table")
                StateLedgerXML._writeTable(xml, ePath, v, visited, depth + 1)
            elseif valType == "number" then
                local s = numberToString(v)
                if s == nil then
                    SLLogger.warning("serialize: non-finite number at '%s#%s', storing 0", basePath, tostring(k))
                    s = "0"
                end
                xml:setString(ePath .. "#t", "num")
                xml:setString(ePath .. "#v", s)
            elseif valType == "boolean" then
                xml:setString(ePath .. "#t", "bool")
                xml:setBool(ePath .. "#v", v)
            else -- string
                xml:setString(ePath .. "#t", "str")
                xml:setString(ePath .. "#v", v)
            end

            index = index + 1
        end
    end

    xml:setInt(basePath .. "#n", index)
    visited[tbl] = nil -- allow the same table to appear in a sibling branch
    return index
end

-- Recursively read the entry list written under `basePath` back into a
-- Lua table. Missing / malformed nodes yield an empty table rather than
-- an error, so a corrupt block degrades to defaults instead of crashing.
function StateLedgerXML._readTable(xml, basePath, depth)
    local result = {}
    if depth > StateLedgerXML.MAX_DEPTH then
        return result
    end

    local n = xml:getInt(basePath .. "#n", 0) or 0
    for i = 0, n - 1 do
        local ePath = string.format("%s.e(%d)", basePath, i)
        local kStr = xml:getString(ePath .. "#k")
        local kt   = xml:getString(ePath .. "#kt")
        local t    = xml:getString(ePath .. "#t")

        if kStr ~= nil and VALUE_TYPES[t] then
            local key
            if kt == "n" then
                key = tonumber(kStr)
            else
                key = kStr
            end

            if key ~= nil then
                local value
                if t == "table" then
                    value = StateLedgerXML._readTable(xml, ePath, depth + 1)
                elseif t == "num" then
                    value = tonumber(xml:getString(ePath .. "#v")) or 0
                elseif t == "bool" then
                    value = xml:getBool(ePath .. "#v", false)
                else -- str
                    value = xml:getString(ePath .. "#v") or ""
                end
                result[key] = value
            end
        end
    end

    return result
end

-- Public: write a map of { moduleName -> stateTable } to a fresh master
-- XML file at `filePath`. Each module becomes one <module> block so a
-- corrupt or oddly-named module id cannot collide with the XML schema.
-- Returns true on success.
function StateLedgerXML.writeMasterFile(filePath, saveVersion, moduleData)
    local xml = XMLFile.create("StateLedger_Master", filePath, "RealisticFarming")
    if xml == nil then
        SLLogger.error("Could not create master save file at '%s'", tostring(filePath))
        return false
    end

    xml:setInt("RealisticFarming#saveVersion", saveVersion)

    local moduleIndex = 0
    for moduleName, stateTable in pairs(moduleData) do
        local blockPath = string.format("RealisticFarming.module(%d)", moduleIndex)
        xml:setString(blockPath .. "#name", moduleName)
        StateLedgerXML._writeTable(xml, blockPath, stateTable, {}, 1)
        moduleIndex = moduleIndex + 1
    end
    xml:setInt("RealisticFarming#moduleCount", moduleIndex)

    xml:save()
    xml:delete()
    return true
end

-- Public: read the master file at `filePath`. Returns
--   parsedByModule  = { moduleName -> stateTable }  (empty table if no file)
--   saveVersion     = integer from the root, or nil if no file
-- A missing file (first-ever save) returns ({}, nil) with no error.
function StateLedgerXML.readMasterFile(filePath)
    if filePath == nil or not fileExists(filePath) then
        return {}, nil
    end

    local xml = XMLFile.loadIfExists("StateLedger_Master", filePath)
    if xml == nil then
        SLLogger.warning("Master save file present but could not be loaded: '%s'", tostring(filePath))
        return {}, nil
    end

    local saveVersion = xml:getInt("RealisticFarming#saveVersion", 1)
    local moduleCount = xml:getInt("RealisticFarming#moduleCount", 0) or 0

    local parsedByModule = {}
    for i = 0, moduleCount - 1 do
        local blockPath = string.format("RealisticFarming.module(%d)", i)
        local name = xml:getString(blockPath .. "#name")
        if name ~= nil and name ~= "" then
            parsedByModule[name] = StateLedgerXML._readTable(xml, blockPath, 1)
        end
    end

    xml:delete()
    return parsedByModule, saveVersion
end
