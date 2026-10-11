# ФАЗА 1 — ТОЧНАЯ СХЕМА CSV (Условия У1, У3, У4 утверждены)

> Источник: только чтение исходников BeamNG 0.39.4. Все ссылки — файл:строка.
> Файл переживает сжатие контекста. Обновлён: 2026-10-11.

## У4 — ГЛАВНАЯ ОГОВОРКА (для всех *_smoothed колонок)

**В Фазе 1 колонки *_smoothed = *_raw (расхождение появится в Фазе 3–4).**
Мод НЕ сглаживает в Фазе 1 — он только логирует. Значения *_smoothed
берутся из итоговых input.* (см. таблицу), которые при активном AI фактически
 равны raw (см. примечание про steering ниже) — и это правильно: в CSV не должно
 быть путаницы. Когда Фазы 3–4 включат наше сглаживание, *_smoothed начнёт
 отличаться от *_raw, и именно это расхождение и есть предмет анализа.

## У3 — ТОЧНЫЕ ПОЛЯ ВВОДА (где что лежит)

### Куда пишет AI
AI (vehicle/ai.lua) вызывает ТОЛЬКО `input.event(...)`, source = `"ai"`:
- `input.event("steering", v, "FILTER_AI", nil, nil, nil, "ai")` — ai.lua:428
- `input.event("throttle", v, "FILTER_AI", nil, nil, nil, "ai")` — ai.lua:429
- `input.event("brake", v, "FILTER_AI", nil, nil, nil, "ai")` — ai.lua:430
- `input.event("parkingbrake", v, "FILTER_AI", nil, nil, nil, "ai")` — ai.lua:431
- **clutch AI НЕ пишет вообще** (в ai.lua вызовов input.event clutch нет —
  clutch у автопилота = 0, управляет КПП).
- AI **НЕ пишет напрямую в electrics** (проверено grep-ом: ai.lua пишет только
  input.event; внутренняя копия lastCommand — ai.lua:111,433-436 — это его
  приватный буфер, нам не нужен).

### Цепочка обработки в input.lua (vehicle/input.lua)
1. `input.event(itype, ivalue, ...)` — input.lua:709 →
   `M.state[itype].val = ivalue` (input.lua:721), `.filter` (722),
   `.source` (726). Также `M.lastInputs[source][itype] = ivalue` (717-718).
   **Это СЫРОЙ ввод (raw) — точка отсчёта для нашей Фазы 4.**
2. `input.updateGFX(dt)` — input.lua:573 каждый кадр превращает state →
   итоговые `M[k]`, т.е. глобальные **`input.steering`, `input.throttle`,
   `input.brake`, `input.clutch`, `input.parkingbrake`** (запись `M[k] = ival`
   — input.lua:675; одновременно `electrics.values[k.."_input"]` — 678).
3. Для фильтра `"FILTER_AI"` (input.lua:641-648):
   - **steering**: `ival = e.smootherPAD:getWithRateCapped(ival, dt, 4 * rateMult)`
     (643) — встроенное сглаживание по скорости изменения (rateMult = 450 /
     steeringWheelLock, 241). Плюс `electrics.values.steeringUnassisted = ival` (644).
   - **throttle/brake/parkingbrake**: `ival = e.val or 0` (646) — **БЕЗ
     какого-либо сглаживания**, т.е. `input.throttle == input.state.throttle.val`.
4. Клатч: структура `M.state.clutch` — input.lua:122-129 (minLimit 0, maxLimit 1).

### ⚠️ Ассистенты руля НЕ трогают AI (важно для Фазы 4!)
`inputStabilization(st, dt, filter)` — input.lua:487-570 (slowdown на скорости,
limit, understeer reduction, oversteer reduction) вызывается ТОЛЬКО для
фильтров: FILTER_DIRECT (610), FILTER_PAD (619), FILTER_KBD (628),
FILTER_KBD2 (637). **Для "FILTER_AI" (641-648) — НЕ вызывается.**
Вывод: встроенные ассистенты скоростного замедления руля к автопилоту не
применяются — в Фазе 4 конфликт с ними исключён; остаётся только rate-cap
4*rateMult из пункта 3 (он МЕДЛЕННЫЙ: при typical lock 450 rateMult=1).

### Где финальные значения уходят в электронику (контекст для Фаз 3)
- `vehicleController.lua:455-457`:
  `inputValues.throttle = electrics.values.throttleOverride or min(max(input.throttle or 0,0),1)`,
  аналогично brakeOverride, clutchOverride — **готовые точки оверрайда**
  (кандидат для Фазы 3, но у steering оверрайда тут НЕТ).
- `electrics.values.smoothedValues.throttleInput/brakeInput` — vehicleController.lua:505-506.
- Итоговые `electrics.values.throttle/brake/clutch` — vehicleController.lua:544-546
  (это уже ПОСЛЕ внутренних сглаживаний контроллера).

## У1 — ТАБЛИЦА: имя_в_CSV ← источник (файл:строка)

Читаем vehicle-слой в `updateGFX`. Дискретизация 20 Гц (наш аккумулятор dt).

| # | Колонка CSV | Источник | Файл:строка |
|---|---|---|---|
| 1 | `time` | наш аккумулятор dt (сек, нарастающий с момента старта CSV) | мод |
| 2 | `pos_x` | `obj:getPosition().x` | vehicle/telemetryLogger.lua:25 (паттерн) |
| 3 | `pos_y` | `obj:getPosition().y` | то же |
| 4 | `pos_z` | `obj:getPosition().z` | то же |
| 5 | `speed` | `obj:getVelocity():length()` — м/с | telemetryLogger.lua:21 |
| 6 | `accel` | СВОЁ: d(speed)/dt по нашим 20 Гц-выборкам, м/с² (не sensors — чтобы избежать путаницы осей и единиц) | мод |
| 7 | `steer_raw` | `input.state.steering.val` (структура — input.lua:89-97; запись event — 721) | input.lua |
| 8 | `steer_smoothed` | `input.steering` (итог, = M.steering, input.lua:675). При AI это raw + rate-cap 4*rateMult (643). В Фазе 1 = raw (см. У4) | input.lua:643,675 |
| 9 | `throttle_raw` | `input.state.throttle.val` (структура — input.lua:98-105) | input.lua:721 |
| 10 | `throttle_smoothed` | `input.throttle` (input.lua:675). При AI = raw байт-в-байт (646). В Фазе 1 = raw (У4) | input.lua:646,675 |
| 11 | `brake_raw` | `input.state.brake.val` (структура — input.lua:106-113) | input.lua:721 |
| 12 | `brake_smoothed` | `input.brake` — при AI = raw (646). В Фазе 1 = raw (У4) | input.lua:646,675 |
| 13 | `clutch_raw` | `input.state.clutch.val` (структура — input.lua:122-129). При AI всегда ≈0 (AI clutch не пишет) | input.lua:721 |
| 14 | `clutch_smoothed` | `input.clutch` (input.lua:675). В Фазе 1 = raw (У4) | input.lua:646,675 |
| 15 | `gear` | `electrics.values.gear` — строка ("N","R","P","1"…) | vehicleController.lua:549 (запись); electrics.lua:12 (объявление M.values) |
| 16 | `gear_index` | `electrics.values.gearIndex` — число (доп. к ТЗ, полезен для анализа) | vehicleController.lua:552 |
| 17 | `rpm` | `electrics.values.rpm` | vehicleController.lua:555; electrics.lua:23 |
| 18 | `engine_temp` | `engine.thermals.coolantTemperature` (сырое, движок напрямую): `powertrain.getDevicesByType('combustionEngine')[1].thermals.coolantTemperature` | combustionEngineThermals.lua:23 (объявление M.coolantTemperature); паттерн чтения — csvMetrics.lua:71-76 |
| 19 | `oil_temp` | `electrics.values.oiltemp` (приборное, проброшено контроллером) | vehicleController.lua:558 (← controlLogicModule.oilTemp ← shiftLogic M.oilTemp = thermals.oilTemperature, manualGearbox.lua:218) |
| 20 | `water_temp` | `electrics.values.watertemp` (приборное, проброшено контроллером) | vehicleController.lua:559 (← shiftLogic M.waterTemp = thermals.coolantTemperature, manualGearbox.lua:217) |
| 21 | `engine_thermal` | `engine.thermals.engineBlockTemperature` (решение пользователя: агрегат «здоровья» движка) | combustionEngineThermals.lua:21; паттерн чтения — csvMetrics.lua:72 |
| 22 | `d_steer_dt` | СВОЁ: (steer_raw_now − steer_raw_prev) / dt, ед/сек | мод |
| 23 | `d_throttle_dt` | СВОЁ: (throttle_raw_now − throttle_raw_prev) / dt | мод |
| 24 | `d_brake_dt` | СВОЁ: (brake_raw_now − brake_raw_prev) / dt | мод |

Пояснения:
- 18 vs 20: coolant и watertemp — практически одно значение, но РАЗНЫЕ
  источники (сырой thermals vs приборный electrics) — это честно, обе колонки
  полезны: расхождение покажет, не «врёт» ли приборка. `engine_temp` и
  `water_temp` в ТЗ — разные колонки, источниками разведены.
- `thermalEnergy` в игре НЕ существует (проверено) → `engine_thermal` =
  engineBlockTemperature (утверждено пользователем).
- Если машин без движка (электрокар) — thermals может не быть: fallback 0 + WARN
  в лог при первом чтении.
- Клонирование колонок нет; NaN недопустим — все значения через `or 0` / `or ""`.

## У2 — ПУТИ ЗАПИСИ (стратегия с fallback)

`FS:getUserPath()` = `C:\Users\sophrosha\AppData\Local\BeamNG\BeamNG.drive\current\`
(с завершающим разделителем — доказательство: ge_utils.lua:1429
`FS:getUserPath().."vehicles"..osSep` конкатенирует без добавления `\`).
Папка мода лежит ИМЕННО там: `...\current\mods\unpacked\AutopilotLive\`.
Значит `FS:getUserPath() .. 'mods/unpacked/AutopilotLive/ai/csv/'` —
должен быть верным путём.

**Но полагаться на это не будем — стратегия «чтобы писалось»:**
1. GE-слой (`apl_debug()`) вычисляет АБСОЛЮТНЫЙ путь через `FS:getUserPath()`
   (GE гарантированно имеет FS) и пробует открыть файл-заглушку на запись.
2. Путь A (основной): `<userPath>mods/unpacked/AutopilotLive/ai/csv/…`
   и `<userPath>mods/unpacked/AutopilotLive/ai/logs/…`
3. Путь B (fallback, если io.open вернул nil): `<userPath>autopilotLive_logs/csv/…`
   и `<userPath>autopilotLive_logs/logs/…`
   (разрешение пользователя: «пиши в autopilotLive_logs, главное чтобы писалось»).
4. Какой путь выбран — пишем в лог мода (INFO) и в ответ `apl_status()`.
5. Абсолютный путь передаётся vehicle-слою ГОТОВЫМ строкой через
   `veh:queueLuaCommand('autopilotLiveCmd.startCsv("C:/.../file.csv")')` —
   vehicle-слой не ищет путь сам, только пишет по полученной строке
   (нормализация `\` → `/` до отправки).
6. Имена: `os.date('%Y-%m-%d_%H-%M-%S')` → `<stamp>_drive.csv` / `<stamp>_mod.txt`.

## Связь GE ↔ vehicle (для кода Фазы 1)

- GE → vehicle: `veh:queueLuaCommand(...)`, вызов глобального
  `autopilotLiveCmd.*` (наш vehicle-модуль расшаривает таблицу в _G).
- vehicle → GE: `obj:queueGameEngineLua('autopilotLive_main.onVehicleLog("W","текст")')`
  — GE-расширение `autopilotLive/main.lua` экспортирует
  `M.onVehicleLog(level, msg)` и пишет в txt-лог.
- Обратите внимание: имя GE-расширения после загрузки = `autopilotLive_main`
  (luaPathToExtName: `autopilotLive/main` → `autopilotLive_main`,
  extensions.lua:55-62) — в queueGameEngineLua обращаться как
  `autopilotLive_main.onVehicleLog(...)`.
