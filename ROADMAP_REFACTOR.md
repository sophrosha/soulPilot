# soulPilot — Roadmap глобального рефакторинга и ребрендинга

**Статус:** ШАГ 1 — создание roadmap и golden-тестов.  
**Старое имя:** AutopilotLive  
**Новое имя:** soulPilot  
**Репозиторий:** https://github.com/sophrosha/soulPilot  
**LICENSE:** уже лежит в репозитории; не перезаписывать.

---

## 1. Жёсткие правила проекта

### 1.1. Тесты прежде всего

Перед любым изменением поведения сначала пишутся тесты, фиксирующие текущее
поведение. После рефакторинга те же тесты должны давать те же значения
(с допуском только для floating-point).

Запрещено «попутно» менять логику во время переноса файлов или переименований.
Любое изменение поведения — отдельный шаг с отдельным обновлением golden-значений.

### 1.2. Код для людей

- Никаких длинных однострочников с десятком тернарников.
- Сложные выражения разбиваются на именованные переменные.
- Приоритет — читаемость контрибьютором, а не минимальное число строк.
- Магические числа выносятся в константы с понятными именами.

### 1.3. Стиль имён

- Переменные: `snake_case`.
- Функции: `camelCase`.
- Константы: `UPPER_SNAKE_CASE`.
- Имена файлов и модулей: осмысленные, без сокращений, кроме общепринятых
  (`config`, `utils`, `ui`, `ge`, `vehicle`).

### 1.4. Логи и комментарии

- Только на английском языке.
- Русский текст удаляется из кода, логов, комментариев и сообщений об ошибках.
- Пользовательские строки UI выносятся в локализацию, а не хардкодятся в Lua.

### 1.5. Глобальные переменные

- Не засорять `_G`.
- Публичные имена — только с префиксом `soulPilot_` или через таблицу/namespace.
- Для GE-моста использовать `extensions.soulPilot_*`, а не произвольные глобалы.
- Если `_G` действительно необходим, оставить только документированный минимум:
  `_G.soulPilot_main` и совместимый bridge-доступ.
- Старые глобалы `autopilotLive_*`, `apl_*`, `autopilotLiveWheelCmd` и т.п.
  удаляются после переходного периода. На время миграции допускаются алиасы,
  покрытые тестами.

### 1.6. DRY

Одинаковые циклы, таблицы, парсеры, клампы и конфиг-хелперы выносятся в общие
утилиты. Не копировать один и тот же код в GE и vehicle без необходимости.

### 1.7. Утилиты

- GE: `lua/ge/extensions/soulPilot/utils/`.
- Vehicle: `lua/vehicle/extensions/auto/utils/`.
- Утилиты не должны зависеть от конкретного модуля.
- Общие математические операции: clamp, move-toward, EMA, safe-number,
  config merge, path helpers.

### 1.8. Модульность

- Файл больше 300–400 строк — кандидат на разделение.
- Большой модуль получает папку: `name_module/`.
- Внутри — секции: pipeline, watchdog, config, status, commands.
- Пример: `pedals/pedalsPipeline.lua`, `pedals/pedalsWatchdog.lua`.
- UI также делится на компоненты, composables и утилиты, а не остаётся одним
  гигантским `app.vue`.

### 1.9. JSON-конфиги

- Полностью удалить ключи `_comment` из конфигов.
- Схема и назначение полей документируются в `docs/`.
- JSON остаётся валидным и читаемым.
- Дефолты не должны содержать пользовательские пути и машинно-зависимые данные.

---

## 2. Новая структура проекта

```text
soulPilot/
├─ src/                         # сам мод
│  ├─ lua/
│  │  ├─ ge/extensions/soulPilot/
│  │  │  ├─ main.lua
│  │  │  ├─ modules/
│  │  │  └─ utils/
│  │  └─ vehicle/extensions/auto/
│  │     ├─ soulPilot*.lua
│  │     ├─ modules/
│  │     └─ utils/
│  ├─ ui/modules/apps/soulPilot/
│  ├─ art/sound/
│  ├─ mod_info/
│  ├─ config/                   # дефолтные JSON без _comment
│  └─ tests/                    # golden/behavior tests (не в релизном zip)
├─ src_music/                   # Python из старого ai/music, разбитый на модули
├─ docs/
│  ├─ ai/                       # Dev-заметки: PROJECT_STATE.md, ARCHITECTURE.md, AGENTS.md
│  ├─ lang/
│  │  ├─ gelua/                 # Описание функций, переменных и алгоритмов GE-слоя
│  │  └─ vlua/                  # Описание функций, переменных и алгоритмов Vehicle-слоя
│  ├─ ru/
│  │  ├─ FAQ.md
│  │  ├─ Installing.md
│  │  ├─ Modules.md
│  │  ├─ Settings.md
│  │  ├─ Dev.md
│  │  └─ AI.md
│  ├─ en/
│  │  ├─ FAQ.md
│  │  ├─ Installing.md
│  │  ├─ Modules.md
│  │  ├─ Settings.md
│  │  ├─ Dev.md
│  │  └─ AI.md
│  └─ readme.md                 # навигация: Предыдущая | На главную | Следующая
├─ assets/                      # логотипы и изображения для README
├─ README.md
├─ .gitignore                   # ai/, venv/, __pycache__, dist/, *.zip
├─ LICENSE
├─ migrate_structure.py        # one-time migration tool (Step 2)
└─ ROADMAP_REFACTOR.md
```

### 2.1. Пути конфигов

- Дефолтные конфиги читаются из `src/config/`.
- Пользовательские настройки сохраняются строго в:

```text
userPath/settings/mod_settings/soulPilot/
```

- Папка `ai/` — dev-workspace: отчёты, временные логи, заметки, CSV.
- `ai/` не входит в релиз и игнорируется git.

### 2.2. Релиз

Релизный zip собирается только из `src/` и необходимых корневых файлов.
В архив не попадают:

- `ai/`;
- `venv/`, `.venv/`;
- `__pycache__/`, `*.pyc`;
- `dist/`, `*.zip`;
- `src/tests/`;
- dev-отчёты и временные файлы.

---

## 3. Архитектура модулей

- Базовый файл (`main.lua` или `soulPilot*.lua`) содержит инициализацию,
  регистрацию команд, загрузку модулей и минимальный setup.
- Бизнес-логика — в `modules/`.
- Общие операции — в `utils/`.
- Большие модули делятся по секциям:

```text
modules/
└─ pedals/
   ├─ pedalsConfig.lua
   ├─ pedalsPipeline.lua
   ├─ pedalsWatchdog.lua
   └─ pedalsStatus.lua
```

- UI-структура повторяет принцип: компоненты, composables, утилиты, локализация.
- Никакой модуль не должен знать о внутренностях другого модуля больше, чем
  через явный публичный API.

---

## 4. Ребрендинг и карта переименований

### 4.1. Пользовательские имена

- Видимое имя: `soulPilot`.
- Старое `AutopilotLive` удаляется из UI, README, app metadata, Quick Access,
  локализации и имени папок.
- `LivingAutopilot` в About заменяется на `soulPilot` (или согласованный
  подзаголовок), без старого имени.

### 4.2. Технические имена

| Старое | Новое |
|---|---|
| `autopilotLive_main` | `soulPilot_main` |
| `autopilotLive_uiConfig` | `soulPilot_uiConfig` |
| `autopilotLiveWheelCmd` | `soulPilotWheelCmd` |
| `autopilotLiveParkCmd` | `soulPilotParkCmd` |
| `autopilotLiveMusicCmd` | `soulPilotMusicCmd` |
| `apl_autopilot` | `soulPilot_autopilot` |
| `apl_wheel` | `soulPilot_wheel` |
| `apl_park` | `soulPilot_park` |
| `apl_music` | `soulPilot_music` |
| `ai/config` | `src/config` |
| `settings/autopilotLive` | `settings/mod_settings/soulPilot` |

На время миграции разрешены старые алиасы, но они должны быть:
1. явно помечены как legacy;
2. покрыты тестами;
3. удалены до релиза.

### 4.3. `_G` policy

- `_G` используется только для реально необходимого GE/vehicle bridge.
- Основной namespace: `soulPilot`.
- Не создавать глобалы вида `wheel`, `parking`, `config`, `utils`.
- Каждый глобальный символ должен быть перечислен в `docs/en/Dev.md` и
  `docs/ru/Dev.md`.

---

## 5. Стратегия golden-тестов

### 5.1. Принцип

Golden-тесты фиксируют **текущее** поведение до переноса и переименования.
Они не должны зависеть от расположения файлов: путь к конфигам ищется через
resolver (`src/config` → `ai/config` на время миграции).

### 5.2. Где лежат

```text
src/tests/test_behavior.py
```

Запуск:

```bash
python -m unittest discover -s src/tests -v
```

### 5.3. Что тестируется в первую очередь

1. **Wheel pipeline** — `rate_limit → EMA → lerp → clamp`.
   - первый кадр;
   - несколько кадров;
   - `rateScale`;
   - смена направления;
   - отсутствие перерегулирования.
2. **Конфиг руля** — `mode=custom`, значения 6.0/8.0, ema 0.08, lerp 0.05
   на момент старта рефакторинга.
3. **JSON-контракты** — все конфиги валидны, числа конечны, ключи на месте.
4. **Parking** — радиус 999999, наличие fallback-поведения, отсутствие
   `enable_parking` в master.
5. **Master flags** — parking не включается мастером, музыка/руль/педали
   управляются флагами.
6. **Конфиг-приоритет** — user override важнее default; после переезда
   путь `settings/mod_settings/soulPilot`.
7. **Reverse-stuck watchdog** — 3 секунды, скорость < 0.5 км/ч, вызов finish.
8. **Wheel double-on** — повторный `on()` не сбрасывает `needInit`.
9. **UI-контракты** — нет Parking в настройках; язык RU/EN/UK/BY; нет `??????`.
10. **Переименование** — нет старых имён в публичных путях/командах/UI
    после удаления legacy-алиасов.
11. **Сборка** — zip не содержит dev-каталогов и содержит обязательные файлы.
12. **Локализация** — все ключи UI есть во всех четырёх языках.

### 5.4. Правило обновления golden-значений

Если намеренно меняется поведение (например, новый тюнинг руля), сначала
обновляется тест с явным описанием причины, затем код. Не наоборот.

---

## 6. Этапы рефакторинга

### ШАГ 1 — Roadmap и golden-тесты

- [x] Создать `ROADMAP_REFACTOR.md`.
- [x] Зафиксировать правила и структуру.
- [x] Создать первые golden-тесты `src/tests/test_behavior.py`.
- [x] Проверить, что тесты проходят на текущем коде (10/10 OK).
- [x] Зафиксировать baseline-значения в golden-тестах.

### ШАГ 2 — Каркас новой структуры

- Создать `src/`, `src/config/`, `src_music/`, `docs/ai/`,
  `docs/lang/gelua/`, `docs/lang/vlua/`, `docs/ru/`, `docs/en/`, `assets/`.
- Перенести `lua/`, `ui/`, `art/`, `mod_info/` в `src/`.
- Перенести `ai/music/` в `src_music/`, `ai/notes/` — в `docs/ai/`.
- Перенести `ai/config/` в `src/config/`.
- Переименовать `autopilotLive` → `soulPilot` в `src/lua/` и `src/ui/`
  (имена файлов, папок и текст `.lua`/`.json`/`.vue`).
- Обновить пути конфигов:
  - default: `src/config`;
  - user: `settings/mod_settings/soulPilot`.
- Обновить `.gitignore` (`ai/`, `venv/`, `__pycache__/`, `dist/`, `*.zip`).
- Golden-тесты должны пройти без изменения ожидаемых чисел.
- Миграция выполняется один раз:

```bash
python migrate_structure.py
```

- Проверка после миграции:

```bash
python -m unittest discover -s src/tests -v
```

### ШАГ 3 — Ребрендинг

- Переименовать папки, extension names, command names, UI app id.
- Добавить legacy-алиасы только там, где нужен переходный период.
- Обновить локализацию, README, docs, Quick Access, keybinds.
- Убедиться, что старые имена не отображаются пользователю.

### ШАГ 4 — Модульность и utils

- Вынести общие clamp/EMA/move-toward/config helpers в `utils/`.
- Разбить файлы >300–400 строк.
- Начать с `pedals`: pipeline, watchdog, config, status.
- После каждого split — golden-тесты.

### ШАГ 5 — Конфиги

- Удалить все `_comment`.
- Описать схему в `docs/ru/Settings.md` и `docs/en/Settings.md`.
- Проверить миграцию старых пользовательских конфигов.
- Убедиться, что дефолты не содержат машинно-зависимых данных.

### ШАГ 6 — UI

- Разделить `app.vue` на компоненты/composables.
- Оставить Parking только как активное действие / Quick Access.
- Проверить языки, fallback, отсутствие `??????`.
- Обновить навигацию docs.

### ШАГ 7 — Python / Audio

- Перенести `ai/music` в `src_music/` с разделением на модули.
- Убрать зависимость от старого `ai/` в runtime.
- Обновить инструкции по VB-Audio/PipeWire.
- Проверить, что release не содержит venv и пользовательский config.

### ШАГ 8 — README, docs, assets

- Переписать README под soulPilot.
- Добавить `docs/readme.md` с навигацией
  «Предыдущая | На главную | Следующая».
- Заполнить `docs/ru/*` и `docs/en/*`.
- Добавить логотипы в `assets/`.

### ШАГ 9 — Релиз

- Удалить legacy-алиасы.
- Обновить `build_release.py` под `src/`.
- Проверить чистый zip.
- Прогнать все тесты.
- Обновить LICENSE/README ссылки на `sophrosha/soulPilot`.

---

## 7. Definition of Done

- Все golden-тесты проходят.
- Нет русского текста в коде/логах.
- Нет `_comment` в JSON.
- Нет старых публичных имён `AutopilotLive`/`apl_*` после релиза.
- Нет необоснованных `_G`-глобалов.
- Файлы не превышают разумный размер; большие модули разбиты.
- Дефолтные конфиги лежат в `src/config`, пользовательские — в
  `settings/mod_settings/soulPilot`.
- `ai/` не входит в git/release.
- README и docs описывают установку, настройки, Python/audio и разработку.
- Тесты можно запустить одной командой.
