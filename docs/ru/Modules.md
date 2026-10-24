# Модули

soulPilot разделён на GE-слой (Game Engine) и vehicle-слой. Оба слоя используют Lua-модули и явные command-таблицы.

## GE-слой

| Модуль | Ответственность |
|---|---|
| `main.lua` | Тонкая точка входа: require модулей, зависимости, хуки. |
| `modules/logger.lua` | Логи в консоль/файл, выбор каталога данных. |
| `modules/configLoader.lua` | Дефолты, пользовательские override и runtime-конфиги. |
| `modules/vehicleBridge.lua` | GE → vehicle через `queueLuaCommand`, fallback-машина. |
| `modules/commands.lua` | Публичные команды и legacy-алиасы `apl_*`. |
| `modules/master.lua` | Состояние автопилота и включение модулей. |
| `modules/csv.lua` | Запись CSV. |
| `modules/uiBridge.lua` | Мост отладки/UI. |
| `modules/lights.lua` | Автосвет и ночные окна. |
| `modules/popup.lua` | Проверка модели, запуск popup, ночной режим. |
| `modules/pet.lua` | Pet-команда, звук мурчания, обработка отказа. |
| `modules/pain.lua` | Обработка повреждений и восстановление. |
| `modules/diagnostics.lua` | Точки входа диагностики. |
| `modules/diagnostics_graph.lua` | Экспорт графа, диагностика карты, метки. |

## Vehicle-слой

| Модуль | Ответственность |
|---|---|
| `auto/soulPilot.lua` | Ядро vehicle-слоя, CSV/debug, логи. |
| `auto/soulPilotWarmup.lua` | Запуск двигателя, температуры, sway и передача AI. |
| `auto/soulPilotWheel.lua` | Command-таблица руля и покадровый pipeline. |
| `auto/soulPilotPedals.lua` | Command-таблица педалей и покадровый pipeline. |
| `auto/soulPilotLights.lua` | Запись `lights_state`, guard auto/manual, suppress. |
| `auto/soulPilotPopup.lua` | Состояние глаз и интервалы моргания. |
| `auto/soulPilotPet.lua` | Guard и анимация pet. |
| `auto/soulPilotPain.lua` | Мониторинг повреждений. |
| `auto/soulPilotMusic.lua` | Потребление музыки и offset руля. |
| `auto/soulPilotPark.lua` | Vehicle-команды парковки. |

## Конвейер руля

```text
target -> rate limit -> EMA -> lerp -> clamp -> steering_input
```

После прогрева руль инициализируется от нуля (`seed_zero`), чтобы ручное положение не становилось стартовой целью AI.

## Конвейер педалей

```text
raw throttle/brake -> arbitration -> rate limits -> EMA -> lerp -> overrides
```

Жёсткие ограничения тормоза не зависят от масштабирования скорости газа.

## Правила моста

- GE использует только `soulPilotWheelCmd`, `soulPilotPedalsCmd`, `soulPilotPopupCmd`, `soulPilotPetCmd`, `soulPilotLightsCmd`, `soulPilotWarmupCmd`, `soulPilotCmd`.
- `autopilotLive*Cmd` оставлены только как vehicle-side алиасы совместимости.
- Новый код отправляет команды через `vehicleBridge.sendToVehicle`.
