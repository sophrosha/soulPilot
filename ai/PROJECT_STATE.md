# PROJECT_STATE — AutopilotLive

> Главный файл состояния проекта. Обновляется после каждого коммита.
> Читать в начале каждой сессии перед началом работы.

## Что это за проект

**AutopilotLive** — оверлей-мод для BeamNG.drive 0.39.4. Накладка поверх ванильного
автопилота: перехватывает ГОТОВЫЕ выходные сигналы AI (throttle, brake, steering,
clutch) и сглаживает их (lerp + ema + rate limit), чтобы машина ехала плавно и живо.

Мод НИКОГДА не трогает: input.event напрямую, КПП, логику ванильного AI,
исходники игры.

## Текущая фаза

**Фаза 0: Инициализация — ВЫПОЛНЕНА полностью.**
**Фаза 1: Дебаг + CSV + логи (Экран 2) — ШАГИ 1.1–1.5 ВЫПОЛНЕНЫ, ждёт ТЕСТА (шаг 1.6).**
План утверждён пользователем с 5 условиями (У1–У5), ВСЕ 5 условий закрыты:
- У1: точная таблица «колонка CSV ← источник (файл:строка)» →
  `ai/notes/phase1_csv_schema.md`.
- У2: стратегия путей с fallback (основной — `FS:getUserPath() .. 'mods/unpacked/AutopilotLive/ai/...'`,
  запасной — `FS:getUserPath() .. 'autopilotLive_logs/...'`, выбор логируется).
- У3: точные поля ввода выписаны там же (raw = `input.state.<k>.val`,
  итог = `input.<k>`; AI пишет только в input.event, clutch не трогает;
  ассистенты руля к FILTER_AI не применяются — input.lua:641-648).
- У4: в схеме зафиксировано «В Фазе 1 *_smoothed = *_raw, расхождение в Фазе 3–4».
- У5: vehicle-слой = `lua/vehicle/extensions/auto/` (обновлено в architecture.md
  и здесь). Папка `lua/vehicle/autopilotLive/` — НЕ используется (оставлена
  пустой с .gitkeep, удалить при удобстве).

### Статус шагов Фазы 1
- [x] 1.1 `scripts/modScript.lua` — точка входа (коммит 63a907f)
- [x] 1.2 `lua/ge/extensions/autopilotLive/main.lua` — apl_debug()/apl_status(),
      txt-лог, резолв путей с fallback, отправка команд vehicle-слою (63a907f)
- [x] 1.3 `lua/vehicle/extensions/auto/autopilotLive.lua` — CSV 20 Гц по схеме,
      буферизация 64 КБ/~2 c, autopilotLiveCmd.startCsv/stopCsv (ffd7845)
- [x] 1.5 `ai/notes/check_csv.py` — 17 проверок, smoke-тест на синтетике PASS (e2f80c2)
- [ ] 1.6 **ТЕСТ В ИГРЕ (жду пользователя)**: см. шаг 1.6 ниже
- [ ] 1.7 Итоговый отчёт phase1_report.md + финальный PROJECT_STATE

### План теста (шаг 1.6) — выполняет ПОЛЬЗОВАТЕЛЬ, я не запускаю игру
1. Запустить игру, дождаться загрузки (modScript исполняется на старте).
2. В консоли (контекст GE-Lua): `apl_debug()` → ожидаем INFO в логе мода.
3. Проехать ~1 минуту с включённым автопилотом AI.
4. `apl_debug()` ещё раз → стоп записи.
5. Прислать мне пути к файлам (или я сам найду: папка мода ai/csv|ai/logs
   либо fallback `<userPath>autopilotLive_logs/` — какой выбрался, видно в логе).
6. Я гоняю `ai/venv/Scripts/python.exe ai/notes/check_csv.py <файл>` → отчёт.

### 1.6a: ДИАГНОСТИКА (2026-10-12) — CSV НЕ стартует
- Симптом (лог пользователя): `apl_debug()` включается, но
  «Ни один каталог данных не доступен на запись!» — probe-файл не создался
  ни в mods/unpacked/.../ai/csv/ (папка существует!), ни в fallback.
- Гипотеза подтверждена чтением исходников:
  **io.open в GE sandbox ограничен CWD/относительными путями**
  (мекомментарии: mcp/tools/fs.lua:11 «io.open is sandboxed to CWD (the game dir)»,
  mcp/tools/system.lua:97 «sandboxed to relative paths») + io.open не создаёт папки.
- Найден штатный образец записи: mcp/tools/fs.lua write_file —
  `FS:directoryCreate(dir,true)` + `io.open(stripLeadingSlashes(p),"w")`;
  и паттерн ui/options.lua:46 — `writeFile("/ui/...", data)` → попадает в user-папку.
- **Решение: команда `apl_diag()`** (коммит 42eb720) — 6 проб записи
  (rel/rel+mkdir/abs-fwd/abs-bs/writeFile-VFS/writeFile-rel) + реальные пути
  через FS:getFileRealPath + уборка. Ждём вывод из beamng.console.
- НЕ трогаем (по инструкции): vehicle-слой, check_csv.py, формат CSV (24 колонки).
- Планы Б/В на случай полного отказа io.open: Б — запись из vehicle-слоя
  (другая VM), В — print в beamng.log + PowerShell-выцепка.

### 1.6b: РЕЗУЛЬТАТЫ apl_diag() (2026-10-12) — вердикт по sandbox
Прогон 6 проб пользователем (вывод beamng.console):
| # | Проба | Результат |
|---|---|---|
| 1 | `io.open("apl_test.txt","w")` rel без папок | **OK**, лежит в `userPath/apl_test.txt` |
| 2 | `FS:directoryCreate` + rel с папкой | **OK**, `userPath/autopilotLive_logs/...` |
| 3 | абс. путь, прямые слэши | **FAIL** (io.open режет, «No error») |
| 4 | абс. путь, бэкслэши | **FAIL** |
| 5 | `writeFile` VFS `"/..."` | **OK**, попал в userPath |
| 6 | `writeFile` rel | **OK** |
- **Выводы (эмпирика > комментария mcp/fs.lua:11):** CWD фактически = **userPath**,
  не game dir; абсолютные пути в GE-Lua io.open **не работают — забыты навсегда**;
  `FS:directoryCreate` работает; `FS:getFileRealPath` резолвит относительные пути в userPath.
- `writeFile` не годится для CSV (пишет файл целиком, нужен стриминг 20 Гц).
- Проба [7] добавлена (коммит 73d291d): `mods/unpacked/AutopilotLive/ai/csv/`
  через `FS:directoryCreate` + относительный io.open — ждём подтверждения OK.
- **План фикса writer'а (на утверждении):** в `resolveDataDir` только относительные
  кандидаты: `mods/unpacked/AutopilotLive/ai/csv/` (приоритет) и
  `autopilotLive_logs/csv/` (fallback); создание папок через `FS:directoryCreate(dir,true)`;
  GE передаёт vehicle-слою **тот же относительный путь** (vehicle пишет как раньше,
  полученный путь; CWD — свойство процесса ОС, общее для обеих VM).
  Коммит: «Fix CSV path resolution: relative from userPath + FS:directoryCreate».
  НЕ трогаем: vehicle-слой сбора данных, check_csv.py, формат (24 колонки).

## Сделано

- [x] Фаза 0.1: структура папок создана (lua/ge, lua/vehicle, ui, ai/{logs,csv,road,notes,config}, mod_info).
- [x] Фаза 0.2: git init + .gitignore + первый коммит `efe69cf`.
- [x] Фаза 0.2: базовый `mod_info/AutopilotLive/mod_info.ini` (name, author, version 0.0.1, description).
- [x] Фаза 0.3: этот файл.
- [x] Фаза 0.4: ai/notes/architecture.md (черновик архитектуры 8 экранов).
- [x] Фаза 0.5: venv создан в ai/venv, pandas 3.0.6 установлен и проверен импортом.
- [x] Фаза 1 (подготовка): исследование API BeamNG → `ai/notes/api_research_phase1.md` (коммит 4dae978).
- [x] Фаза 1 (У1/У3/У4): точная схема CSV → `ai/notes/phase1_csv_schema.md`.

## Принятые решения (утверждены пользователем)

| Тема | Решение |
|---|---|
| Расположение проекта | Всё в папке мода: git, ai/, lua/. Documents\AutopilotLive не используется |
| Префикс команд | `apl_` (apl_debug, apl_warmup, apl_pet, apl_mark) |
| Термополя CSV | engine_temp, oil_temp, water_temp + thermalEnergy как engine_thermal |
| Прогрев | Порог по температуре (water+oil ≈ 80–90°C), минимум 10 сек, разумный максимум |
| Дефолты | Ночь 20:00–07:00; мурчание 5 сек, повтор = стоп |
| Звук мурчания | 7а — реакции без звука; 7б — отдельное исследование fmod |
| Глазки | Случайный интервал 120–300 сек, без привязки к времени суток |
| Данные в git | md/notes/config — всегда; csv/logs/road — по умолчанию игнорируются, маленькие образцы можно `git add -f` |

## Открытые вопросы

1. **mod_info:** позже может понадобиться thumbnail.jpg и tagline — допишем в Фазе 1,
   когда мод начнёт что-то делать.
2. API-слой для Фазы 1 (какие именно хуки vehicle Lua перехватывают сигналы AI) —
   исследуется чтением исходников игры в начале Фазы 1.

## Важные файлы

- `ai/notes/architecture.md` — черновик архитектуры всех 8 экранов.
- `mod_info/AutopilotLive/mod_info.ini` — метаданные мода.
- `.gitignore` — что из ai/ попадает в git.

## Полезные команды (будут в Фазе 1)

- `apl_debug` — вкл/выкл дебаг-логирование (появится в Фазе 1).
