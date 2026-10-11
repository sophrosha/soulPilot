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
**Фаза 1: Дебаг + CSV + логи (Экран 2) — ЗАКРЫТА (2026-10-12): тест 1.6 №2 → 17/17 PASS, отчёт `ai/notes/phase1_report.md`. Дальше — только по команде «делай Фазу 2».**
**Фаза 2: Граф дорог из навиграфа (Экран 3) — В РАБОТЕ (2026-10-12): шаги 2.1–2.5 выполнены, следующий — 2.6 (graph.example.json уже пишется экспортёром) + TODO-фикс авто-stopCsv, потом 2.7 тест. После 2.7 — СТОП, ждать команду «делай Фазу 3».**
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
- [x] 1.6 **ТЕСТ В ИГРЕ**: №1 — 14/17 (3 находки → фиксы), №2 — **17/17 PASS**
- [x] 1.7 Итоговый отчёт phase1_report.md + финальный PROJECT_STATE

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
- **План фикса writer'а (утверждён пользователем) — ВЫПОЛНЕН, коммит 3dfc4d8**
  «Fix CSV path resolution: relative from userPath + FS:directoryCreate»:
  `resolveDataDir` → только относительные кандидаты: `mods/unpacked/AutopilotLive/ai/csv|logs/`
  (приоритет), `autopilotLive_logs/csv|logs/` (fallback-страховка, создаётся только если
  основной путь упал — resolveDataDir идёт до первого успеха);
  `dirWritable` → `FS:directoryExists`/`FS:directoryCreate(dir,true)` + probe `io.open`
  **с немедленным `os.remove`** (зонд не остаётся в папке мода);
  `startCsvRecording` → vehicle-слой получает **относительный** путь (vehicle не менялся,
  комментарий в нём «абсолютный» устарел — не трогаем по инструкции), в консоль печатается
  `print('CSV: ' .. realPath)` через `FS:getFileRealPath` (fallback на каталог/относительный).
  НЕ тронуто: vehicle-слой сбора данных, check_csv.py, формат (24 колонки).
  Проба [7] подтверждена пользователем OK: real = userPath/mods/.../ai/csv/apl_test_mod.txt,
  cleanup убрал 5/5 файлов.
- **Следующий шаг:** реальный тест — `apl_debug()` → 30 сек с автопилотом → `apl_debug()`;
  пользователь присылает лог консоли / путь CSV (строка `CSV: ...`).

### 1.6c: ИГРОВОЙ ТЕСТ 1 — CSV РАБОТАЕТ, 14/17 PASS (2026-10-12)
Файл: `ai/csv/2026-10-12_00-32-53_drive.csv` (1657 строк, 88.2 с, 20 Гц — PASS),
лог мода чистый. Три FAIL разобраны — **все три находки, не баги данных**:

1. **gear dtype=int64 — сломан был ЧЕК, а не данные**: pandas выводит dtype по
   содержимому (Lua-строка "1" → int64, кавычки не спасают); сам чек 2b
   противоречил схеме (пример gear "1"). Фикс: проверка кавычек в тексте CSV
   (всегда ставит наш писатель) + допустимые значения gear по
   `vehicleController/shiftLogic getGearName()` (ALLOWED_GEAR: числа −1..10 как
   строки, "P/R/N/D/S/L/2/1", "M1..M10", "S1..S10", ""), вне множества — WARN.
   Коммит `be8f985`.
2. **steer/clutch_smoothed ≠ raw — по 1 строке из 1657 → находка Фазы 1**:
   `vehicle/input.lua:641-648` — ветка FILTER_AI: **руль ИИ движок сам
   rate-limit сглаживает** (строка 643, smootherPAD 4*rateMult), throttle/brake
   — passthrough (646), `inputStabilization` к FILTER_AI не применяется
   (отдельный слой). Фикс: `*_smoothed = raw` (копии) — коммит `499bf97`.
   **Ключевой вопрос Фазы 4 зафиксирован** в api_research_phase1.md §14:
   варианты (a) аддитивно поверх / (b) отключить FILTER_AI для steering /
   (c) input.state.steering.val → input.steering вместо движкового сглаживания.
   Сравнивать наш smoothed в дальнейшем — с RAW (`input.state.steering.val`),
   не с финальным `input.steering`.
3. **stopCsv не доставлен** (WARN «Машина игрока не найдена»): фикс в GE —
   запоминание id машины при старте CSV + `getObjectByID(csvVehicleId)`
   fallback в sendToVehicle + pcall на queueLuaCommand. Коммит `29f7905`.

Документы (schema gear/smoothed-строки, api_research §14 «Открытый вопрос для
Фазы 4», этот файл) — отдельным коммитом.

**Ожидание: тест 1.6 повторно (60 с езды) → 17/17 PASS → шаг 1.7 (phase1_report).**

### 1.6d: ТЕСТ №2 — 17/17 PASS, ФАЗА 1 ЗАКРЫТА (2026-10-12)
Файл `ai/csv/2026-10-12_01-03-01_drive.csv`: 2014 строк / 106.5 с,
последняя строка полная, пустых нет; dt медианный 0.0530 с, макс. 0.0580 с;
`*_smoothed == *_raw` — 0 по всем каналам; gear в кавычках 2014/2014,
значения ['0'..'3'] из ALLOWED_GEAR. **check_csv.py: все 17 проверок PASS.**
Игру закрыли без второго apl_debug() — файл цел (flush каждые ~2 с спас),
штатного стопа не было (см. TODO Фазы 2 ниже).
Отчёт: `ai/notes/phase1_report.md` (шаг 1.7).

## TODO к Фазе 2 (мелкий фикс, НЕ реализовывать вне Фазы 2)

- [x] **Авто-stopCsv при закрытии игры/сессии — ЗАКРЫТ (коммит Фазы 2):**
  хуки `M.onShutdown()` (stopCsvRecording + closeLogFile) и
  `M.onClientPostStartMission()` (остановка + принудительный сброс состояния,
  если машина уже недоступна); `onExtensionUnloaded` оставлен как есть.
  Причина: в тесте №2 Фазы 1 стоп не дёрнулся, спас только flush каждые ~2 с.

## Сделано

- [x] Фаза 0.1: структура папок создана (lua/ge, lua/vehicle, ui, ai/{logs,csv,road,notes,config}, mod_info).
- [x] Фаза 0.2: git init + .gitignore + первый коммит `efe69cf`.
- [x] Фаза 0.2: базовый `mod_info/AutopilotLive/mod_info.ini` (name, author, version 0.0.1, description).
- [x] Фаза 0.3: этот файл.
- [x] Фаза 0.4: ai/notes/architecture.md (черновик архитектуры 8 экранов).
- [x] Фаза 0.5: venv создан в ai/venv, pandas 3.0.6 установлен и проверен импортом.
- [x] Фаза 1 (подготовка): исследование API BeamNG → `ai/notes/api_research_phase1.md` (коммит 4dae978).
- [x] Фаза 1 (У1/У3/У4): точная схема CSV → `ai/notes/phase1_csv_schema.md`.
- [x] Фаза 1: **ЗАКРЫТА 2026-10-12** — шаги 1.1–1.7, тест 17/17 PASS,
      отчёт `ai/notes/phase1_report.md`; ключевые находки — sandbox путей
      (относительные от userPath) и FILTER_AI steering smoothing (input.lua:643).
- [x] Фаза 2 (шаги 2.1–2.3): api_research_phase2.md, graph_schema.md (+правки),
      apl_exportGraph() + ai/config/graph.json.

### Статус шагов Фазы 2 (порядок 2.1→2.7, каждый шаг — отдельный коммит)

- [x] 2.1 `ai/notes/api_research_phase2.md` — навиграф (map.nodes), API, решения
      (коммит `f7ad155`)
- [x] 2.2 `ai/road/graph_schema.md` — схема graph.json/marks.csv (коммит `40a4790`);
      правки пользователя → коммит `3a22f8b`: edges.angle_from_deg/angle_to_deg
      (вместо одного angle_deg — корректно для direction="both"), length_m по
      КОНЦАМ ребра (inPos/outPos, map.lua:174-187, НЕ хорда), лимит
      meta.warnings = 10 + isolated_count + полный список в
      ai/road/warnings.txt (.gitignore)
- [x] 2.3 `apl_exportGraph()` в GE main.lua + `ai/config/graph.json`
      (μ=0.75, порог 20°, шаг 5 км/ч): защита «карта не загружена» (WARN),
      детерминированный обход (сортировка id), явные null через JSON_NULL
      (jsonEncodePretty пишет неизвестные типы как null, utils.lua:417),
      graph.json + graph.example.json (срез 20 узлов) + warnings.txt,
      отчёт в консоль: узлы/рёбра, % рёбер без radius_m (WARN если > 50%),
      isolated, реальный путь через FS:getFileRealPath
- [x] 2.4 `ai/notes/graph_check.py` — 28 проверок по схеме (мета, узлы,
      рёбра, дубликат-инвариант angle_from/to, инварианты полного графа:
      phantom, покрытие, isolated_count); WARN — битые ссылки навиграфа;
      `--example` — полулярный контроль среза (срез нарушает инварианты
      полного графа — они пропускаются). Smoke: синтетика 28/28 PASS,
      негативный тест (4 порчи) — 4 FAIL, exit 1. **Открытие:** пустая
      Lua-таблица пишется как `{}` (utils.lua:394) — links при degree<3 и
      warnings без записей = `{}`; чекер принимает `{}` и `[]`; примечание
      добавлено в graph_schema.md
- [x] 2.5 `apl_mark("комментарий")` → `ai/road/marks.csv` (8 колонок схемы):
      позиция `getPlayerVehicle(0):getPosition()`, ближайший узел — перебор
      map.nodes (min евклид. дистанции), ребро — `map.findClosestRoad(pos)`
      (map.lua:2691/3977, dist = sqrt) → edge_id min_max как в graph.json;
      comment экранируется (кавычки удваиваются, поле в кавычках), числа —
      с точкой независимо от локали (gsub ','→'.'), шапка при первом добавлении,
      WARN если findClosestRoad вернул nil (edge_id пуст)
- [ ] 2.6 graph.example.json — коммит (уже пишется экспортёром из 2.3)
- [ ] 2.7 ТЕСТ пользователем (60 с езды + 2–3 метки apl_mark) → phase2_report.md
      → **СТОП: Фаза 3 только по команде «делай Фазу 3»**

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
