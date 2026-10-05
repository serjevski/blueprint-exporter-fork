-- Handler on_tick jest zarejestrowany zawsze (bez aktywnego zadania to tani
-- early-return) — warunkowa rejestracja zależna od storage wymagałaby
-- odtwarzania w on_load i groziłaby desyncem. Stan eksportu żyje w storage.job.
-- W multiplayerze Lua wykonuje się na każdym kliencie, ale write_file
-- z for_player pisze tylko na maszynie gracza, który kliknął.
local Export = require("scripts.export")

script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name ~= "blueprint-exporter-export" then return end
  local player = game.get_player(event.player_index)
  if player then
    Export.start(player)
  end
end)

script.on_event(defines.events.on_tick, function()
  Export.process()
end)
