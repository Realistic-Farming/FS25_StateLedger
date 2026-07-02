-- =========================================================
-- FS25_StateLedger - Logger
-- =========================================================
-- Author: TisonK
-- =========================================================
-- Small logging helper with a mod prefix and a debug gate.
-- Pattern mirrors the other Realistic Farming mods so log lines
-- are greppable by the "[StateLedger]" tag.
-- =========================================================

SLLogger = {}
SLLogger.PREFIX = "[StateLedger] "
SLLogger.debugEnabled = false

function SLLogger.info(msg, ...)
    if select("#", ...) > 0 then
        Logging.info(SLLogger.PREFIX .. msg, ...)
    else
        Logging.info(SLLogger.PREFIX .. msg)
    end
end

function SLLogger.warning(msg, ...)
    if select("#", ...) > 0 then
        Logging.warning(SLLogger.PREFIX .. msg, ...)
    else
        Logging.warning(SLLogger.PREFIX .. msg)
    end
end

function SLLogger.error(msg, ...)
    if select("#", ...) > 0 then
        Logging.error(SLLogger.PREFIX .. msg, ...)
    else
        Logging.error(SLLogger.PREFIX .. msg)
    end
end

function SLLogger.debug(msg, ...)
    if not SLLogger.debugEnabled then
        return
    end
    if select("#", ...) > 0 then
        Logging.info(SLLogger.PREFIX .. "[debug] " .. msg, ...)
    else
        Logging.info(SLLogger.PREFIX .. "[debug] " .. msg)
    end
end
