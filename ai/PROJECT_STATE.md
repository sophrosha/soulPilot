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
**Фаза 2: Граф дорог из навиграфа (Экспорт 3) — ЗАКРЫТА (2026-10-12): тест 2.7 на East Coast → фикс бага односторонних links → повторный экспорт → 28/28 PASS (полный) + 24/24 PASS (example), отчёт `ai/notes/phase2_report.md`.**
**Фаза 2.5: Визуализация графа — ЗАКРЫТА (2026-10-12): `ai/notes/graph_viz.py` (graph_full.png + graph_zoom.png + graph.html), тест пользователя — визуализация работает, цели достигнуты (HTML-чекбоксы для фильтрации типов узлов — основной инструмент для Фазы 4).**
**Фаза 3: Сглаживание педалей (Экран 4, vehicle-слой) — В РАБОТЕ (план утверждён пользователем с условиями У1-У5, порядок: 3.1→3.5 → СТОП перед 3.6).**

### Статус шагов Фазы 3 (порядок 3.1→3.7, каждый шаг — отдельный коммит)

- [x] 3.1 `ai/notes/api_research_phase3.md` — находки по исходникам (коммит `dc35779`):
  порядок кадра main.lua:85-90 (ai → input → controller → extensions), Override-механизм
  `electrics.values.throttleOverride/brakeOverride/clutchOverride` (vehicleController.lua:454-457,
  ванильный прецедент cruiseControl.lua/escMeasurement.lua), латентность 1 кадр,
  `ai.isDriving()` (ai.lua:6167-6169, экспорт 6216), parkingbrake-override НЕ существует
  (grep = 0), AI не шлёт clutch, jsonDecode доступен в vehicle-VM, нейтраль = gear "N"|"0".
- [x] 3.2 `ai/config/pedals.json` — все пороги конвейера (секунды/единицы) (коммит `a40b8ab`)
- [x] 3.3 `lua/vehicle/extensions/auto/autopilotLivePedals.lua` — ядро конвейера
      (коммит `74185ca`): rate_limit→ema→lerp (time-constant коэффициенты, frame-rate
      независимые), арбитраж brake>throttle ПОСЛЕ сглаживания, нейтраль gear "N"|"0",
      плавный старт min(time, speed) с обеими рампами, предиктивность с гистерезисом,
      У1: nil-сброс при off/ai-stop/onReset, У2: needInit=sync с raw, ленивый clutch
      (< 0.001 не пишем). Lua интерпретатора нет — баланс блоков проверен эвристикой
      (эталон autopilotLive.lua сходится), логика вычитана вручную.
- [x] 3.4 GE: `apl_pedals("on"|"off"|"status")` (коммит `7de3504`): sendToVehicle
      команд в autopilotLivePedalsCmd, проверка конфига FS:fileExists, pedalsRequested
      в apl_status, сброс при смене миссии
- [x] 3.5 CSV: `*_smoothed` из нашего конвейера (коммит `e283622`): в buildRow —
      autopilotLivePedalsGetState(); берём значения только при engaged (Override
      реально пишется), иначе копии raw; steer не трогаем; 24 колонки без изменений
- [~] 3.6 ТЕСТ пользователем (3 сценария A/B/C) + check_csv.py с новыми чеками:
      чекер ГОТОВ ДО теста (коммит `3f4b637`): режим определяется по данным
      (engaged = |smoothed−raw| > 1e-9), 5а (off: копии) / 5б (idle-строки = raw) /
      5в (диапазон) / 5г (кап rate из pedals.json ×1.2 внутри сегментов, переходы
      исключены) / 5д (конвейер отличается); кап thr учитывает арбитражный срез
      brake_rise/(brake_full−brake_start). Смоук: синтетика A/B/C 21/21 PASS,
      негативный тест (скачок 20 ед/с) — 1 FAIL, эталон CSV Фазы 1 — 17/17.
- [x] 3.6-pre: **`ai/notes/quality_framework.py`** (коммит `760a19c`) — единый
      фреймворк качества (процесс ревью 7 шагов R1-R7, 5 рубрик с весами,
      гейты PRE_COMMIT/PRE_TEST/RESEARCH_CLAIMS, утилиты strip_lua-токенайзер/
      баланс-контроль/гигиена/скоринг) + **`quality_gate_phase3.py`** —
      автоматический гейт Фазы 3 + **`smoke_pedals_csv.py`** — генератор
      синтетики A/B/C для воспроизводимого негативного теста чекера.
      **ГЕЙТ ПРОЙДЕН (exit 0): PRE_COMMIT 7/7, PRE_TEST 5/5, RESEARCH_CLAIMS
      4/4; rubrics: lua_module 16/16, research_doc 10/10, config_json 10/10,
      python_tool 12/12.** Находки при отладке: (а) regex-страйпер Lua врал на
      '--- ...' строках (съедал кавычку) → состоятельный токенайзер одним
      проходом; (б) эвристика баланса не знала standalone `do ... end` (3 шт. в
      GE main.lua) → считает; (в) git() `.strip()` срезал ведущий пробел
      porcelain-первой строки → rstrip.
      **Фактические команды теста 3.6: `apl_debug()` — toggle (ВКЛ: лог + старт
      CSV, ВЫКЛ: стоп CSV + лог; аргументы игнорируются), `apl_pedals("on"|
      "off"|"status")`. Команды `apl_statusCsv` в коде НЕТ — она ошибочно
      попала в первоначальный тест-план (docs-коммит: убрана; CSV стартует
      `apl_debug()`).**
      **ОЖИДАНИЕ: команды теста 3.6 выданы пользователю → прогон → CSV → отчёт.**
- [ ] 3.7 `phase3_report.md` + PROJECT_STATE → СТОП

### Известные факты Фазы 3 (для Фазы 4 — НЕ переоткрывать)

- **Override-механизм для педалей AI найден**, используется ванильным cruiseControl
  (`throttleOverride`): контроллер читает `electrics.values.*Override or input.<k>`
  (vehicleController.lua:454-457); **латентность 1 кадр** (наш хук идёт после
  контроллера: main.lua:90 vs :88); **сброс в nil критичен** (не 0, не последнее
  значение — иначе педаль залипает; nil = возврат на штатный вход).
- Запись в `input.throttle` БЕССМЫСЛЕННА: строка main.lua:86 (input.updateGFX)
  перезатирает его свежим AI-значением до контроллера (:88).
- AI не читает input.* обратно (ai.lua:434-436 — lastCommand из аргументов) →
  петли «перекрыли и AI увидел» нет.
- Известные ограничения (НЕ чинить в Фазе 3): cruiseControl при активном моде
  конфликтует за throttleOverride (штатно не встречается); датчики-читатели
  input.throttle (postCrashBrake, controlModes, telemetryLogger и т.д.) видят RAW;
  controller=dummy без override-ветки не перехватывается.
- **Микро-решения Фазы 3 (api_research_phase3.md §14, для ВЕТО в тесте 3.6):**
  плавный старт снимается, если машина уже едет в момент on; нейтраль = gear
  "N" ИЛИ "0"; арбитраж — после сглаживания; predictive — флаг с гистерезисом;
  CSV smoothed = финальные значения (после арбитража) при engaged, иначе копия raw.
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
- [x] 2.6 graph.example.json — коммит (связный BFS-подграф 20 узлов, вариант (a);
      битые ссылки среза — [INFO] в --example, не WARN)
- [x] 2.7 ТЕСТ пользователем (экспорт + 2 метки apl_mark) → фикс бага
      односторонних links → повторный экспорт → phase2_report.md
      → **ФАЗА 2 ЗАКРЫТА. Фаза 3 только по команде «делай Фазу 3».**

### 2.7a: ДИАГНОСТИКА КАРТЫ (2026-10-12) — тест упал, причина НАЙДЕНА по исходникам
Тест 2.7: `apl_exportGraph()` → WARN «карта не загружена». Разбор по
исходникам ДО правок (по плану пользователя):
- **Причина: баг обращения в моём коде, а не карта.** Глобальное имя
  расширения `map` — это таблица API модуля (`M`), у НЕЁ нет поля `nodes`:
  структура с узлами — локальная переменная модуля (`map.lua:25`
  `local map = {nodes = {}}`), наружу отдаётся через `map.getMap()`
  (`map.lua:3793-3795`); deprecated-ветка `map.map` (`4001-4012`) — только
  ключ `map`. ⇒ `map.nodes` == nil ВСЕГДА, на любой карте (гвард сработал
  корректно — но по ложной причине). Правильный путь: `map.getMap().nodes`.
- **Ленивая загрузка**: навиграф строится не сразу — `map.load()` (= Mload
  с флагом `loadedMap`, `map.lua:3642-3646`), сброс флага — `onMissionLoaded`.
  Кто-то должен его вызвать первым (AI, map API-пользователи).
- **Источники навиграфа**: основной — `DecalRoad` сцены (`map.lua:587+`),
  `map.json` — ДОПОЛНИТЕЛЬНЫЙ «manual road segments» (`map.lua:786-795`);
  отсутствие map.json — не ошибка, просто без manual-сегментов. ⇒
  гипотеза «West Coast без map.json = нет навиграфа» НЕВЕРНА.
- **Команда `apl_mapDiag()`** (коммит Фазы 2): печатает mission/levelDir,
  map API, `map.nodes` (прямой) vs `map.getMap().nodes` до/после
  `map.load()`, существование map.json (FS:fileExists + размер), результат
  `map.findClosestRoad` от позиции игрока. НИЧЕГО не чинит.
- Ожидание: вывод диагностики на West Coast и East Coast → план фикса
  (ожидаемо: доступ через `map.getMap().nodes` + предварительный
  `map.load()` в экспортёре — НЕ чинить без команды пользователя).

### 2.7b: РЕЗУЛЬТАТ ДИАГНОСТИКИ + ФИКС (2026-10-12)
- **East Coast (целевая карта; West Coast ОТМЕНЁН пользователем):**
  `map.nodes (прямой)` = nil, `map.getMap().nodes` = **5439 узлов ДО
  `map.load()`** (buildSerial=1), map.json существует (6981 байт),
  `findClosestRoad(pos)` = (DR269_2, DR269_3, 1.24 м). После `map.load()` —
  buildSerial 2 (перестройка, не первая загрузка) ⇒ граф грузится движком
  автоматически; **`map.load()` в нормальном пути не звать**.
- **Противоречие «API поля = nil, но функции работают» — опечатка в
  диагностике** (`map == 'table'` вместо `type(map) == 'table'`), НЕ ленивая
  метатаблица. Ленивая загрузка расширений (extensions.lua:1167-1184,
  `MT.__index` → `tbl.load`) — к глобальному `map` отношения не имеет.
- **Фикс утверждён пользователем (У1-У3) — коммит `385abf0`:**
  У1: доступ к графу только `pcall(map.getMap)` + полный гвард
  (`type(gm)=='table'`, `type(gm.nodes)=='table'`, `next(gm.nodes)~=nil`);
  поля API-таблицы не читать напрямую (findClosestRoad/map.load — через
  замыкания в pcall). У2: `map.load()` — ТОЛЬКО при пустых nodes (единственное
  место — гвард apl_exportGraph). У3: `build_serial` в meta — из актуального
  `gm.buildSerial` ПОСЛЕ возможного `map.load()`. apl_mapDiag: опечатка
  исправлена, обе строки отчёта (прямой vs getMap) оставлены.
- Документы (api_research_phase2 §1/§3 + ВАЖНО-блок про `map.getMap().nodes`
  и __index extensions; этот файл) — вторым коммитом.
- **ОЖИДАНИЕ: тест 2.7 на East Coast** (`apl_exportGraph()` → отчёт →
  60 с езды + 2–3 `apl_mark` на разных типах участков) → graph_check.py
  --example → коммит graph.example.json (2.6) → phase2_report.md →
  финальный коммит Фазы 2 → СТОП.

### 2.7c: ТЕСТ 2.7 ПРОШЁЛ + НАЙДЕН И ПОФИКСЕН БАГ ОДНОСТОРОННИХ links (2026-10-12)
Тест на East Coast: экспорт (5439 узлов / 5656 рёбер), 2 метки apl_mark
(узлы/рёбра записались, формат edge_id min_max верен). Прогон
`graph_check.py --stats --example`:
- **БАГ (пойман чекером: FAIL «isolated, но есть ребро» + WARN phantom=-5656):**
  links в навиграфе хранятся ОДНОСТОРОННЕ (цепочки next от DecalRoad):
  `A.links[B]` есть, обратного `B.links[A]` может не быть. Доказательство —
  арифметика: сумма |links| == E ровно. Мой degree = |links| был НЕ
  неориентированной степенью → 5098 «dead_end», «приёмники» — isolated,
  degree==2 почти не встречался ⇒ 91% рёбер без radius (артефакт!).
- **Фикс (коммит Фазы 2):** проход A — сбор рёбер + union-смежность
  (O(E)); degree узлов = |union-соседей|; radius/angle/типы — от правильного
  degree; порядок рёбер сортируется по edge_id (детерминизм).
- **radius_m — НЕ баг:** баг-индикатор turn_no_radius == 0; измеренные 506
  шт (медиана 9.9 м, выбросы >1000 м — «почти прямые», Фаза 4 минимизирует
  через min(limit, phys)).
- **isolated 71** — разбросаны по всей карте (медиана 6.7 м до соседа) —
  после фикса станут только настоящие.
- **Связность:** 12 компонент, наибольшая 5199 (95.6%) — норм для навиграфа
  BeamNG; после фикса ожидаем рост.
- **example-meta дополнена** полной копией meta (+note) — чекер --example
  требует mu/warnings.
- Чекеру добавлен флаг `--stats` (распределение radius по классам, перцентили
  радиусов, зона isolated, связность BFS).
- **ОЖИДАНИЕ: повторный `apl_exportGraph()` пользователем на East Coast**
  (перегенерация graph.json/example с фиксом) → graph_check --stats --example
  → 2.6 коммит example → phase2_report.md → финальный коммит → СТОП.

### 2.7d: ФАЗА 2 ЗАКРЫТА (2026-10-12) — повторный экспорт чистый
Повторный `apl_exportGraph()` + чекер `--stats --example`: **28/28 PASS**
(полный) + **24/24 PASS** (example). Фикс односторонних links отработал:
dead_end 5098→62, straight 40→4653, turn 213→289, fork 16→372, crossroads 1→62,
isolated 71→1, radius null 91.1%→12.6% (все остатки — junction, по дизайну),
phantom-WARN исчез. Измеренные радиусы: медиана 72.6 м, p90 390.6 м.
Связность: 12 компонент, наибольшая 5199 (95.6%) — норм для навиграфа BeamNG.
- **Плоскость проверена (для Фазы 2.5/4):** размахи x=2373 м, y=1940 м,
  z=98 м ⇒ **z — вертикаль, x-y — топ-вью**; `direction_deg` сверен на всех
  5656 рёбрах с atan2(dx,dy): **0 расхождений** — схема азимута корректна.
- **Известные ограничения (НЕ чинить, зафиксировано в phase2_report.md):**
  выбросы radius_m > 1000 м — 100 шт (макс 74018.5, артефакт формулы трёх точек
  на почти-коллинеарных; Фаза 4 отсекает min(limit, phys), при необходимости —
  кап `> 10000 → null` в Фазе 4); 1 isolated-узел за игровой зоной (x=1401,
  492.7 м до соседа); «битые ссылки» в example — структурное свойство среза
  (links degree≥3 хранит полных соседей), в чекере для --example = [INFO].
- Коммит 2.6: `graph.example.json` (BFS-срез, вариант (a)) + `marks.csv`
  (образец) + чекер: битые ссылки среза = INFO. Отчёт:
  `ai/notes/phase2_report.md`. **Следующий шаг: Фаза 2.5 «Визуализация
  графа» (graph_viz.py: graph_full.png + graph.html, plotly) — ПЛАН на
  утверждении пользователя; в Фазу 3 НЕ заходить.**

### Фаза 2.5: ВИЗУАЛИЗАЦИЯ ГРАФА — ЗАКРЫТА (2026-10-12)
`ai/notes/graph_viz.py` (коммит `8f2b78e`): один запуск генерит
`graph_full.png` (matplotlib, весь граф сверху: узлы по типам, рёбра — толщина
по speed_limit_kph, цвет radius_m по log10-viridis, null — серые, one-way —
пунктир, метки marks.csv — красные звёздочки, легенда, заголовок из meta),
`graph_zoom.png` (кроп ±100 м вокруг первого crossroads: подписи узлов +
radius/скорость у рёбер), `graph.html` (plotly offline: hover узлов/рёбер,
чекбоксы типов узлов сбоку, метки со звёздочками). Зависимости:
`ai/requirements.txt` (matplotlib==3.11.2, plotly==7.1.0, venv уже установлен).
Кириллица — DejaVu Sans (проверено на рендере). Артефакты PNG/HTML — в
.gitignore через `ai/road/*` (не коммитятся).
- Smoke на graph.example.json: 2 бага пойманы и починены (легенда
  handles/labels; кортеж вместо списка в группах радиусов); путь без меток
  (нет файла/пусто) — работает без ошибок.
- ТЕСТ пользователя: всё работает. Ключевая находка использования: отключение
  straight (82% узлов) через чекбоксы → turn/fork/crossroads читаемо — **в
  Фазе 4 пользоваться HTML + фильтрами**. «Мелко» на full-плане — цена
  размера карты (2373×1940 м на 2400×2400 px), не баг.
- **Заметка на будущее (Фаза 4, НЕ сейчас):** если понадобится регулярно
  смотреть граф на разных участках — опция «несколько zoom-кропов вокруг 5
  случайных crossroads» (graph_zoom_1.png, ...).
- Заголовки PNG/HTML: meta.level на East Coast = 'unknown' (экспортёр не
  получил имя миссии) → fallback-константа 'East Coast' в graph_viz.py.
- **ФАЗА 2.5 ЗАКРЫТА. Фаза 3 — только по команде «делай Фазу 3». СТОП.**

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
- `ai/notes/quality_framework.py` — единый фреймворк качества (рубрики, чек-листы,
  процесс ревью, утилиты Lua-анализа). Импортировать в новые инструменты.
- `ai/notes/quality_gate_phase3.py` — автоматический гейт Фазы 3 (запуск: venv python).
- `ai/notes/check_csv.py` — чекер CSV (Фаза 1 + режим-осознанная проверка Фазы 3).
- `ai/notes/smoke_pedals_csv.py` — генератор синтетики A/B/C для смоука чекера.
- `mod_info/AutopilotLive/mod_info.ini` — метаданные мода.
- `.gitignore` — что из ai/ попадает в git.

## Полезные команды (будут в Фазе 1)

- `apl_debug` — вкл/выкл дебаг-логирование (появится в Фазе 1).
