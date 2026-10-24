# Установка soulPilot

## Установка релиза

1. Соберите или скачайте `soulPilot-<version>.zip`.
2. Откройте в BeamNG **Mods → Open Mods Folder** или скопируйте zip в:

```text
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\mods\
```

3. Включите **soulPilot** в Mod Manager.
4. Полностью перезапустите BeamNG.
5. Заспавните машину и откройте HUD-приложение soulPilot или используйте консоль.

Правильный архив имеет runtime-папки в корне:

```text
soulPilot-<version>.zip
├─ lua/
├─ ui/
├─ mod_info/
├─ art/
├─ config/
├─ scripts/
└─ src_music/
```

Если внутри zip есть верхняя папка `src/`, архив собран старой версией скрипта и игра его не загрузит.

## Установка для разработки

Исходники лежат в `src/`, но BeamNG ожидает runtime-папки прямо в корне распакованного мода.

```powershell
Set-Location "C:\Users\<вы>\AppData\Local\BeamNG\BeamNG.drive\current\mods\unpacked\soulPilot"
python ai/dev_mode.py
```

`dev_mode.py` копирует:

```text
src/lua       -> lua
src/ui        -> ui
src/mod_info  -> mod_info
src/art       -> art
src/config    -> config
```

Также проверяются/копируются `scripts/`, `locales/` и `src_music/`, если их исходники лежат в `src/`. В текущем репозитории эти три папки уже находятся в корне — это допустимый вариант.

## Удаление старого мода и кеша

Перед первым запуском после миграции:

```powershell
Remove-Item -Recurse -Force "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current\mods\unpacked\AutopilotLive" -ErrorAction SilentlyContinue
Remove-Item -Force "$env:LOCALAPPDATA\BeamNG\BeamNG.drive\current\mods\db.json" -ErrorAction SilentlyContinue
```

`mods/db.json` — база/кеш модов BeamNG. Она пересоздаётся при следующем запуске игры. Не удаляйте её при работающей игре.

## Проверка установки

В консоли игры:

```lua
print(extensions.soulPilot_main ~= nil)
apl_status()
```

Первая строка должна вывести `true`. Если в консоли всё ещё `autopilotLive_main`, активен старый мод или старый кеш.

## Удаление

Отключите мод в Mod Manager и удалите zip/папку. Пользовательские настройки можно удалить отдельно:

```text
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\mod_settings\soulPilot\
```
