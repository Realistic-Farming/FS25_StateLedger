-- =========================================================
-- FS25_StateLedger - mod entry point
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Loads the StateLedger modules, publishes the g_stateLedger handle, and
-- hooks the FS25 mission lifecycle:
--   Mission00.load                     -> publish the cross-mod bridge handle
--   Mission00.loadMission00Finished    -> parse the master save file + deliver
--   FSCareerMissionInfo.saveToXMLFile  -> write the single master save file
--   FSBaseMission.delete               -> drop the handle
--
-- Load order: StateLedger is mod 1 in the ecosystem. The handle is
-- published as soon as this file runs so companion mods that load after
-- it can call registerModule during their own module load, before the
-- mission exists.
-- =========================================================

local modDirectory = g_currentModDirectory
local modName      = g_currentModName

source(modDirectory .. "src/Logger.lua")
source(modDirectory .. "src/StateLedgerXML.lua")
source(modDirectory .. "src/StateLedger.lua")

-- Create the instance and publish the handle immediately (before any
-- mission hook), so early companion registrations are never missed.
local stateLedger = StateLedger.new()
getfenv(0)["g_stateLedger"] = stateLedger

-- ---------------------------------------------------------
-- Mission lifecycle hooks
-- ---------------------------------------------------------

local function onMissionLoad(mission)
    -- g_currentMission is a shared C++ object visible to all mods, unlike
    -- getfenv(0) which is per-mod scoped. Publish the cross-mod bridge here.
    if mission ~= nil then
        mission.stateLedger = stateLedger
    end
    SLLogger.info("StateLedger active (mod 1, save bedrock)")
end

local function onMissionLoadedFinished()
    stateLedger:onMissionLoaded()
end

local function onMissionSave()
    stateLedger:save()
end

local function onMissionDelete()
    getfenv(0)["g_stateLedger"] = nil
    if g_currentMission ~= nil then
        g_currentMission.stateLedger = nil
    end
end

-- appendedFunction so the base game's own handler runs first.
Mission00.load = Utils.appendedFunction(Mission00.load, onMissionLoad)
Mission00.loadMission00Finished = Utils.appendedFunction(Mission00.loadMission00Finished, onMissionLoadedFinished)

-- Save via FSCareerMissionInfo:saveToXMLFile, the window where
-- savegameDirectory points at the tempsavegame that FS25 then copies over
-- the real savegame. Hooking the non-existent Mission00.saveToXMLFile is a
-- known trap that silently never fires.
if FSCareerMissionInfo ~= nil and FSCareerMissionInfo.saveToXMLFile ~= nil then
    FSCareerMissionInfo.saveToXMLFile = Utils.appendedFunction(
        FSCareerMissionInfo.saveToXMLFile,
        function() onMissionSave() end
    )
else
    SLLogger.warning("FSCareerMissionInfo.saveToXMLFile not found - master state will NOT be saved")
end

FSBaseMission.delete = Utils.prependedFunction(FSBaseMission.delete, onMissionDelete)

-- ---------------------------------------------------------
-- Console command: slStatus (target + method, the proven pattern)
-- ---------------------------------------------------------

if addConsoleCommand ~= nil then
    addConsoleCommand("slStatus", "Show StateLedger registered modules and load state",
        "consoleCommandStatus", stateLedger)
end
