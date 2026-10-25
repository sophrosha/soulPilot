# Настройки

## Источники и приоритет

Настройки ищутся в таком порядке:

1. пользовательские:

```text
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\mod_settings\soulPilot\
```

2. исходные дефолты:

```text
src/config/
```

3. runtime-дефолты развёрнутого мода:

```text
config/
```

Побеждает первый читаемый файл. `dev_mode.py` не изменяет пользовательские файлы.

## Основные файлы

| Файл | Назначение |
|---|---|
| `master.json` | Флаги модулей, режим AI, политика прогрева, `debug_mode`. |
| `wheel.json` | Лимиты руля, EMA, lerp, профиль. |
| `pedals.json` | Скорости газа/тормоза, арбитраж, плавный старт. |
| `warmup.json` | Пороги двигателя, sway, передача AI. |
| `lights.json` | Состояния света, polling, гистерезис. |
| `lights_by_map.json` | Ночные окна для отдельных карт. |
| `popup.json` | Модели, интервалы моргания, debug-задержка. |
| `pet.json` | Длительность, газ, звук и cooldown pet. |
| `pain.json` | Пороги повреждений, stuck/flipped, восстановление. |
| `music.json` | Амплитуды музыки. |
| `parking.json` | Параметры парковки. |
| `graph.json` | Параметры диагностики графа. |

## Логирование

В `master.json`:

```json
"debug_mode": 0
```

При `0` в консоль выводятся только `WARN`/`ERROR` и явные ответы `status`. Значение `1` включает подробные логи модулей. Вывод vehicle-слоя через `aplPrint` подчиняется тому же флагу.

## Прогрев

```json
{
  "timing": { "min_time_s": 10, "max_timeout_s": 30 },
  "engine": { "temp_threshold_c": 75, "oil_threshold_c": 60 },
  "sway": {
    "enabled": 1,
    "amplitude": 0.035,
    "freq_hz": 0.2,
    "fade_time_s": 2,
    "duration_s": 4
  },
  "finish": {
    "auto_engage_after_warmup": 1,
    "ai_mode_after_warmup": "traffic"
  }
}
```

Держите `sway.amplitude` не выше `0.035`. При завершении прогрева sway сбрасывается, а руль инициализируется от нуля.

## Popup

```json
{
  "models": ["bolide", "wigeon", "200bx"],
  "day_min_s": 120,
  "day_max_s": 180,
  "night_min_s": 180,
  "night_max_s": 300,
  "blink_min_s": 1.2,
  "blink_max_s": 1.2,
  "debug_force_blink_delay_s": 0
}
```

- `0` — обычный режим, моргание раз в 2–3 минуты.
- `5` — debug-режим, моргание каждые 5 секунд (работает и ночью).
- Имена моделей сравниваются с basename `vehicle.JBeam`, поэтому полный путь тоже принимается.

## Руль

Текущая настройка:

```json
{
  "mode": "custom",
  "rate_limit": { "steer_rise": 6.0, "steer_fall": 8.0 },
  "ema_tau": { "steer": 0.08 },
  "lerp_tau": { "steer": 0.05 }
}
```

`mode: comfort/sport` включает пресет, `custom` использует явные значения. Comfort: rise/fall `1.8/2.5`, EMA `0.15`, lerp `0.12`.

## Pet

```json
{
  "duration_s": 6.0,
  "sound": {
    "sound_event": "art/sound/apl_pet.wav",
    "pitch": 0.8,
    "volume": 5.0,
    "no_pos": true
  }
}
```

Для мурчания `sound_event` должен быть непустым. GE использует `Engine.Audio.playOnce`, затем fallback `file:<path>`.

## Изменение в игре

- Настройки HUD сохраняются в userPath.
- Консольные команды применяются сразу для большинства модулей.
- После сохранения настроек руля может потребоваться переспавн машины.
