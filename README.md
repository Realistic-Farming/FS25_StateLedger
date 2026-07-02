# FS25_StateLedger

**Version:** 1.0.0.0
**Author:** TisonK

The disk I/O bedrock of the Realistic Farming mod ecosystem. StateLedger is mod 1 in the load order: it collapses every companion mod's savegame data into one atomic XML write and one atomic load. Without it, each mod writes its own file in one save window, and a crash or force-quit mid-window can corrupt the later files and lose progression permanently. StateLedger removes that failure mode by batching everything into a single file.

There are no settings and nothing to configure. Install it, keep it loaded, and let the companion mods use it.

## How companion mods use it

Register once, at init, guarding against StateLedger being absent:

```lua
if g_stateLedger then
    g_stateLedger:registerModule("MyMod_State", {
        serialize   = function()      return self:getStateTable() end,   -- return a plain table
        deserialize = function(data)  self:applyState(data) end,         -- data is nil on a new save
    })
end
```

- **serialize** returns a plain Lua table (strings, numbers, booleans, nested tables). No handles, closures, or userdata. It runs inside the save window, so keep it fast. Called inside `pcall`; if it errors, that block is omitted and every other mod still saves.
- **deserialize** receives the exact table `serialize` returned on a resume, or `nil` on a brand-new save. It must handle `nil` by initializing defaults. Also called inside `pcall`.

A mod may register more than one module for schema isolation (for example a roster and a hire-hall kept in separate blocks), so a bad write in one cannot corrupt the other.

Registration works before or after the master file is parsed: each module is delivered its data exactly once, whichever order things load in.

## What it does NOT handle

Per-player local settings (HUD position, transparency, font size) are player-scoped and must not go through StateLedger, they would overwrite every player's local prefs with the last writer's values. Those stay in each mod's own local file (or in SettingsHub if per-player scope is added there).

## Save file

`<savegameDirectory>/RealisticFarming_MasterState.xml`, one `<module>` block per registered mod, written by the server only inside the `FSCareerMissionInfo:saveToXMLFile` hook. The root carries an integer `saveVersion`; per-mod schema versions live inside each mod's own state table (`data._version`).

## Console

- `slStatus` - list registered modules and their load state.
