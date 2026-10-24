# api_research_phase5.md — Фаза 5: прогрев машины (исследование исходников BeamNG 0.39.4)

> Статус: исследование ЗАВЕРШЕНО (2026-10-16) перед написанием кода.
> Правило проекта: исходники игры ТОЛЬКО читаются, не правятся.

## 1. Программный завод двигателя

Ключевые места:

- `lua/vehicle/electrics.lua:350-372` — `setIgnitionLevel(ignitionLevel)`:
  - уровень 0/1 → `controller.mainController.setEngineIgnition(false)` + `setStarter(false)` (зажигание выкл);
  - уровень 2 → ignition ON, стартёр OFF («run»);
  - уровень 3 → ignition ON + стартёр ON («стартёр крутит»).
- `lua/vehicle/controller/vehicleController/vehicleController.lua:296-343` —
  `handleStalling(isEngineRunning, dt)`:
  - строка 303-304: при схватке (`isEngineRunning && ignitionLevel > 2`) контроллер
    сам опускает уровень 3 → 2. Т.е. **достаточно один раз позвать
    `electrics.setIgnitionLevel(3)`** — остальное машина делает сама (это ровно
    тот же путь, что при удержании клавиши стартера игроком);
  - arcade-КПП (строки 307-322): при газе/тормозе сам крутит стартер (антизаглох);
    realistic (323+): только сообщение «заглох, нажми стартер» — авто-завода нет.
- Сигнал «двигатель заведён»: `electrics.values.engineRunning` (пишется
  vehicleController:565 из `controlLogicModule.isEngineRunning`; 0/>0).
- «Стартёр крутится»: `engine.starterEngagedCoef > 0` (vehicleController:298-299).
- Прямой input.event для стартера НЕ нужен — electrics API suffices. Это важно
  для чартера мода: «не дёргать input.event напрямую» соблюдается.

Вывод для кода: starting_engine = `electrics.setIgnitionLevel(3)` (для ICE),
`setIgnitionLevel(2)` для EV (нет combustionEngine — стартёр бессмысленен,
нужен только ignition-on; у EV `isEngineRunning=1` после включения —
shiftLogic/electricMotor.lua:205).

## 2. Снятие ручника

- Override-каналов для ручника НЕТ: vehicleController:455-457 поддерживают только
  `throttleOverride`/`brakeOverride`/`clutchOverride` (педали). Parkingbrake —
  штатный input-канал (`input.lua:114`, `parkingbrake`).
- `vehicleController.lua:428-452` — `smartParkingBrake(ivalue, filter,
  isAxisOverride)`, экспортирована как `M.smartParkingBrake` (строка 1248).
  При `ivalue=0` и FILTER_DIRECT (дефолт, строка 429) путь `input.event("parkingbrake", 0, FILTER_DIRECT)` (строка 445-446) — ручник отпущен.
- Точка внешнего взаимодействия официальная: комментарий в коде —
  «this used in certain cases where we need to interact with the smart parking
  brake externally (for example the airbrakes)».
- Доступ из vehicle-модуля: `controller.getControllerSafe("vehicleController")`
  (lua/vehicle/controller.lua:232/236, 1041-1043; nilController — безопасная
  заглушка, если контроллера нет).
- Побочный факт: в arcade smart parking brake авто-включается при
  ignitionLevel<2 и скорости<1 (vehicleController:516-519) и авто-снимается при
  газе+ignition=2 (522-524). Во время нашего старта (ignition 3) авто-включение
  не сработает (условие <2 не выполняется).
- Текущее состояние читаем: `electrics.values.parkingbrake` (0..1).

Согласование (решение координатора 2026-10-16): вызов `smartParkingBrake(0)`
РАЗРЕШЁН — штатный API машины; input.event делает контроллер, не наш модуль.

## 3. Температуры двигателя

- Источник истины: `engine.thermals.*` (powertrain/combustionEngineThermals.lua):
  `coolantTemperature`, `oilTemperature`, `engineBlockTemperature`,
  `cylinderWallTemperature`, `exhaustTemperature`, `radiatorFanSpin`.
- `vehicleController.lua:558-559`: `electrics.values.oiltemp` и `watertemp` —
  зеркала `controlLogicModule.oilTemp/waterTemp`, gearbox-логика каждый кадр
  читает `engine.thermals.oilTemperature` / `coolantTemperature`
  (например shiftLogic/manualGearbox.lua:217). При желании можно читать
  electrics, но надёжнее — напрямую thermals.
- **Пороги движка**: coolant damage 120°C, max 130°C, oil damage 150°C
  (combustionEngineThermals.lua:156-158). Рабочий порог 85°C — безопасный запас.
- **КРИТИЧЕСКИЙ ФАКТ**: `startPreHeated = true` захардкожен (строка 146),
  `constants.preHeatTemperature = 80` (строка 150). В `reset()` (строки
  1498-1506) ВСЕ температуры стартуют с **80°C**, а не с температуры
  окружения (tEnv). Следствие: стандартный спавн — «почти тёплая» машина;
  с80→85 греется за ~5-15 с, т.е. **минимум 10 с будет доминировать почти
  всегда**. Долгий холодный прогрев — только если thermals инициализированы от
  tEnv (initThermals, строки 1617-1624 — при холодном окружении).
- Доступ из vehicle-модуля: `powertrain.getDevicesByType('combustionEngine')` →
  `dev.thermals` (паттерн уже в нашем autopilotLive.lua:61-79 для CSV).
- Электрокар: combustionEngine отсутствует → «прогревать нечего», EV-путь.

Решение по критерию (ответ координатора 2026-10-16): done когда
`coolant >= temp_threshold_c (85)` И `oil >= oil_threshold_c (60)`, либо по
`max_timeout_s (120)`. Масло медленнее — компромиссный порог 60°C.

## 4. Как AI включается; что при aiDriving=false

- Vehicle AI: `ai.setMode` (ai.lua:6192), `M.mode = 'disabled'` по умолчанию
  (строка 7). Включение ванильного автопилота — НАША зона не в Фазе 5.
- НАШИ модули при `aiDriving=false` пассивны: wheel не пишет steering_input,
  pedals не пишут Override. Значит wheel/pedals ON при выключенном автопилоте
  безопасны — модули ждут aiDriving.
- `auto_engage_after_warmup` = включить НАШИ wheel/pedals (GE шлёт команды on),
  ванильный AI НЕ трогаем: игрок включит автопилот сам, когда поедет.
- ai.lua:1856-1865: для трафика машина с ignitionLevel 0/1 считается «стоящей»
  — наш прогрев (ignition ≥2) сбрасывает это состояние корректно.

## 5. Точка потребления steering_input (для sway)

- `input.lua:675-678`: каждый input-event пишет
  `electrics.values[k .. "_input"]` — т.е. `steering_input` перезаписывается
  движком каждый кадр из input-потока (AI шлёт FILTER_AI, игрок — KBD/PAD).
- Схема Фазы 4 подтверждена работой wheel-модуля: запись нашего значения в
  `updateGFX` переживает кадр и применяется следующим физшагом. Warmup sway
  пишет `electrics.values.steering_input` той же схемой.
- **Нюанс порядка хуков**: порядок updateGFX у расширений не гарантирован
  алфавитом; `autopilotLiveWarmup.lua` обычно грузится раньше
  `autopilotLiveWheel.lua` — если wheel engaged, его запись идёт ПОСЛЕ нашей и
  затирает sway.
- Решение координатора (2026-10-16), вариант B: при wheel engaged свей
  ОТКЛЮЧАЕТСЯ с INFO-сообщением (wheel.lua не трогаем). Обычный прогрев — до
  включения AI/wheel — работает всегда.

## 6. GE-слой: команда и включение модулей

- Паттерн: консольный глобал `apl_xxx(mode)` в
  `lua/ge/extensions/autopilotLive/main.lua` → `sendToVehicle('...Cmd.on("conf")')`
  через `veh:queueLuaCommand` (main.lua:138-156).
- Конфиги кладутся в `mods/unpacked/AutopilotLive/ai/config/*.json`, путь
  относительный от userPath (У2).
- GE знает `wheelRequested`/`pedalsRequested` (main.lua:23-24) — auto_engage
  должен проверять, включены ли уже, и НЕ дублировать on (повторный on в
  wheel/pedals перезагружает конфиг и рестартует плавный старт).
- Сообщение «прогрев завершён»: print в GE-консоль + guihooks.message (HUD,
  паттерн electrics.lua:357) + txt-лог GE.

## 7. State-machine Фазы 5

```
off ──start──> starting_engine ──схватка/timeout──> warming_up ──условия──> done
  ^                  │                                    │                  │
  │                  │ (EV: ignition-2, фаза пустая)      │                  │ (ручник, сообщение,
  └────off в любой фазе───────────────────────────────────┴──────────────────┴── auto_engage)
```

- `starting_engine`: engineRunning>0 уже? → сразу warming_up. Нет: если
  combustionEngine есть — setIgnitionLevel(3); EV — setIgnitionLevel(2); ждём
  engineRunning>0 или `start_timeout_s (10)` → WARN «не завёлся» и дальше по
  таймеру (не блокируем прогрев).
- `warming_up`: elapsed (от start, включая старт) >= `min_time_s (10)` И
  coolant >= 85 И oil >= 60 → done. elapsed >= `max_timeout_s (120)` → done
  (+WARN, если условия не выполнены). Опрос температур — `temp_poll_hz (1)`.
- `done`: одноразово: снятие ручника (если `parking_brake_release_at_end` и
  parkingbrake>0.5) → smartParkingBrake(0); сообщение; сигнал в GE
  (`onVehicleWarmupDone(vehId, elapsed, tempC, autoEngage)`) → GE при
  `auto_engage_after_warmup` шлёт on wheel/pedals (если не включены).
- `off()`: плавное затухание свея (~2 с), двигатель НЕ глушим, ручник не
  трогаем, стоп фиксируется в логе.
- Сброс vehicle (onReset/onVehicleDestroyed): полный reset состояния.
- КПП НЕ трогаем ни в одной фазе (никаких clutch/gear).
