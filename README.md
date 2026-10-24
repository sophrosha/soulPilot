# AutopilotLive / LivingAutopilot

Мод для **BeamNG.drive 0.39.4**, который делает AI-автопилот живее: плавный руль,
прогрев автомобиля, автоматические фары, звуковые реакции, мурчание, parking-ассистент
и аудио-реактивная отдача от музыки.

> UI — это только настройки. Машина начинает движение только после
> `apl_autopilot("on")`, через Quick Access или бинд.

## Возможности

- **Master-режим** — прогрев, подключение руля/педалей, свет, popup, pain и AI.
- **Плавный руль** — конвейер `rate_limit -> EMA -> lerp`, режимы `comfort` / `sport`.
- **Прогрев** — запуск двигателя, контроль температуры, отключение лишнего вмешательства.
- **Автосвет** — день/ночь, отдельные окна для карт.
- **Audio-Reactive** — Spotify/системный звук через Python: bass/beat/BPM,
  плавная отдача в руль и вибрацию.
- **Pet** — погладить машину, звук мурчания.
- **Popup / Pain** — реакции на события и восстановление после повреждений.
- **Parking** — поиск свободного места, маршрут, остановка, ручник и глушение.
  Поиск идёт по всей карте; если мест нет — безопасная остановка на текущей позиции.
- **Локализация** — RU / EN / UK / BY.

## Требования

- BeamNG.drive **0.39.4**.
- Windows или Linux.
- Для аудио-реактивности — Python **3.11+** (проверялось на 3.13).
- Для Spotify на Windows — **VB-Audio Virtual Cable** (или аналогичный loopback-источник).

## Установка

1. Скачайте релизный `.zip`.
2. Установите его через Mod Manager BeamNG или положите архив в папку модов.
3. Включите мод и полностью перезапустите игру.
4. Заспавните автомобиль.

Для разработки мод можно держать распакованным в:

```text
...\BeamNG.drive\current\mods\unpacked\AutopilotLive\
```

После изменения GE-расширений нужен полный перезапуск игры. Vehicle-модули
перезагружаются при спавне автомобиля.

## Управление

| Действие | Клавиши / команда |
|---|---|
| Autopilot on/off | `Ctrl+Shift+A` |
| Погладить / мурчание | `Ctrl+Shift+P` |
| Прогрев | `Ctrl+Shift+W` |
| Открыть каталог HUD-приложений | `Ctrl+Shift+U` |
| Мастер | Quick Access → AutopilotLive → Мастер |
| Pet | Quick Access → AutopilotLive → Погладить |
| Parking | Quick Access → AutopilotLive → Парковка |

Консольные команды:

```lua
apl_autopilot("on")
apl_autopilot("off")
apl_autopilot("status")

apl_wheel("on")
apl_wheel("off")
apl_wheel("status")

apl_music("on")
apl_music("off")
apl_music("status")

apl_park("auto")
apl_park("cancel")
apl_park("status")

apl_status()
apl_debug_set(true)
```

## Настройки

Дефолтные конфиги лежат в:

```text
ai/config/*.json
```

Пользовательские настройки и настройки UI всегда пишутся в userPath:

```text
%LOCALAPPDATA%\BeamNG\BeamNG.drive\current\settings\autopilotLive\
```

Основные файлы:

| Файл | Назначение |
|---|---|
| `master.json` | что включать при Master on: wheel, pedals, lights, popup, pain, music |
| `wheel.json` | профиль и сглаживание руля |
| `pedals.json` | газ/тормоз |
| `warmup.json` | прогрев |
| `lights.json` | автосвет |
| `music.json` | аудио-реактивные амплитуды |
| `parking.json` | радиус поиска, маршрут, остановка |
| `pet.json`, `popup.json`, `pain.json` | поведение ассистентов |
| `debug.json` | debug-логирование |
| `ui.json` | язык интерфейса |

Файл в `settings/autopilotLive` имеет приоритет над `ai/config`.

## Python и Audio-Reactive

Python-часть нужна только для музыки. Без неё остальные функции работают.

### 1. Окружение

Windows:

```bat
py -3 -m venv ai\venv
ai\venv\Scripts\python.exe -m pip install --upgrade pip
ai\venv\Scripts\python.exe -m pip install -r ai\music\requirements.txt
```

Linux:

```bash
python3 -m venv ai/venv
ai/venv/bin/python -m pip install --upgrade pip
ai/venv/bin/python -m pip install -r ai/music/requirements.txt
```

`ai/venv` не входит в релизный zip — его нужно создать локально.

### 2. Захват звука

Windows, Spotify через VB-Audio Virtual Cable:

1. Установите VB-Audio Virtual Cable.
2. В Spotify выберите вывод **CABLE Input (VB-Audio Virtual Cable)**.
3. В Python-приложении выберите устройство **CABLE Output (VB-Audio Virtual Cable)**.
4. Звук самой игры оставьте на колонках/наушниках.

Linux (PipeWire/PulseAudio):

- выберите monitor-устройство нужного выхода;
- либо направьте Spotify в отдельный virtual sink и слушайте его monitor.

### 3. Запуск

С GUI:

```bat
ai\venv\Scripts\python.exe ai\music\app.py
```

Консольный режим:

```bat
ai\venv\Scripts\python.exe ai\music\app.py --console
ai\venv\Scripts\python.exe ai\music\app.py --console --list
ai\venv\Scripts\python.exe ai\music\app.py --console --device "CABLE Output"
```

В окне приложения выберите устройство и нажмите **Start**. Приложение пишет
`ai/music/current.json` примерно 50 раз в секунду. GE-модуль читает этот файл;
если данные старше ~300 мс, музыкальная отдача сбрасывается в ноль.

### 4. Включение музыки в игре

1. В UI включите **Music** (это только сохранит `enable_music = 1` в `master.json`).
2. Запустите мастер: `apl_autopilot("on")`.

Либо напрямую:

```lua
apl_music("on")
```

Музыка не управляет газом, тормозом или КПП. Она добавляет только небольшие
sway/vibration/beat-смещения к рулю.

## Parking

Паркинг — активное действие, а не модуль, который включается при старте.

```lua
apl_park("auto")
```

Поиск идёт в радиусе `999999` м, то есть фактически по всей карте. Если мест нет,
мод не зависает, а останавливает машину на текущей позиции, ставит ручник и глушит
двигатель. Reverse-stuck watchdog завершает попытку, если AI выбрал заднюю,
но не может сдвинуться дольше 3 секунд.

## Сборка релиза

Из корня мода:

```bash
python build_release.py
```

Результат:

```text
dist/AutopilotLive-<version>.zip
```

Полезные опции:

```bash
python build_release.py --dry-run
python build_release.py --output-dir C:\Temp\apl-release
python build_release.py --version 0.1.0
```

В архив не попадают:

- `ai/venv`, `ai/notes`, `ai/csv`, `ai/logs`, `ai/road`;
- `__pycache__`, `.pyc`, `.tmp`;
- `ai/music/config.json`, `ai/music/current.json`;
- старые звуки, тестовые отчёты, staging-иконки и dev-скрипты.

## Диагностика

```lua
apl_status()
apl_wheel("status")
apl_music("status")
apl_park("status")
apl_debug_set(true)
```

Debug по умолчанию выключен. При включённом debug пишутся подробные сообщения
GE/vehicle; обычный режим оставляет только WARN/ERROR и ключевой статус.

Логи:

```text
autopilotLive_logs/logs/
autopilotLive_logs/csv/
```

## Ограничения

- Мод не вызывает `input.event` напрямую.
- КПП и сцепление не управляются модом.
- AI не должен использоваться на публичных серверах без разрешения владельца.
- Для корректной работы новых GE-расширений нужен полный перезапуск игры.

## Ссылки

- GitHub: https://github.com/sophrosha
- Сайт: https://sophron.ru
- Лицензия: MIT
