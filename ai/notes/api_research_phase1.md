# ИССЛЕДОВАНИЕ API BEAMNG 0.39.4 — Фаза 1 (дебаг + CSV)

> Дата: 2026-10-11. Источник: только чтение исходников
> `D:\SteamLibrary\steamapps\common\BeamNG.drive\lua\`.
> Файл создан, чтобы пережить сжатие контекста. Всё ключевое здесь.

## 1. Слои Lua и где что живёт

- **GE-слой** (game engine): `lua/ge/`, расширения — `lua/ge/extensions/<путь>/<файл>.lua`.
  Путь мода в VFS оверлеится поверх игры: файл мода
  `mods/unpacked/AutopilotLive/lua/ge/extensions/autopilotLive/main.lua`
  виден как `/lua/ge/extensions/autopilotLive/main.lua`.
  Загрузка GE-расширений: `extensions.load('autopilotLive/main')`
  (в `lua/common/extensions.lua`: путь с `/` → extName через `luaPathToExtName`,
  подчёркивания → `autopilotLive_main`).
- **Vehicle-слой**: `lua/vehicle/`. Глобальные модули грузятся в
  `vehicle/main.lua:init()` через `require(...)`: input, electrics, ai,
  powertrain, controller, sensors и т.д.
- Модуль расширения обязан `return M` в конце файла.

## 2. КЛЮЧЕВОЕ: автозагрузка vehicle-расширений

`vehicle/main.lua:314`:
```lua
extensions.loadModulesInDirectory("lua/vehicle/extensions/auto")
```
Это вызывается при КАЖДОМ спавне машины и ищет `*.lua` рекурсивно через
`FS:findFiles` (VFS!). Значит файл мода
`AutopilotLive/lua/vehicle/extensions/auto/<name>.lua`
**загрузится сам при спавне машины**. Это штатный путь для vehicle-слоя мода.
- Также `vehicle/main.lua:34`: `extensions.addModulePath("lua/vehicle/extensions/")`.
- Наша же плановая папка `lua/vehicle/autopilotLive/` сама по себе НЕ
  автозагрузится — нужен загрузчик (см. Открытые вопросы).

## 3. КЛЮЧЕВОЕ: загрузка GE-слоя мода через modScript

`core/modmanager.lua`:
- Строка 704: `FS:findFiles('/scripts/', 'modScript.lua', -1, true, false)` —
  ищет ВЕЗДЕ по VFS, включая смонтированные unpacked-моды, и исполняет
  каждый найденный `modScript.lua` через `pcall(dofile, v)` при старте (initDB).
- Строка 695-702: пока исполняются modScript'ы, `extensions.load` сам
  выставляет `setExtensionUnloadMode(module, "manual")` (расширение не выгрузится
  при смене карты). Позже (стр. 722) старая версия возвращается.
- Строки 915-920: для unpacked-модов дополнительно ищутся
  `<unpackedPath>/scripts/modScript.lua` и `<unpackedPath>/mods_data/modScript.lua`.

**Вывод: штатная точка входа GE-слоя мода = `AutopilotLive/scripts/modScript.lua`,
внутри: `extensions.load('autopilotLive/main')`.**

## 4. Консольные команды (ВАЖНО — нет registerConsoleCommand)

- API регистрации именованных консольных команд в Lua НЕТ (grep
  `registerConsoleCommand|addConsoleCommand` — ноль совпадений).
- Консоль (`core/windowsConsole.lua`):
  - Контекст `GE-Lua` — строка исполняется **в C++ как Lua-код**
    (комментарий стр. 14: "executed in c++, it does not reach here").
    Значит ввод `apl_debug()` = обычный вызов Lua-функции в GE-VM.
  - UI-консоль (`ui/console.lua:998`): `executeLuaSandboxed(cmd, 'GEConsole')`.
  - **Хук**: `windowsConsole.executeCommand` (стр. 11) вызывает
    `extensions.hook('onConsoleExecuteCommand', context, cmd)` ДО ветвления по
    контексту — наше GE-расширение может реализовать
    `M.onConsoleExecuteCommand = function(context, cmd)` и ловить строки вида
    `apl_debug` (пока не проверено, зовётся ли хук именно для GE-Lua-контекста).
- Единственный реальный пример использования: `util/followTheWhiteRabbit.lua`
  (реализует `onConsoleExecuteCommand`, проверяет context и cmd).
- **План команд (Фаза 1)**: поддержать ОБА механизма:
  1. Глобальные функции GE-слоя: `apl_debug()`, `apl_status()` — надёжно,
     т.к. GE-Lua контекст исполняет строку как Lua.
  2. Ловля строк в `onConsoleExecuteCommand` — как опция, проверить при тесте.
- Для vehicle-слоя есть отдельный консольный контекст «Current Vehicle - Lua»
  (`queueLuaCommand`), но мод команды туда не добавляет.

## 5. Перехват сигналов AI (vehicle-слой)

- **AI пишет ввод через** `vehicle/ai.lua:428-431`:
  ```lua
  input.event("steering",   steering,   "FILTER_AI", nil, nil, nil, "ai")
  input.event("throttle",   throttle,   "FILTER_AI", nil, nil, nil, "ai")
  input.event("brake",      brake,      "FILTER_AI", nil, nil, nil, "ai")
  input.event("parkingbrake",parkingbrake,"FILTER_AI", nil, nil, nil, "ai")
  ```
- **`input.lua` (vehicle)** — устройство модуля:
  - `input.event(itype, ivalue, filter, angle, lockType, osClockHP, source)`
    (стр. 709) кладёт `M.state[itype].val = ivalue` (СЫРОЕ значение) + filter.
    `M.lastInputs[source][itype]` хранит сырой ввод по источникам (стр. 717-718).
  - `input.updateGFX(dt)` (стр. 573) каждую кадровую секунду превращает
    `M.state` → финальные значения: **`input.throttle`, `input.brake`,
    `input.steering`, `input.clutch`, `input.parkingbrake`** (через `M[k] = ival`,
    стр. 675). Для `FILTER_AI` (стр. 641-648): steering проходит через
    `smootherPAD:getWithRateCapped(ival, dt, 4*rateMult)`, остальное — без
    сглаживания (`ival = e.val`). Также пишет `electrics.values[k .. "_input"]`.
  - Фильтры: FILTER_DIRECT / FILTER_PAD / FILTER_KBD / FILTER_KBD2 / "FILTER_AI".
  - `inputStabilization` (стр. 487) — встроенные ассистенты руля
    (slowdown на скорости, limit, understeer reduction) — НЕ трогаем, работаем поверх.
- **Потребители**: `controller/vehicleController/vehicleController.lua:455-456`:
  ```lua
  inputValues.throttle = electrics.values.throttleOverride or min(max(input.throttle or 0,0),1)
  inputValues.brake    = electrics.values.brakeOverride    or min(max(input.brake or 0,0),1)
  ```
  ⚠️ Существует готовый механизм оверрайдов: `electrics.values.throttleOverride`,
  `electrics.values.brakeOverride` — кандидат для Фаз 3 (педали), НО у steering
  оверрайда здесь нет (str. 457+, нужно проверить при Фазе 4 — читать
  vehicleController полностью).
  Также `controlModes.lua:50` — `setInputValue(name, value)` (экспорт стр. 113) —
  кандидат для подачи сглаженных значений (исследовать в Фазе 3).
- **ВАЖНО**: `input` — глобальный модуль vehicle-VM; наш vehicle-скрипт может
  ЧИТАТЬ `input.state` (сырой, до сглаживания: `input.state.steering.val` —
  нужно уточнить имя: в коде `M.state`, доступен ли как `input.state`) и
  `input.throttle` и т.д. (финальный). Точку перехвата для подачи своих значений
  выбираем в Фазе 3 (кандидаты: обёртка над `input.event` — запрещено дёргать
  напрямую, electrics override, setInputValue).

## 6. Данные для CSV (точные источники)

| Поле | Источник (vehicle-слой) | Где видел |
|---|---|---|
| позиция x,y,z | `obj:getPosition()` → `.x .y .z` | telemetryLogger.lua:25 |
| скорость | `obj:getVelocity():length()` (м/с) | telemetryLogger.lua:21 |
| ускорение | `sensors.gx2`, `sensors.gy2` (g) или считать d(speed)/dt самим | telemetryLogger.lua:23-24 |
| throttle/brake/steer/clutch raw+smoothed | `input.state[k].val` (raw) и `input.k` (финал) — **уточнить структуру M.state** | input.lua:675,717 |
| gear | `electrics.values.gear` (строка: "N","R","P","D", цифры), `electrics.values.gearIndex` (число) | csvMetrics.lua:61-62 |
| rpm | `electrics.values.rpm` | csvMetrics.lua:63 |
| oiltemp | `electrics.values.oiltemp` | csvMetrics.lua:62 |
| watertemp | `electrics.values.watertemp` | csvMetrics.lua:64 |
| wheelspeed | `electrics.values.wheelspeed` | csvMetrics.lua:64 |
| engine thermals (полные) | `powertrain.getDevicesByType('combustionEngine')` → `[v].thermals.engineBlockTemperature / cylinderWallTemperature / coolantTemperature / exhaustTemperature / oilTemperature` | csvMetrics.lua:71-76 |
| thermalEnergy (engine_thermal) | поля `thermals` combustionEngineThermals.lua — **thermalEnergy НЕ найден, уточнить** (есть oilTemperature, engineBlockTemperature, coolantTemperature=str.631, энергия внутри через energyToOil) | combustionEngineThermals.lua:223,631-633 |
| env temp | `obj:getEnvTemperature()` (Кельвины!) | csvMetrics.lua:58 |
| parkingbrake | `input.parkingbrake` | telemetryLogger.lua:22 |

⚠️ `electrics.values.watertemp`/`oiltemp` — уже экспортированы контроллером
(см. shiftLogic `M.waterTemp`, `M.oilTemp`). Для чистых данных — powertrain thermals.

## 7. Готовые образцы CSV-логеров (ЧИТАТЬ при написании кода)

1. **`lua/vehicle/extensions/telemetryLogger.lua`** (86 строк) — канон:
   - `updateGFX(dt)` копит данные в память, `saveDataToDisk()` пишет
     `io.open("telemetryData_" .. os.date("%H-%M-%S") .. ".csv", "w")`,
     escapeCSV, `\r\n`, `M.onReset = M.onInit` для очистки.
   - Управление: `startRecording/stopRecording`.
2. **`lua/vehicle/extensions/test/csvMetrics.lua`** — через
   `require('csvlib')`: `csvWriter.newCSV(unpack(headers))`,
   `csvData:add(unpack(row))`, `csvData:write(path)`; троттлинг записи
   `frame % rate == 0` (rate=64 кадров); расширенные поля (thermals,
   electrics) — брать оттуда.
3. **`lua/vehicle/extensions/tech/dumpPlayerInput.lua:37`** — минимал-пример
   записи `io.open`+`string.format("%f,...")`.
4. **`lua/common/csvlib.lua`** — `writeFile(filename, self:dump())` (стр. 94).

## 8. Запись файлов

- Глобальная `writeFile(filename, data)` = `io.open(filename,'w')`
  (`lua/common/utils.lua:906`). Есть и в vehicle, и в GE слоях.
- Относительные пути (`io.open("x.csv")`) резолвятся... **не проверено**:
  вероятно, от user-папки игры
  (`FS:getUserPath()` = `C:\Users\sophrosha\AppData\Local\BeamNG\BeamNG.drive\current\`).
  Наш мод = `.../current/mods/unpacked/AutopilotLive/`, значит путь к данным:
  **`mods/unpacked/AutopilotLive/ai/csv/...`** (проверить при первом тесте!
  Если io.open пишет не туда — использовать
  `FS:getFileRealPath()` / абсолютный путь через `FS:getUserPath() .. rel`
  (паттерн из `mcp/tools/system.lua:76`)).
- Также `FS:getUserPath()` доступен (modmanager, photomode).

## 9. Связь GE ↔ vehicle

- GE → vehicle: `veh:queueLuaCommand("строкаLua()")` (примеры: ge_utils.lua:850,
  campaign/exploration.lua).
- vehicle → GE: `obj:queueGameEngineLua("...")`, внутри —
  `extensions.hook('eventName', args)` (примеры: scriptAIManager.lua:92,
  ai.lua:654). Имена хуков придумываем сами, но hook вызывается по всем
  загруженным GE-расширениям, реализовавшим `M.eventName`.

## 10. GE-хуки жизненного цикла (для GE-расширения)

- `M.onExtensionLoaded()` — при загрузке (extensions.lua:606).
- `M.onInit()` — после onExtensionLoaded (стр. 639).
- `M.onExtensionUnloaded()` — выгрузка.
- `onUpdate(dtReal, dtSim, dtRaw)` — каждый кадр GE (main.lua:935,
  `extensions.hook('onUpdate', ...)`).
- Хуки vehicle-расширений: `M.updateGFX(dt)` (графика-тик, как в
  telemetryLogger), `M.onInit`, `M.onReset`, `M.onVehicleLoaded`
  (vehicle/main.lua:316 `extensions.hook("onVehicleLoaded", ...)`).
- Также полезны GE: `onVehicleSpawned`, `onVehicleSwitched`,
  `onVehicleDestroyed` (см. windowsConsole M.*).
- `extensions.hook('onConsoleExecuteCommand', context, cmd)` — см. п.4.
- Дебаг-вывод: `log('I'/'W'/'E', tag, msg)` → пишет в beamng.log (основной!).
  Наш отдельный лог = собственный файл через writeFile/io.open (см. ТЗ:
  свои события — в ai/logs/, НЕ зависеть от beamng.log).

## 11. Окружение/время (заготовка для Фазы 6)

- `core_environment` — GE-расширение (в presetExtensions, main.lua:357).
  Время суток — исследовать в Фазе 6 (не трогали).

## 12. Итоговая архитектура Фазы 1 (черновик для плана)

```
AutopilotLive/
├── scripts/modScript.lua            ← ТОЧКА ВХОДА: extensions.load('autopilotLive/main')
├── lua/ge/extensions/autopilotLive/main.lua   ← GE: команды apl_debug(), флаги,
│     eventLog (ai/logs/*.txt), управление записью, передача команд vehicle-слою
├── lua/vehicle/extensions/auto/autopilotLive.lua ← vehicle: автозагрузка при спавне,
│     сбор строк CSV (input*, electrics, thermals), запись в ai/csv/*.csv
```
- CSV пишет vehicle-слой (там все данные), лог событий — GE-слой (он видит
  спавн/выгрузку/карту), связь между ними — queueLuaCommand/queueGameEngineLua.
- Дебаг вкл → vehicle слой стартует запись CSV немедленно, вкл лог-файл.

## 13. Открытые вопросы (решить до/в Фазе 1)

1. **`input.state` ПОДТВЕРЖДЕНО**: input.lua:20/89 `M.state = {}` — модуль
   `input.state[itype].val` = СЫРОЕ значение (input.lua:721), `.filter`, `.source`.
   Значит raw = `input.state.throttle.val` и т.д., финал = `input.throttle`.
2. **`thermalEnergy` НЕ существует** в combustionEngineThermals (grep — 0 совпадений;
   есть только внутренние energyToXxx потоки). Для колонки engine_thermal
   предложу: `thermals.engineBlockTemperature` как «агрегат» или считать самим —
   спросить пользователя.
3. Путь записи io.open из vehicle-слоя (от user root или от корня игры) —
   проверить первым тестом.
4. Хук `onConsoleExecuteCommand` — приходит ли для GE-Lua-контекста.
5. Структура папки vehicle-слоя: оставить `lua/vehicle/autopilotLive/`
   (самодельный загрузчик в auto/) или сразу в `extensions/auto/` —
   предложу пользователю.
6. Порядок частоты CSV: каждый кадр (60+/сек) vs троттлинг (как csvMetrics
   rate=64) vs дискретизация по времени (например 20 Гц) — спросить.

## 14. Правила (напоминание после сжатия)

- ТОЛЬКО русский в общении и комментариях; имена переменных — английские.
- НЕ править `D:\...\BeamNG.drive\lua\*` (только читать).
- НЕ запускать игру самому, не лезть в личные файлы, не в интернет кроме
  документации BeamNG.
- AutopilotLive = оверлей: НЕ дёргать input.event напрямую, НЕ трогать КПП,
  НЕ подменять AI, НЕ менять исходники игры.
- Каждая фаза: план → утверждение пользователем → код → тест → коммит (рус.).
- PROJECT_STATE.md читать в начале сессии; обновлять после каждого коммита.
- Все данные — в ai/ папки мода.
- venv: `ai/venv/` (pandas 3.0.6 установлен, Python 3.13.15).
- Префикс команд: `apl_`.
- Папка проекта (git): `C:\Users\sophrosha\AppData\Local\BeamNG\BeamNG.drive\current\mods\unpacked\AutopilotLive\`.
