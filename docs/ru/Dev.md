# Разработка

## Структура репозитория

```text
soulPilot/
├─ src/                 исходники runtime
│  ├─ lua/              GE + vehicle Lua
│  ├─ ui/               Vue HUD
│  ├─ mod_info/         метаданные мода
│  ├─ art/              runtime-арт
│  ├─ config/           дефолтные JSON
│  └─ tests/            Python golden-тесты
├─ scripts/             modScript.lua
├─ locales/             переводы UI
├─ src_music/           Python music bridge
├─ dev_mode.py          src/ -> корень мода
└─ build_release.py     сборка плоского zip
```

## Цикл разработки

```powershell
python dev_mode.py
python -m unittest discover -s src/tests -v
```

`dev_mode.py` зеркалирует файлы и удаляет устаревшие внутри runtime-папок. Он не создаёт `dist` внутри мода.

## Релиз

```powershell
python build_release.py --dry-run
python build_release.py
```

По умолчанию zip пишется вне распакованного мода:

```text
...\BeamNG.drive\current\mods\soulPilot-dist\soulPilot-<version>.zip
```

В архиве runtime-папки лежат в корне. Папки `src/` внутри архива быть не должно.

## Тесты

Покрываются:

- контракты JSON/конфигов;
- golden-расчёты руля и педалей;
- реальная маршрутизация GE-команд через Lua;
- аудит имён GE → vehicle;
- vehicle command-таблицы и legacy-алиасы.

Все тесты запускаются из корня репозитория.

## Мост GE ↔ vehicle

GE:

```lua
bridge.sendToVehicle('soulPilotWheelCmd.on("mods/unpacked/soulPilot/config/wheel.json")')
```

Vehicle:

```lua
soulPilotWheelCmd = {}
function soulPilotWheelCmd.on(path) ... end
```

Правила:

- имена команд — `soulPilot*Cmd`;
- `autopilotLive*Cmd` — только алиасы совместимости;
- команды должны переживать отсутствие машины игрока;
- API движка оборачивается в `pcall`.

## Стиль кода

- английские комментарии и логи в новом коде;
- `snake_case` для переменных и полей состояния;
- `camelCase` для функций;
- без дублирования math/bridge;
- не редактировать собственные `lua/` файлы BeamNG.

## Кеш и отладка

В консоли:

```lua
apl_debug_set(true)
apl_status()
apl_wheel("status")
apl_pedals("status")
apl_popup("status")
```

Логи пишутся в writable data directory (обычно `ai/logs/` при разработке).
