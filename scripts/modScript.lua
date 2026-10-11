-- AutopilotLive — штатная точка входа мода (точка входа GE-слоя)
-- Исполняется core/modmanager.lua при старте игры:
--   modmanager ищет 'scripts/modScript.lua' по всему VFS (включая unpacked-моды)
--   и запускает через pcall(dofile, ...). См. modmanager.lua:704.
-- Пока исполняются modScript'ы, extensions.load сам ставит unloadMode="manual"
-- (modmanager.lua:697-702), так что расширение переживёт смену карты.

extensions.load('autopilotLive/main')
