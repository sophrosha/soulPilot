# API-исследование Фазы 6: фары день/ночь (BeamNG.drive 0.39.4)

Исследование ПЕРЕД кодом (шаг 6.1). Читаны ТОЛЬКО исходники игры
(`D:\SteamLibrary\steamapps\common\BeamNG.drive\lua\*` — чтение разрешено),
ничего не правилось. План утверждён координатором 18.10: вопросы 1-5 + дополнение
(1) `night_state: 2` должен читаться из конфига; (2) `apl_mark` дописывает
игровое время в comment.

## 1. Управление фарами

### 1.1 Штатная точка: `electrics.setLightsState(newval)`

- Определение: `lua/vehicle/electrics.lua:1026-1028`, экспорт `M.setLightsState`
  (`:1107`). Реализация тривиальна: `lightsState = newval` — локальная переменная
  модуля. **Прямая установка состояния: БЕЗ input.event, БЕЗ toggle-цикла.**
- Значения (подтверждено в трёх местах):
  | state | смысл | источник |
  |---|---|---|
  | 0 | выкл | радиал-меню `headlights_off` → `setLightsState(0)` (`:537`) |
  | 1 | ближний (lowbeam) | `headlights_low` → `setLightsState(1)` (`:552`) |
  | 2 | дальний (highbeam) | `headlights_high` → `setLightsState(2)` (`:567`) |
  цикл ручного переключения: `toggle_lights` 0→1→2→0 (`:973-981`).
- Чтение состояния: `electrics.values.lights_state` (публикуется каждый кадр,
  `:406-407`), производные: `vals.lowhighbeam = (1 или 2)` (`:433`),
  `vals.lowbeam = (1)` (`:434`), `vals.highbeam = (2)` (`:435`).
- **`lightsOverride` НЕ существует** (grep по всей lua — 0 совпадений), как и
  parkingbrake-override в Фазе 5. Яркости/dim API **нет**: только 0/1/2;
  `vals.parking = 0 -- TODO: input.parkinglights` (`:421`) — габариты не
  реализованы даже в ванили. «Яркость 40%/100%» из ТЗ — только через разные
  state (см. §7, решение координатора).

### 1.2 Официальный прецедент «без дёрганья»: `techCore.handleSetLights`

`lua/vehicle/extensions/tech/techCore.lua:471-483` (внешний API tech-расширений):

```lua
if headLights ~= nil and state.lights_state ~= headLights then
  electrics.setLightsState(headLights)
end
```

**Guard «не зовём setLightsState, если уже целевое состояние»** — это и есть
штатная защита от «дёрганья переключателя». Перенимаем схему 1-в-1.
Второй внешний вызов: `gameplayInterfaceModules/interactElectrics.lua:34`
(клик по световому переключателю в салоне — действие ИГРОКА, попадает под
детект ручного вмешательства, §7.4).

### 1.3 Что НЕ используем

- `toggle_lights` (`electrics.lua:973-981`) — цикл 0→1→2→0: именно то самое
  «дёрганье переключателем вкл-выкл-вкл», запрещённое ТЗ.
- Flash highbeam (`:1002-1005` — временный 2 с возвратом сохранённого): у игрока
  это отдельная клавиша; при срабатывании в auto мы увидим смену
  `lights_state` и корректно расценим как ручное вмешательство (§7.4).
- `input.event` — не дёргаем никогда (контракт проекта).

## 2. Игровое время

### 2.1 Чтение: `core_environment.getTimeOfDay()` — ТОЛЬКО GE

- Определение: `lua/ge/extensions/core/environment.lua:492`, экспорт `M.getTimeOfDay`
  (`:1850`). Возвращает таблицу с полем **`time`** — нормированная доля суток
  `0..1`, где **0 = полдень** (проверено по обратной функции
  `ge_utils.lua:706`: `tod.time = ((секofday / 86400) + 0.5) % 1`, и по чтению
  `ge_utils.lua:679`: `seconds = ((tod.time + 0.5) % 1) * 86400`).
- **Конвертация в часы: `ЧЧ = ((time + 0.5) % 1) * 24`** — ровно так делает
  ванильная глобальная обёртка `ge_utils.lua:676-688 getTimeOfDay(asString)`
  → `{hours, mins, secs}` (24ч) либо `"HH:MM:SS"`.
- **`electrics.values` времени НЕТ** (grep `vals.(sun|time|daylight|weather)` — 0)
  → время доступно **только в GE** → архитектура: время решает GE, vehicle
  получает готовый числовой target (как в warmup: логика не в GE).

### 2.2 Установка времени (для тестов)

- `core_environment.setTimeOfDay({time = <0..1>})` — environment.lua:704-744
  (принимает таблицу полями состояния, `time` — нормированная доля).
- **Глобальная GE-обёртка `setTimeOfDay('19:50')`** — `ge_utils.lua:692-707`
  (парсит строку "HH:MM[:SS]"); файл подключён как глобалы:
  `lua/ge/main.lua:45 require("ge_utils")`. Точно так же читается глобал
  `getTimeOfDay()` (без аргумента → таблица `{hours, mins, secs}`).
  **Тест-команды даём через `setTimeOfDay('ЧЧ:ММ')`.**

### 2.3 Ванильная ночная автоматика — НЕ про фары машины

- `environment.lua:357-373 isNightTime(time)` + `:464-466 applynightLightsState`
  + `:402-427 setNightLightsEnabled` — включает/выключает **свет сцены**
  (scenetree-объекты: фонари, emissive) при смене времени (`setTimeOfDay` → `:733`).
  **Фары игрока НЕ затрагиваются** — конфликта с нашим модом нет.
- Окно ночи для сцены: `getNightLightsTimeWindow()` (`:343-355`) — сначала
  level-specific dynFields `nightLightsNightStart/NightEnd` (пер-карточное
  переопределение уже существует нативно!), иначе дефолты
  `0.25 / 0.75` (`:40-41` = 18:00/06:00 в шкале 0=полдень), иначе — солнечное
  окно `core_solarTimeOfDay.getSolarNightWindow(state)`.
- Солнечное окно также использует ванильный трафик:
  `gameplay/traffic/vehicle.lua:528-537 checkTimeOfDay()`.
- **Вывод для ТЗ:** нам НЕ нужен solar (сезон/широта) — ТЗ требует фикс РФ-часы
  20:00–07:00 + пер-карточные overrides. Наш `lights_by_map.json` — зеркало
  нативных `nightLightsNightStart/End`, но для фар.

## 3. Определение машины (pop-up guard)

- **`veh.JBeam`** — внутренний ключ модели (строка), GE-поле объекта:
  `core/vehicles.lua:932` (`res.key = vehicle.JBeam` в `getVehicleDetails`).
  Альтернатива: `getCurrentVehicleDetails().current.key` (`:950` → `:945`).
- Имена ключей проверены по структуре контента: `content/vehicles/bolide.zip`,
  `content/vehicles/wigeon.zip` → ключи **`bolide`**, **`wigeon`** (pop-up фары).
- Человекочитаемое имя — `getCurrentVehicleDetails().model.Name/.Brand`
  (`core/vehicles.lua:945`, использование: `util/richPresence.lua:341-346`) —
  для guard не подходит (локализуется), берём `JBeam`.
- **Решение:** guard ставится в GE при `apl_lights("auto")`: JBeam ∈ popup-списка
  → авто-режим НЕ активируется (INFO «Фаза 8»). Ручные far/near/off — работают
  (это ровно то же API, что радиал-меню ванили).

## 4. Определение карты

- **`getCurrentLevelIdentifier()`** — GE-глобал, возвращает строковый id уровня
  (применения: `ge/map.lua:150`, `ui/uiNavi.lua:389,414,423`).
- Человекочитаемое имя — `core_levels.getLevelName(getMissionFilename())`
  (`ge/setSpawnpoint.lua:15,31`) — для конфига не нужно.
- Фактические идентификаторы (проверено по `content/levels/*.zip`):
  **`east_coast_usa`** (East Coast, USA — наша основная карта), **`italy`**
  (Italy). Также: `west_coast_usa`, `jungle_rock_island`, `johnson_valley`,
  `small_island`, `utah` и др. На тесте подтвердим фактический id командой
  `apl_lights("status")` (печатает map id).

## 5. Хук GE-тика

- `M.onUpdate(dtReal, dtSim, dtRaw)` — штатный хук GE-расширений (примеры ванили:
  `ge/extensions/mcp/tools/spawn.lua:12`, `ge/extensions/core/vehicle/
  vehicleTriggerHighlight.lua:278`, `gameplay/tutorial/runtime.lua:261`).
- В нашем `lua/ge/extensions/auto` ... `autopilotLive/main.lua` хука `onUpdate`
  пока НЕТ — добавляем в Фазе 6 (1 Гц через аккумулятор, только при auto).

## 6. Паттерны мода (переиспользуем)

- Чтение JSON в GE: `io.open(отн. путь) → read('*all') → pcall(jsonDecode, ...)`
  (`main.lua:329-348 loadGraphConfig`). Пути **относительные от userPath**
  (`mods/unpacked/AutopilotLive/ai/config/...` — CWD общий для GE и vehicle-VM).
- GE → vehicle: `sendToVehicle()` (`main.lua:139-157`, `veh:queueLuaCommand`).
- vehicle → GE: `obj:queueGameEngineLua('autopilotLive_main.onVehicleXxx(...)')`
  (паттерн `toGE` в `autopilotLiveWarmup.lua:77-83` + хендлеры
  `main.lua:1118+`).
- Публичные vehicle-команды: глобальная таблица `autopilotLiveXxxCmd`
  (`autopilotLiveWarmup.lua:407+`), конфиг GE передаёт в `on(confPath)`.
- `M.updateGFX(dt)` vehicle-расширения + защита NaN/dt (`warmup.lua:348-349`).

## 7. Архитектурное решение Фазы 6 (по утверждённому плану)

### 7.1 Распределение ответственности

- **GE (`main.lua`)** — время, карта, popup-guard, гистерезис, day/night →
  numeric target; шлёт vehicle команду **только при смене target**.
- **vehicle (`autopilotLiveLights.lua`)** — применяет `electrics.setLightsState`
  с guard `lights_state ~= target` (паттерн techCore §1.2), детектит ручное
  вмешательство в auto.
- wheel/pedals/КПП/прогрев/CSV — не трогаются; input.event — не дёргается.

### 7.2 Режимы (ответы координатора 18.10, вопросы 1-5)

| режим | state | как |
|---|---|---|
| день 07:00-20:00 | `day_state` (дефолт **1** — ближний как ДХО; можно 0 «день без света») | auto |
| ночь 20:00-07:00 | `night_state` (дефолт **1** — ближний; в конфиге можно **2** — дальний) | auto |
| дальний | 2 | только ручной `apl_lights("far")` — auto сам НЕ включает |
| ближний | 1 | ручной `apl_lights("near")` |
| выкл | 0 | ручной `apl_lights("off")` (гасит + снимает auto) |

Авто-режим включает фары **только игроком** `apl_lights("auto")`; выключает —
`apl_lights("off")` или ручное вмешательство (§7.4).

### 7.3 Гистерезис ±15 минут (обязателен — «чтобы не мигало»)

Алгоритм (Шмитт-триггер на границах окна, шкала часов 0..24, окно wraps через
 полночь, `start=20, end=7`):

- состояние `isNight` (свой флаг);
- **день → ночь:** только когда часы попали В окно (`h ≥ start или h < end`);
- **ночь → день:** когда часы вышли из окна, РАСШИРЁННОГО на ±`hysteresis_min`
  (`[start − 15м, end + 15м]`) — т.е. ночью остаёмся ещё 15 мин после 07:00 и
  не выключаемся за 15 мин до 20:00 при откате времени;
- при промежуточных значениях (полоса ±15 мин) **состояние держится** —
  мигание невозможно, пока время не перепрыгнет полосу целиком;
- при включении auto флаг инициализируется членством текущих часов в окне.

Эффект при обычном (направленном вперёд) времени: ночь ровно [20:00 → 07:15].
Никаких step-переходов/ступеней (запрещено координатором), API яркости нет.

### 7.4 Ручное вмешательство — auto отключается, не дерёмся

- vehicle в auto хранит `lastApplied` (что мы применили). В `updateGFX`:
  `lights_state ≠ lastApplied` → это сделал не мы (клавиша L, радиал-меню,
  клик в салоне, flash-highbeam) → **auto → off** + событие в GE;
- GE печатает ровно: **«apl_lights: Ручное управление, авто-режим отключен»**
  (INFO) и ставит `lightsAuto=false`; фары остаются в том состоянии, как их
  поставил игрок (не возвращаем — «не деремся»);
- `setTarget` при уже выключенном (по vehicle) auto — игнорируется;
- respawn (`M.onReset`) в auto: `lastApplied = nil` → авто-применение target на
  ближайшем кадре без ложного interrupt (electrics сбрасываются при спавне).

### 7.5 Конфиги

- `ai/config/lights.json` (DEFAULTS в GE-коде, синхронно):
  `timing.poll_hz` (1), `timing.hysteresis_min` (15), `modes.day_state` (1),
  `modes.night_state` (1 — **валидация 0..2, значение 2 читается и работает**),
  `night_window.start/end` ("20:00"/"07:00", парсинг "HH:MM" → часы),
  `guard.refuse_auto_on_popup` (1), `guard.popup_models` (["bolide","wigeon"]).
- `ai/config/lights_by_map.json` — ТОЛЬКО явные overrides:
  `maps.<levelId>.night_window` (например `east_coast_usa`, `italy`).
  Для карт, не указанных в JSON, — дефолт РФ 20:00–07:00 из `lights.json`
  (ответ координатора, вопрос 5). Применяется окно карты, если запись есть.
- Правка JSON → пере-запуск `apl_lights("auto")` (конфиг читается при включении).

### 7.6 `apl_mark` + игровое время (дополнение координатора)

`apl_mark("тут темнеет")` → в `marks.csv` comment = `тут темнеет [19:45]`.
GE-слой перед записью читает `core_environment.getTimeOfDay()`, конвертирует в
`HH:MM` (§2.1) и дописывает ` [ЧЧ:ММ]` к комментарию. (Запись marks.csv идёт
из GE напрямую — `main.lua:753-834`, vehicle-слой не участвует; результат
точно ТЗ: метка со временем для калибровки световых окон в `lights_by_map.json`.)

## 8. Тест-команды (детализация — `phase6_report.md`)

`apl_debug()`, `setTimeOfDay('ЧЧ:ММ')` (глобал ge_utils), `apl_lights("auto"|
"far"|"near"|"off"|"status")`, `apl_status()`, `apl_mark("текст")`.
