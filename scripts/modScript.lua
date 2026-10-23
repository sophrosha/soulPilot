-- AutopilotLive — штатная точка входа мода (точка входа GE-слоя)
-- Исполняется core/modmanager.lua при старте игры:
--   modmanager ищет 'scripts/modScript.lua' по всему VFS (включая unpacked-моды)
--   и запускает через pcall(dofile, ...). См. modmanager.lua:704.
-- Пока исполняются modScript'ы, extensions.load сам ставит unloadMode="manual"
-- (modmanager.lua:697-702), так что расширение переживёт смену карты.

extensions.load('autopilotLive/main')

-- Фаза 10.2: бинды по умолчанию (Ctrl+Shift+A/P/W/U).
-- Пишем ОТДЕЛЬНЫЙ файл keyboard_apl.diff (не трогаем keyboard.diff пользователя):
-- loader сканирует settings/inputmaps по префиксу клавиатуры и объединяет файлы.
local function ensureDefaultBinds()
  local path = 'settings/inputmaps/keyboard_apl.diff'
  local exists = io.open(path, 'r')
  if exists then exists:close() return end
  local json = '{\n  "bindings": [\n' ..
    '    { "action": "apl_toggle_autopilot", "control": "ctrl shift a" },\n' ..
    '    { "action": "apl_pet_toggle",      "control": "ctrl shift p" },\n' ..
    '    { "action": "apl_warmup_toggle",   "control": "ctrl shift w" },\n' ..
    '    { "action": "apl_ui_toggle",       "control": "ctrl shift u" }\n' ..
    '  ]\n}\n'
  local f = io.open(path, 'w')
  if f then
    f:write(json)
    f:close()
    print('[AutopilotLive] Бинды по умолчанию записаны: Ctrl+Shift+A/P/W/U (settings/inputmaps/keyboard_apl.diff)')
  else
    print('[AutopilotLive] WARN не удалось записать settings/inputmaps/keyboard_apl.diff — назначьте клавиши в Options > Controls')
  end
end
pcall(ensureDefaultBinds)
