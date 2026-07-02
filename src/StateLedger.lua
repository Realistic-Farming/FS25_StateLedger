-- =========================================================
-- FS25_StateLedger - core class
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Disk I/O bedrock for the Realistic Farming ecosystem. Collapses every
-- companion mod's save into one atomic master XML write and one atomic
-- load, so a force-quit mid-save can no longer corrupt the later mods'
-- separate files.
--
-- Companion mods never write their own ecosystem-state file. They call
--   g_stateLedger:registerModule(name, { serialize = fn, deserialize = fn })
-- once at init, and receive their data (or nil on a new save) via
-- deserialize.
--
-- Lifecycle (order-independent by design):
--   * A module may register BEFORE or AFTER the master file is parsed.
--   * parseFile() reads the master file once (server only) and caches it.
--   * Each registered module is DELIVERED exactly once: at parse time if
--     already registered, or at registration time if parse already ran.
--   * save() (server only) calls every module's serialize and writes the
--     single master file inside the game save window.
-- =========================================================

StateLedger = {}
local StateLedger_mt = Class(StateLedger)

StateLedger.SAVE_VERSION = 1
StateLedger.SAVE_FILE    = "RealisticFarming_MasterState.xml"

function StateLedger.new()
    local self = setmetatable({}, StateLedger_mt)

    self.registrations = {}   -- name -> { serialize = fn, deserialize = fn }
    self.registerOrder = {}   -- ordered list of names (stable save/deliver order)
    self.parsedData    = {}   -- name -> stateTable, populated by parseFile
    self.deliveredTo   = {}   -- name -> true once deserialize has run
    self.hasParsed     = false
    self.loadedVersion = nil

    return self
end

-- =========================================================
-- Registration
-- =========================================================

---@param name string  unique module id, e.g. "WorkerCosts_Roster"
---@param hooks table   { serialize = function()->table, deserialize = function(table|nil) }
---@return boolean success
function StateLedger:registerModule(name, hooks)
    if type(name) ~= "string" or name == "" then
        SLLogger.warning("registerModule: invalid module name '%s', ignoring", tostring(name))
        return false
    end
    if type(hooks) ~= "table"
        or type(hooks.serialize) ~= "function"
        or type(hooks.deserialize) ~= "function" then
        SLLogger.warning("registerModule('%s'): needs { serialize = fn, deserialize = fn }, ignoring", name)
        return false
    end
    if self.registrations[name] ~= nil then
        SLLogger.warning("registerModule('%s'): already registered, overwriting the previous callbacks", name)
    else
        table.insert(self.registerOrder, name)
    end

    self.registrations[name] = hooks
    SLLogger.debug("Registered module '%s'", name)

    -- If the master file has already been parsed, this module registered
    -- late; deliver its data now so it never misses its load.
    if self.hasParsed then
        self:_deliver(name)
    end

    return true
end

-- Deliver a single module's parsed data (or nil) via its deserialize
-- callback, exactly once. Wrapped in pcall so one bad module cannot take
-- down the load for the others.
function StateLedger:_deliver(name)
    if self.deliveredTo[name] then
        return
    end
    local hooks = self.registrations[name]
    if hooks == nil then
        return
    end
    self.deliveredTo[name] = true

    local data = self.parsedData[name] -- nil on a brand-new save

    local ok, err = pcall(hooks.deserialize, data)
    if not ok then
        SLLogger.error("deserialize failed for '%s': %s", name, tostring(err))
    else
        SLLogger.debug("Delivered state to '%s' (%s)", name, data ~= nil and "resume" or "defaults")
    end
end

-- =========================================================
-- Load
-- =========================================================

-- Resolve the master save file path from the mission savegame directory.
-- Returns nil when there is no savegame directory (e.g. a pure MP client),
-- in which case there is nothing to load and nothing to save.
function StateLedger:getSaveFilePath()
    if g_currentMission == nil
        or g_currentMission.missionInfo == nil
        or g_currentMission.missionInfo.savegameDirectory == nil then
        return nil
    end
    return g_currentMission.missionInfo.savegameDirectory .. "/" .. StateLedger.SAVE_FILE
end

-- Parse the master file once and deliver to every registered module.
-- Safe to call when no file exists (new save): every module receives nil
-- and initializes its own defaults. Idempotent.
function StateLedger:parseFile()
    if self.hasParsed then
        return
    end

    local path = self:getSaveFilePath()
    local parsed, version = StateLedgerXML.readMasterFile(path)
    self.parsedData    = parsed or {}
    self.loadedVersion = version
    self.hasParsed     = true

    local count = 0
    for _ in pairs(self.parsedData) do count = count + 1 end
    SLLogger.info("Master state parsed (%d module block(s), saveVersion %s)",
        count, tostring(version))

    -- Deliver in registration order for deterministic behavior.
    for _, name in ipairs(self.registerOrder) do
        self:_deliver(name)
    end
end

-- Called from the mission-loaded hook.
function StateLedger:onMissionLoaded()
    self:parseFile()
end

-- =========================================================
-- Save
-- =========================================================

-- Collect every module's serialize() output and write the single master
-- file. Server only: the master file is server-shared state and lives on
-- the host's disk. Per-player local prefs do NOT belong here.
function StateLedger:save()
    if g_currentMission == nil or not g_currentMission:getIsServer() then
        return
    end

    local path = self:getSaveFilePath()
    if path == nil then
        SLLogger.warning("save skipped: no savegame directory available")
        return
    end

    local moduleData = {}
    local saved = 0
    for _, name in ipairs(self.registerOrder) do
        local hooks = self.registrations[name]
        if hooks ~= nil then
            local ok, result = pcall(hooks.serialize)
            if not ok then
                SLLogger.error("serialize failed for '%s': %s (block omitted this save)", name, tostring(result))
            elseif type(result) ~= "table" then
                SLLogger.warning("serialize for '%s' returned %s, expected table (block omitted)", name, type(result))
            else
                moduleData[name] = result
                saved = saved + 1
            end
        end
    end

    local ok = StateLedgerXML.writeMasterFile(path, StateLedger.SAVE_VERSION, moduleData)
    if ok then
        SLLogger.info("Master state saved (%d module block(s))", saved)
    end
end

-- =========================================================
-- Introspection (console command support)
-- =========================================================

function StateLedger:getStatus()
    local lines = {}
    table.insert(lines, string.format("StateLedger: %d module(s) registered, parsed=%s, saveVersion=%d",
        #self.registerOrder, tostring(self.hasParsed), StateLedger.SAVE_VERSION))
    for _, name in ipairs(self.registerOrder) do
        local hasData = self.parsedData[name] ~= nil
        table.insert(lines, string.format("  - %s (delivered=%s, loadedData=%s)",
            name, tostring(self.deliveredTo[name] == true), tostring(hasData)))
    end
    return table.concat(lines, "\n")
end

-- Console command target: `slStatus`. addConsoleCommand calls this as
-- self:consoleCommandStatus(), so it must be a method on the instance.
function StateLedger:consoleCommandStatus()
    return self:getStatus()
end
