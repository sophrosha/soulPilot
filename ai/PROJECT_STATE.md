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
**Фаза 3: Сглаживание педалей (Экран 4, vehicle-слой) — ЗАКРЫТА (2026-10-12, прогон #3: 21/21 PASS, Н1 закрыта, clutch-passthrough подтверждён).**
**Фаза 4: Сглаживание руля (Экран 4, vehicle-слой) — ЗАКРЫТА (2026-10-15): прогоны 4.6/4.7/4.8 PASS на Civetta Bolide + Gavril T-Series (чекер 21/21), вариант (c) — перезапись electrics.values.steering_input в хуке :90, граф-торможение решено НЕ строить (ванильный AI уже делает backward-pass), Fix 5b (прыжок при on) данными не подтверждён; + отдельный хотфикс педалей Gavril Fix 1-5 (`53ae9c6`, тест 5 PASSED). Отчёт `ai/notes/phase4_report.md`. В Фазу 5 НЕ заходить — ТОЛЬКО по команде.**
**P1 (разбор жалоб игрока, pedals) — ЗАКРЫТ (2026-10-15): качели raw = AI+Gavril (A/B: OFF-прогоны 4.7-B/4.8 дают качели БЕЗ модуля), перелом «плавно→резко» = первый цикл круиз-логики AI (t≈46.9–47.8), clutch = ванильная КПП (наш модуль passthrough, 5г′ — 0 лагов), чекер 22/22 в обоих прогонах. Отчёт `ai/notes/phase4_analysis_P1_final.md`. Открыто (по команде): аномалия status 1.9e17, тюнинг throttle/brake, фикс комментария clutch.**
**ФАЗА 4 ЗАКРЫТА ОКОНЧАТЕЛЬНО (2026-10-15, поздний вечер): аномалия brake.out ~1e17 (позже ЗАКРЫТА 16.10 — см. статус-строку ниже; отчёт `ai/notes/phase4_analysis_anomaly.md`); жалоба «педали на Gavril как без модуля» — данными ОПРОВЕРГНУТА (лаг sm от raw 0.22–0.32 с, corr 0.99–1.00, сброс −17→−3.1 ед/с; «резкость» = сбросы/циклы ванильного AI, см. phase4_report §7); wheel на Gavril РАБОТАЕТ (out ≠ raw подтверждено, §8); чекер свежего CSV 26/26 (после уточнения гейта 5ж — см. «Хвосты» ниже).**
**ХВОСТЫ ФАЗЫ 4 ЗАКРЫТЫ (2026-10-15): гейт чекера 5ж уточнён 1e-3 → 0.05 (вариант A, обоснование в коде чека; 5е/5з не менялись; CSV 20-00-38 — 26/26 PASS); clutch-комментарий «AI НИКОГДА не пишет clutch» исправлен в pedals.lua (3 места) + §7/§15 api_research_phase3.md — логика passthrough НЕ менялась. Дальше Фаза 5 — ТОЛЬКО по команде.**
**ДИАГНОСТИКА ОЩУЩЕНИЙ «педали как без модуля» (2026-10-15, ночная сессия 22:55) — МОДУЛЬ РАБОТАЕТ, ДЕГРАДАЦИИ НЕТ:** свежий CSV 22-56-34 (чекер 26/26): торможения AI 0.92→sm 0.28 / 0.55→0.26 / 0.73→0.39 (в 2–3 раза мягче), сброс газа AI до 0 → модуль удержал 1.00 ещё 0.46 с; стартов с места в прогоне НЕТ, скриншот status — крошечные значения (thr 0.08, steer −0.010) — сглаживанию нечем проявиться. Все 17 CSV за 12–15.10: метрики Gavril 13.10 vs 15.10 ИДЕНТИЧНЫ (gap thr ср 0.032–0.045, d(sm)/dt макс 1.88–3.94, %>1.0 = 1.2–2.1%) — «потеря переменной/откат» опровергнуты (pedals.json не менялся с 12.10 12:41, git линейный без revert, сессия шла на актуальном коде; «rate limit exceeded» в логах сессии 22:55 отсутствует). «Смена на Bolide» телеметрией 22:55 НЕ подтверждена (один vehicle 46054, тот же мод-лог-хендл = был СБРОС, не switch; после сброса apl_debug() не вызывался → CSV второй части нет). Косметика DIAG (diagFmt: <1e-6 → 0.000000, мусор — как есть + «<МУСОР>», логика не менялась). Отчёты: ai/notes/phase4_analysis_pedals_feel.md, ai/notes/phase4_analysis_all_logs.md. **ВСЁ ЗАКОММИЧЕНО (`5cb4138`, `62ada45`); серия фикса аномалии — 2026-10-16, см. следующую статус-строку.**
**АНОМАЛИЯ brake.out ~1e17 ЗАКРЫТА (2026-10-16): артефакт %.3f в LuaJIT string.format при большом числе аргументов — ДОКАЗАНО кадром игрока (в одном кадре %.3f = 6.7e17 при DIAG exact = 0.0 и чистом lastOut). Фикс: все числовые поля status/WARN/эхо в pedals/wheel переведены на diagFmt/tostring (%s), логика конвейера НЕ менялась; кольцевой буфер ловушки — на конкатенацию с tostring (forensic-точность сохранена). Ловушка («последний рубеж» + буфер 5 кадров + DIAG exact) оставлена как страховка от РЕАЛЬНОГО бага кода. Отчёт переписан в финальное состояние: `ai/notes/phase4_analysis_anomaly.md`. Gavril per-vehicle конфиг — отложен игроком (основная машина сейчас — Civetta Bolide, к Gavril вернёмся позже).**
**ФАЗА 5: ЗАКРЫТА (2026-10-18) — ФИНАЛЬНЫЙ ТЕСТ ПРОЙДЕН, ПОЛЬЗОВАТЕЛЬ В ВОСТОРГЕ («всё работает как надо»).** Итог: warmup state-machine (off → starting_engine → warming_up → done; завод electrics.setIgnitionLevel(3)/(2), минимум 10 с, done = coolant≥75°C И oil≥60°C либо таймаут 30 с), ручник smartParkingBrake(0) в finish(), сигнал GE + HUD «прогрев завершён, машина готова», auto_engage (только НАШИ wheel/pedals, при =1, без дублирования). SWAY: кубический синус amplitude·sin³ (0.035 ≈ 3.5°, 0.2 Гц — «плоские пики», дыхание), РАНДОМНОЕ окно события [1-8 с + 4 с] при каждом start, вариант B при wheel engaged. Пороги/таймаут/свэя — в warmup.json (правимо без кода); DEFAULTS синхронизированы; финальные правки 18.10 (75°C/30с/0.035/0.2) устранили WARN на холостых (65-75°C). Артефакты: `ai/notes/api_research_phase5.md`, `ai/config/warmup.json`, `lua/vehicle/extensions/auto/autopilotLiveWarmup.lua`, `apl_warmup` в GE, `ai/notes/phase5_report.md`. Коммиты Фазы 5: `a34df63` (5.1) → `ede7198` (5.2) → `f3f83a5` (5.3) → `adb44d8` (5.4) → `cd7f167` (5.5) → `aec9619` (5.6 куб.синус+окно) → `d23bcba` (доки) → `d000a44` (рандом-окно) → `f1ee8d3` (5.8 пороги/свэя/TODO) → (этот коммит — закрытие). Контракты соблюдены: wheel/pedals/КПП не тронуты, input.event напрямую не дёргается, ванильный AI не включается автоматически. Задача по педалям закрыта (18.10). Дальше — **Фаза 6 (фары день/ночь): ТОЛЬКО PLAN, код до утверждения.** В Фазу 7 не заходить.
**ЗАДАЧА ПО ПЕДАЛЯМ (анализ логов) — ЗАКРЫТА (2026-10-18): координатор ПРИНЯЛ выводы phase4_analysis_all_logs.md (деградации нет, переменная не терялась). Фикс 2.45e-59 (DIAG exact) — ПОДТВЕРЖДЁН ЗАКОММИЧЕНЫМ: diagFmt в pedals/wheel.lua (коммиты `62ada45` + `9d0dfe4`, grep даёт 10+ вхождений). TODO по педалям больше не висит.**
**ФАЗА 6 (фары день/ночь): ЗАКРЫТА (2026-10-18).** План утверждён координатором 18.10, код (шаги 6.1-6.5) + калибровки + быстрая команда night_state — всё проверено игроком в игре: дальний свет (night_state: 2) включается, `apl_lights("night_state", 2)` работает, гистерезис на границах дня/ночи корректен, ручное вмешательство отключает auto, на Bolide сработала pop-up защита (отказ auto, Фаза 8 — ждём). Реализовано: auto включается ТОЛЬКО командой игрока, дальний в auto — только из night_state: 2 (или вручную far), гистерезис ±15 мин без step-переходов, ручное вмешательство → авто-отключение («Ручное управление, авто-режим отключен»), pop-up guard (bolide/wigeon — Фаза 8), окна карт East Coast 18:40 / Italy 18:20 / Utah 18:20 / РФ-дефолт 20:00 (lights_by_map.json), `apl_mark` пишет игровое время [ЧЧ:ММ]. Закрытие: коммит «Phase 6 closed...». Чистка 18.10 (решение координатора): lights.json — дефолт РФ 20:00-07:00 и night_state: 1 (игровой след теста откачен), запись utah в lights_by_map.json убрана (остались East Coast 18:40 и Italy 18:20). **Дополнение 19.10 (Ф8): pop-up guard (bolide/wigeon) СНЯТ по решению координатора — auto-свет Ф6 на этих моделях работает.** В Фазу 7 — план (код не писать до утверждения). В Фазу 8 НЕ заходить.

**ФАЗА 7 ЗАКРЫТА (2026-10-19).** Финальное состояние (правки после 3 тестов 18.10): механика — руль ×0.5 на время эффекта (`autopilotLiveWheelCmd.setRateScale`, возврат 1), лёгкий газ `throttleOverride = env·(0.05 + 0.05·sin(2π·2.5Гц·t))` → 0..0.1 (лимит ≤0.15), тормоз НЕ используется (сломал физику во 2-м тесте), фиксация — ручник `controller.mainController.smartParkingBrake(1)/(0)` (штатный vehicleController.lua:428), guard'ы: на ходу ≥5 км/ч отказ «НЕЛЬЗЯ гладить на ходу», спам → «кошачье устало» (4 за 30 с → кулдаун 20 с). Команды: GE `apl_pet("on"|"off"|"status")`, конфиг `ai/config/pet.json` (throttle/sound/cooldown — правки без кода), vehicle `autopilotLivePet.lua`. ЗВУК ОТЛОЖЕН: текущий `event:>Engine>Shutoff>v8_20xy_eng` — предварительный (playOnce-оверлап 0.5 с, volume 2.0, позиция машины, фолбэк `no_pos`), игрок пришлёт финальный event позже (см. phase7_report «Ограничения / TODO»). Отчёт: `ai/notes/phase7_report.md`. В Фазу 9 НЕ заходить.

**ФАЗА 8 (Pop-up фары / «Глазки»): КОД НАПИСАН (2026-10-19), ОЖИДАЕТСЯ ТЕСТ ИГРОКОМ.** План `ai/notes/phase8_plan.md` утверждён координатором 19.10 с ответами: (1) моргание — **Вариант А** (через `setLightsState`, штатный API — свет мигает вместе с выездом фар); (2) guard Ф6 `refuse_auto_on_popup` **СНЯТ** (удалён из GE `main.lua` и `lights.json` — авто-свет Ф6 на Bolide/Wigeon теперь работает, ночью фары выедут сами); (3) интервалы подтверждены: день 120–180 с, ночь 180–300 с, blink 1.5–2 с. Реализовано: конфиг `ai/config/popup.json` (интервалы + `models` + `debug_force_blink_delay_s` — тест-режим: >0 = ВСЕ интервалы = N сек, напр. 5 — моргает каждые 5 с), GE `apl_popup("auto"|"off"|"status")` (вкл только командой, guard по `playerJBeam` — только bolide/wigeon, ночь считается по окну lights через `gameTodHours`+`inNightWindow` и шлётся vehicle при смене), vehicle `autopilotLivePopup.lua` (таймер → `setLightsState(1)` → blink 1.5–2 с → `(0)` ТОЛЬКО при выключенном свете; горящий свет = подавление, таймер стоит; ручное вмешательство игрока → auto OFF + WARN; переходы Ф6-auto через `isLightsAuto()` — НЕ вмешательство), **совместимость с Ф6**: `autopilotLiveLightsCmd.setSuppress(v)` (на время мигка авто-логика Ф6 молчит — мигок не считается их interrupt) + `isAuto()` (в vehicle-модуле Ф6, 2 метода). Сброс `popupAuto` в onClientPostStartMission. Тик ночи в `M.onUpdate` (~2 с, только при popupAuto). Чек `apl_check8.py` — ALL OK (баланс 3 Lua, JSON ×2, guard в коде отсутствует, input.event-вызовов нет). **Тест игроком: см. команды в phase8_plan.md §5 (начать с `popup.json` → `debug_force_blink_delay_s: 5`).** В Фазу 9 НЕ заходить.

**ФАЗА 8.1 (2026-10-24): инверсия глазок + прогрев + watchdog педалей + руль.** Решения координатора: ночью моргание подавлено; `ai_mode_after_warmup` по умолчанию `"traffic"`.
- **Popup (инверсия):** в покое глаза ОТКРЫТЫ (`lights_state=1`, горят как ДХО), моргание = ЗАКРЫТИЕ на 1.2 с и возврат в 1. Разделить гидравлику и лампы НЕЛЬЗЯ: `lowhighbeam` пересчитывается КАЖДЫЙ кадр из `lights_state` (electrics.lua:407/433), hydros читает его же (hydros.lua:301) — выбран вариант «свет 1 в покое». НОЧЬЮ моргание подавлено. Ручное вмешательство игрока (не переход Ф6-auto) → auto OFF + WARN. `stop()` больше НЕ гасит свет (было опасно ночью); `onReset` → awake; `sleep/wake_up` работают и без auto (сценарий прогрева), wake восстанавливает прежний state (дальний не ломается); в Ф6 добавлен `getTarget()` — blink не выполняется, если target ≠ 1. `debug_force_blink_delay_s` в файле = 0.
- **Warmup:** при `on()` → `popup.sleep()` (глаза закрыты), в `finish()` → `wake_up()`; `off()` (отмена прогрева) → `wake_up()`. Новая опция `finish.ai_mode_after_warmup` (default `"traffic"`, `""` = AI не включать): ИСПРАВЛЕН инвертированный guard (`if not ai` → `if ai and ai.setMode`), вызов через GE (`ai.setMode(mode)`, `ai.setDriving(true)`), whitelist режимов; auto_engage wheel/pedals — отдельно.
- **Pedals watchdog:** `osClockHP` у AI-событий ПУСТОЙ (ai.lua:438 — source="ai", timestamp=nil) → собственные таймеры: `rawHoldT` (сколько raw не меняется) и `stuckT` (`out>0.9` при `raw<0.05`); >2 с → WARN + дамп `diagDump` + **ресинк конвейера на raw**. Status дополнен: `input.throttle`, `electrics.values.throttleOverride`, `source`, контроллер, watchdog-таймеры.
- **Wheel:** `steer_rise 3.5→6.0`, `steer_fall 5.0→7.0`, `ema_tau 0.06→0.04`, `lerp_tau 0.08→0.05` (JSON + DEFAULTS) — прежний кап был МЕДЛЕННЕЕ ванильного FILTER_AI (~4 ед/с, input.lua:644).
- **`ai/notes/report_generator.py`:** глубокий отчёт (каналы min/max/p95/p99, лаг и corr raw↔sm, % кадров на капе, скачки >1.2·кап, залипание газа ≥2 с, недоход руля на пиках, аномалии) с `--md/--json`; смоук на реальном CSV 2026-10-12_07-23-49 пройден.
- **Гигиена:** `autopilotLivePopupOld.lua`/`autopilotLiveWarmupOld.lua` убраны из `extensions/auto` (игра грузила их как дубли) → `ai/notes/legacy/` (в .gitignore). Чек: баланс 6 Lua-файлов OK, JSON ×3 валидны, report_generator компилируется.

**ФАЗА 8.2 (2026-10-24, фиксы по логам beamng.log):** логи показали: Bolide 110–768 с, **768.8 спавн us_semi (Gavril T-Series)**, метки «pod 90…» (866.5) и «GRM PIZDA NAHUI» (1002.4) — обе на грузовике; `apl_pedals ON` 814.4.
- **Pedals:** причина «газа 100%» — `needInit` при resume AI сидил `pipe := raw` (Gavril часто паузит/возобновляется). Фикс: сид из **`lastOut.throttle`** (+smooth_start_cap), **жёсткий кламп** `thrOut ∈ [prev−fall·dt, prev+rise·dt]` после всех модификаторов (тормоз не клампится), watchdog молчит 0.5 с после resume, prints `AI ПАУЗА/RESUME` и параметров on().
- **Warmup-AI:** `ai.setMode`/`ai.driveInLane` — API **vehicle-VM** (ai.lua:6233/6236), GE-вызов был no-op. Теперь вызов из vehicle (для traffic + `driveInLane("on")`), через 0.5 с print `ai.mode/isDriving/gear`.
- **Popup:** ложное «вмешательство» (288.99: `lastSeen=0` при `lights_state=1`) — убрано перечитывание state после `applyEyes`; `updateGFX` держит 0 при `warmupHold` даже без auto; print state до→после в sleep/wake.
- **Ночь:** GE keepalive `setNight` каждые 5 с (не только при смене) + print с часом (на смене и каждые 30 с keepalive).
- **Sway:** окно 3–10 с, громкий print `SWAY START` при входе в окно.
- **auto_csv=1:** `apl_pedals("on")`/`apl_wheel("on")`/`apl_warmup("start")` сами стартуют CSV (apl_debug больше не обязателен).

**ФАЗА 8.3 (2026-10-24, по отчёту CSV и логам):** прогрев+AI приняты игроком («идеально», не трогаем).
- **Pedals:** `throttle_rise 2.0 → 1.2` (газ 0→100% ≈0.83 с; «1,2,3…100»), DEFAULTS синхронизированы (1.2/3.0). **Жёсткий кламп тормоза** добавлен (brake_rise/fall) — раньше needInit/фолбэки проскакивали кап, отчёт видел 3.02/с при капе 2.5.
- **Popup:** найден баг — после правки потерялся `local cur = curState()` → `nil ~= lastSeen` давал мгновенное «АВТО-ОТКЛЮЧЕНО (lights_state=nil)» (лог 215.7 и далее). Вернули чтение state ДО проверки; добавлен heartbeat `TICK awake` раз в 10 с и консольный print «моргание отложено (причина)».
- **report_generator:** скорость скачка считается по dt конкретной пары строк (было — медиана; алиасинг давал ложные +20%).

**ФАЗА 8.4 (2026-10-24, по CSV `2026-10-24_01-27-11`):** подтверждено данными — в «застрявших» эпизодах газа 99% `brake_smoothed` держался в `(0,0.02)` 583 из 584 кадров, gear=1, rpm≈2650; там, где brake_out=0 (t=25–35.8), КПП переключалась (0,2,3,4,5).
- **Pedals:** `brakeOverride = nil` при `brkOut < 0.02` — ванильный апшифт требует `M.brake <= 0` (automaticGearbox.lua:355), микро-хвост сглаживания блокировал передачи. Watchdog «газ >0.9 ≥5 с» независимо от raw (print gear/rpm/brakeOut раз в 5 с). Ramp-print каждые 0.2 с при росте газа (видно шаги 0.1→0.3→0.6→1.0). Status: gear/rpm/electrics.values.throttle/brakeOverride/gasHigh.
- **Popup:** ночью `awake` **не трогает state** (раньше форсил 1 — затирал дальний, «слабые фары»); `wake_up` ночью оставляет state как есть. Приборка: отдельной electrics-переменной НЕТ (grep electrics.lua: dashboard/interior/gauge = 0) — разделить с фарами нельзя без правки JBeam; ночью моргания нет вообще.
- **report_generator:** новый детектор «газ >0.9 ≥3 с (независимо от raw)» с таблицей t0/t1/передачи/rpm/raw/brake + FAIL при отсутствии переключений; max_rate по dt строки. На историческом CSV: 5 эпизодов, 4 без переключения — детектор работает.

**ФАЗА 8.7 (2026-10-24, по тесту игрока):** руль (comfort) одобрен.
- **Petmode:** машина уезжала без ИИ — ванильный контроллер сам снимает smart-ручник при `throttle > 0` (vehicleController.lua:526). Фикс: `setHandbrake(1)` **каждый кадр** в updateGFX (обход ванильного авто-снятия); `setHandbrake(0)` в finish. Газ 0.05–0.10 случайно каждые 0.2 с (было sin 2.5 Гц), руль плавно 1→0.5 за 1.5 с, guard «двигатель не заведён».
- **Wheel:** новый `mode` в wheel.json: `comfort` (3.5/4.0, ema 0.05, lerp 0.06) / `sport` (6.0/7.0, 0.04/0.05) / неизвестный = числа из файла (`custom`). Пресет имеет приоритет над числами.
- **Popup/ночь:** прямой `setNight` сразу после `apl_popup("auto")` + print результата отправки; vehicle печатает `START получен — night=...`; keepalive печатает `sent=true/false`. Диагностика «GE НОЧЬ / vehicle false».
- Звук: `Engine.Audio.setPitchMultiplier` в 0.39.4 отсутствует — питч двигателя из Lua не меняем (playOnce pitch=0.7).

**ФАЗА 8.9 (2026-10-24): звук петмода — GE `Engine.Audio.playOnce`.** Рабочий путь — **чистый VFS без `file:` и без ведущего слэша**: `art/sound/apl_pet.wav` (проверено игроком: `playOnce('AudioGui','art/sound/apl_pet.wav',{volume=2})` звучит). Один вызов при `apl_pet("on")` (файл 10 с > 6 с петмода), volume 2.0, pitch 0.8. Vehicle-слой звук НЕ создаёт: `createSFXSource`/`playSFX` крашили FMOD (`failed to load ... through FMOD`), per-source delete в API нет. Газ в петмоде убран (только звук + руль + force-ручник), в warmup finish добавлены `apl_popup("auto")` + `apl_lights("auto")` через GE.

**ФАЗА 9.1 (2026-10-24): «Система Боли» — авто-восстановление.** Включается ТОЛЬКО `apl_pain("auto")`; конфиг `ai/config/pain.json` (пороги/кулдаун/warmup_after/restore_ai).
- **Vehicle `autopilotLivePain.lua`:** детекторы 1 Гц — STUCK (`ai.isDriving()` + газ ≥ порога + скорость ≤ порога дольше `stuck_time_s`), FLIPPED (`getDirectionVectorUp():dot(0,0,1) < flipped_up_dot` дольше `flipped_time_s`), DAMAGE (порог; `getSectionDamageSum()` доступен только в GE — шлётся `setDamage` каждые 2 с). Guard'ы: не трогает при прогреве (`warmupCmd.getState()`) и поглаживании (`petCmd.isActive()`), кулдаун.
- **GE `apl_pain("auto"|"off"|"status")`:** STUCK/FLIPPED → `spawn.teleportToLastRoad(veh,{resetVehicle=true})`, fallback — `map.findClosestRoad` + `veh:setPosRot`; DAMAGE → `be:resetVehicle(0)` (reset/repair на месте). После — `autopilotLiveWarmupCmd.on(conf,{noSway=true})` и `ai.setMode("traffic")` при `restore_ai=1`.
- **Warmup:** `on(confPath, opts)` + `opts.noSway` (быстрый прогрев); геттеры `warmupCmd.getState()`, `petCmd.isActive()`.

Ожидается тест игроком: авария/переворот/status. В Фазу 9 (LiDAR и пр.) не заходить без команды.

**ФАЗА 10.2 (2026-10-24): встроенное радиальное меню (Quick Access) — РАБОТАЕТ.** Отдельный Vue-виджет НЕ делаем. `lua/ge/extensions/autopilotLive/quickAccessMenu.lua`: `core_quickAccess.addEntry` (официальный экспорт, quickAccess.lua:2753) — вкладка **AutopilotLive** (иконка `steeringWheelSporty`, categoryOrder −40) рядом с «Ремонт»/«ИИ», содержимое на третьем уровне `/root/sandbox/apl/` (на втором уровне quickAccess ждёт только категории с `goto`, иначе FATAL на строке 1669): кнопки **«Живая тачка»** (master toggle) и **«Погладить»** (apl_pet on), обе возвращают `{'hide'}`. Регистрация через хук `onRegisterQuickAccessMenus` + страховка `onExtensionLoaded` (идемпотентно). Бинд `apl_ui_toggle` открывает вкладку: `core_quickAccess.toggle('/root/sandbox/apl/')`. GE: `petActive` (для статуса), геттеры `apl_autopilotState()`/`apl_petActive()`, загрузка меню из `main.lua`. Ошибка «attempt to index field 'goto'» исправлена переносом действий на третий уровень.

**ФАЗА 10.3 (2026-10-25): ощущения.** (1) «Режим овоща» после ремонта/телепорта: `autopilotLivePedalsCmd.setRateScale(0.5, 3.0)` — throttle_rise/fall ×0.5 на 3 с (таймер в pedals, авто-возврат 1.0); вызывается из GE `painRecover`. (2) AI после ремонта включается ТОЛЬКО при `masterState=='on'` (иначе машина не едет сама). (3) Мост урона: `setDamage(value, seq)` через `veh:queueLuaCommand` (sendToVehicle — fallback), print SEND/RECV для диагностики. (4) Подруливание на прямых добавлено и **удалено** по фидбеку («выглядит неестественно») — руль просто следует raw. (5) Фикс `clampNum` в pedals (был FATAL в setRateScale).

**ФАЗА 10.6 (2026-10-25): мост vehicle→GE — КОРЕНЬ ВСЕХ БАГОВ, ЗАКРЫТА.** Игрок подтвердил: warmup, master, wheel, QuickAccess, pain — все 5 работают.
- **Причина:** GE-консоль и `queueGameEngineLua` исполняются в песочнице, где `_G.autopilotLive_main` не виден, даже если extension-загрузчик сделал `rawset(_G, extName, M)`. `extensions.load` также кладёт модуль в таблицу `extensions[extName]`, а таблица `extensions` — вайтлист-глобал песочницы.
- **Фикс:** в конце `lua/ge/extensions/autopilotLive/main.lua` — `_G.autopilotLive_main = M` **и** `extensions.autopilotLive_main = M`. Во всех 8 vehicle-модулях (`autopilotLive`, Lights, Pain, Pedals, Pet, Popup, Warmup, Wheel, ~57 вызовов) коллбэки вызываются через `extensions.autopilotLive_main.X(...)` с guard'ом `if extensions and extensions.autopilotLive_main ...`.
- **QuickAccess:** `onRegisterQuickAccessMenus` сбрасывает `registered=false` и пере-регистрирует вкладку ПОСЛЕ построения стандартного дерева (ранняя регистрация из `onExtensionLoaded` не видна).
- **Wheel (финальный комфорт):** `"mode": "comfort"`, пресет comfort = rise/fall **6.0/8.0** (быстрый трекинг raw, без PIO), `ema_tau 0.10`, `lerp_tau 0.08`; DEFAULTS и числа JSON синхронизированы. Виляние ушло ещё на 6/8 + малых tau; 0.10/0.08 убирают остаточную резкость.
- Диагностика после полного перезапуска: `extensions.isExtensionLoaded('autopilotLive/main')`, `extensions.autopilotLive_main ~= nil`, vehicle→GE `GE_EXT=true`.

**ФАЗА 12.2 (2026-10-25): Vue-UI + локализация (каркас).**
- `ui/modules/apps/AutopilotLive/`: `app.json` (`domElement`, `directive=autopilotLive`, `vue=true`, interactive), `app.vue`, `app.png`. Приложение автоматически попадает в каталог HUD Apps (`ui_apps.getAvailableAppList`).
- `app.vue`: вкладки Overview/Music/Steering/Parking/About, переключатель Normal/Expert. Normal — BngSwitch для Master/Lights/Music/Parking (Parking = apl_park auto/cancel), Expert — BngSlider для `sway_amp`, `vibration_amp`, `beat_amp`, `beat_decay_s`, `steer_rise/fall`, `ema_tau`, `lerp_tau`, скорости/радиусы паркинга. Save шлёт `{files={...}}` в GE.
- `lua/ge/extensions/autopilotLive/uiConfig.lua`: `getConfig()` (значения master/wheel/music/lights/popup/pet/pain/pedals/warmup/parking + состояние), `setConfig()` (deep-merge, sanitize, запись в ai/config), `setModule()` (вызовы apl_autopilot/apl_lights/apl_music/apl_park/apl_wheel/apl_popup), `getState()`. Загружается из main.lua.
- Локализация: `locales/translations/{en-US,ru_RU,uk_UA,be_BY}/autopilotLive.translation.json`, ключи `apl.ui.*`, `apl.modules.*`, `apl.fields.*`, `ui.apps.apl.*`; fallback en-US. Для uk/by используются канонические папки `uk_UA`/`be_BY`.
- Бинд `apl_ui_toggle` (Ctrl+Shift+U): открывает `pause.hudApps.selector` с поиском «AutopilotLive» (fallback — Quick Access). Первый раз приложение добавляется в HUD-раскладку через каталог, дальше доступно как HUD-app.
- Проверки: app.vue компилируется через `@vue/compiler-sfc`; JSON/Lua (luaparser) OK; uiConfig в LuaJIT-моке читает/пишет конфиги и вызывает модули.

**ФАЗА 12.3.3 (2026-10-25): Языковой dropdown + блок LivingAutopilot.**
- Язык: вместо 4 кнопок — одна кнопка с текущим кодом и выпадающим меню вверх; `langOpen`/`currentLanguage`, закрытие по клику вне; смена языка мгновенная, сохранение в `ui.json`.
- About: белая заглушка `apl_preview_ui.png` удалена; добавлены LivingAutopilot, версия, описание, источники, автор/лицензия и две ссылки с белыми кружками GH/WEB.
- Локализация: +9 ключей `apl.about.*` в en-US/ru_RU/uk_UA/be_BY (по 62 ключа), локальные словари app.vue обновлены.

**ФАЗА 12.3.2 (2026-10-25): UI — только настройки.**
- `uiConfig.setModule` пишет только `enable_*` в `settings/autopilotLive/master.json` и возвращает true/false; никаких apl_music/apl_lights/apl_park/apl_autopilot/callGlobal. Parking — флаг `enable_parking` (не запуск); Master — `enable_master`.
- `stateTable` читает сохранённые флаги master.json (UI показывает настройки, не live-состояние).
- `app.vue.toggleModule` — только `setModule(id,next)` + локальная галочка; физических команд нет.
- Язык: 4 кнопки RU/EN/UK/BY, `lang` ref меняется сразу (реактивность), выбор пишется в `ui.json`; локальные словари en/ru/uk/by с fallback en; исправлены реальные `??????` в JSON (UTF-8 без BOM).
- Иконка General: `settings` → `cogOutline` (settings — группа иконок). Sidebar 220px, rows 40px, группы 24px, границы 1px, ползунок 3px/параллелограмм, тумблер 36×20, `scrollIntoView({block:'start'})`.
- `master.json`: `enable_master`, `enable_parking`.

**ФАЗА 12.3 (2026-10-25): UI в стиле BeamNG + userPath-конфиги + debug.**
- `app.vue`: нативный экран настроек с левой навигацией (иконки, активный пункт оранжевый, hover серый), группы в рамках, тёмный фон, один экран. Размеры: sidebar 220px, строки 40px, панели/отступы 24px, границы 1px. Тумблеры овальные, профиль руля `< >`, плоские ползунки с параллелограммным бегунком и числовым полем. Normal/Expert, Debug Logging. Заглушка `apl_preview_ui.png` (белая) в About.
- `app.vue`: локальные словари en/ru/uk/by с fallback на en (устраняет `??????` даже если game-locale не загрузился), селектор языка внизу слева; выбор пишется в `settings/autopilotLive/ui.json`, по умолчанию берётся `core_locales.getLanguage()`. Навигация использует `scrollIntoView({block:'start'})`.
- **Master в UI — только настройка:** `setModule('master')` пишет `master.json.enable_master` и НЕ вызывает `apl_autopilot`; физический запуск — только `apl_autopilot("on")` / Quick Access.
- `settings/autopilotLive/*.json` — источник записей UI; `ai/config/*.json` — дефолты. `readJsonFile`/`configPath` в main, vehicle-модули wheel/pedals/warmup/music/parking/lights/master/popup/pain используют userPath.
- Дефолты UI: music/lights/wheel/popup пишут `master.json.enable_*`; `masterFinish` перечитывает конфиг и не включает музыку, если UI её выключил.
- Debug: `debug.json` + `apl_debug_set`; флаг в vehicle; частые vehicle-print на `aplPrint`, WARN/ERROR/status остаются; OFF по умолчанию.
- Quick Access: третья кнопка «Парковка» → `apl_park("auto")`.
- Проверки: @vue/compiler-sfc, luaparser, uiConfig LuaJIT-мок (userPath, master save-only, language, debug), JSON переводов.

**ФАЗА 12.1.1 (2026-10-25): Parking audit — маршрут только по связному навграфу.** По тесту: AI чуть не врезался в столб, поехал через лес и остановился посреди дороги.
- Причина: `wpTargetList` — список **последовательных целей**, а не готовый маршрут; при неполном/пустом `getPointNodePath` и fallback `map.getPath` можно было отправить одну/несвязанные точки → AI ехал напрямик. Плюс не был включён traffic-режим до маршрута.
- `parking.lua`: убран fallback `map.getPath`; только `map.getPointNodePath(pos,node,0,1e4,nil,nil,4)`.
- Строгая валидация: `#path >= 2`; все узлы есть в `map.nodes`; каждое ребро подтверждено `links` в одну из сторон; машина не дальше 15 м от дороги; первый узел ≤80 м от машины; последний узел ≤ `max_spot_road_dist_m+arrival_radius_m` от spot. Иначе `failed_route`, маршрут не отправляется.
- Перед маршрутом: `ai.setMode("traffic")`, `ai.setPullOver(false)`, `ai.setSpeedMode("limit")`; в `ai.driveUsingPath` передаётся **одна достижимая цель** `{targetNode}` с `driveInLane="on"`, `avoidCars="on"`, `routeSpeedMode="limit"`.
- Диагностика: `apl_park("route")` печатает длину `routePath`, `targetNode`, координаты target/spot, каждый узел и наличие связи с предыдущим.

**ФАЗА 12.1 (2026-10-25): Parking Mode P1 — поиск, маршрут, остановка.** Без quit (P3).
- `ai/config/parking.json`: радиусы поиска/дороги, arrival, route speed, stop/hold, ручник/зажигание, таймауты; `quit_game` зарезервирован.
- GE `autopilotLive/parking.lua`: `apl_park("auto"|"cancel"|"status")`. Поиск через `extensions.gameplay_parking` (`getParkingSpots`→`findParkingSpots`→`filterParkingSpots{standardSize,checkVehicles,useProbability=false}`), проверка `ps.vehicleFits` и расстояния до навграфа (`map.findClosestRoad`). Маршрут: `map.getPointNodePath`/`getPath`, отправка `ai.driveUsingPath({wpTargetList=..., routeSpeedMode="limit", avoidCars="on", driveInLane="on"})`. Тик 5 Гц: approach → `beginStop`; таймауты маршрута/остановки, stuck-детектор; `fail` = AI stop без глушения.
- Vehicle `autopilotLivePark.lua`: `beginStop` → `ai.setMode("stop")`, ожидание speed ≤ stop_speed в течение hold_s, затем `smartParkingBrake(1, FILTER_DIRECT, true)` + `electrics.setIgnitionLevel(0)` (автомат P/N), callbacks `onVehicleParked/onVehicleParkFailed` в GE (через `extensions.autopilotLive_parking`). Cancel не снимает ручник.
- `main.lua`: загрузка `autopilotLive/parking`.
- Ограничение P1: AI останавливается у ближайшей дорожной точки к parking spot; точный заезд/задний ход — P2. Если sites нет — `apl_park` возвращает ошибку, без имитации парковки.
- Проверки: LuaJIT-моки — поиск/маршрут/arrival/callback, ручник/зажигание, timeout; luaparser/JSON OK.

**ФАЗА 11.4 (2026-10-25): мягкий beat без «кочки».** Игрок: при ударе бита руль резко «подбивался», как на кочке. Причина — мгновенный импульс 0.01 на фронте beat.
- `ai/config/music.json`: вместо `beat_kick_amp/beat_kick_ms` — `beat_amp=0.01`, `beat_decay_s=0.2` (attack фиксирован 0.05 с в коде).
- Vehicle `autopilotLiveMusic.lua`: `beatEnv` плавно растёт `dt/0.05` до 1 и спадает `dt/beat_decay_s` до 0; к рулю добавляется `beatEnv*beat_amp` через `autopilotLiveMusicGetBeatKick()` (имя сохранено, wheel не меняется по логике). Никаких ступенек: первый кадр даёт ~0.0032 вместо 0.01.
- Wheel: по-прежнему `clampSym(pipe.out + drive + beatEnv*amp)` после сглаживания; park-ветка добавляет то же к `steering_input`.
- Проверки в LuaJIT-моке: rise 0.0032→0.0064→0.0096→0.01 за 4 кадра; fall до 0 за ~0.2 с; lights_calls пуст.

**ФАЗА 11.3 (2026-10-25): реакции музыки — beat в руль, мягче бас.** По фидбеку игрока (амбиент даёт слишком сильную дрожь; фары не нужны):
- `ai/config/music.json`: `lights_pulse=0` (фары от музыки отключены по умолчанию; старый код пульса сохранён, включается обратно флагом), `sway_amp=0.005`, `vibration_amp=0.001`, `vibration_hz=6.0`; новые `beat_kick_amp=0.01`, `beat_kick_ms=90`.
- Vehicle `autopilotLiveMusic.lua`: `bass_smooth` EMA (`bassSmooth += (bass-bassSmooth)*min(dt*5,1)`) используется для качка/вибрации; на фронт beat — затухающий импульс `beat_kick_amp*(1-age/dur)` через `autopilotLiveMusicGetBeatKick()`. Фары не трогаются при `lights_pulse=0` (popup не блокируется).
- Wheel: `outVal = clampSym(pipe.out + drive + kick)` после сглаживания; на стоянке `applyParkMusic` добавляет `park + kick` к текущему `steering_input` (после warmup-sway).
- Проверки в LuaJIT-моке: lights_calls пуст при lights_pulse=0; kick 0.01 на фронте и 0 через 90 мс; bassSmooth нарастает; конфиг/синтаксис OK.

**ФАЗА 11.2 (2026-10-25): Spotify/Audio-Reactive — UI + Lua-интеграция.**
- **UI `ai/music/ui.py`:** PySide6-окно (выбор устройства, Start/Stop, полоски Bass/Beat, BPM, статус/ошибки). Захват и FFT в `QThread`; на Windows worker сам делает `CoInitializeEx(MTA)`, устройство переоткрывается по имени. Настройки (`device`, `device_index`) — `ai/music/config.json` (gitignore). `app.py` по умолчанию открывает GUI, `--console`/`--list`/`--seconds` — консоль; без PySide6 — автоматический fallback в консоль.
- **GE `lua/ge/extensions/autopilotLive/music.lua`:** читает `mods/unpacked/AutopilotLive/ai/music/current.json` каждые 50 мс, парсит `jsonDecode`; свежесть по `seq` (нет нового > 300 мс → bass/beat=0); ночь — `extensions.autopilotLive_main.isNightNow()` раз в 1 с; шлёт `autopilotLiveMusicCmd.set(bass,beat,bpm,night)`; `start()` повторяется раз в 5 с после respawn. Команда `apl_music("on"|"off"|"toggle"|"status")`. Загружается из `main.lua`.
- **Vehicle `autopilotLiveMusic.lua`:** на стоянке (`speed <= 3 км/ч`) — качок руля `sin(2π·0.6·t)·0.02·bass`; в движении (`>=5 км/ч`) — вибрация `sin(2π·10·t)·0.002·bass`; оба через хук в `autopilotLiveWheel.lua` ПОСЛЕ сглаживания (park-offset добавляется к текущему `steering_input` после warmup-sway). Свет: на фронт beat пульс через popup (`lights_state 0↔1`, `pulse 120 мс`, мин. интервал 200 мс, state 2 и ночь не трогаем); пока музыка владеет светом, popup не моргает (`musicHold`).
- **Конфиг `ai/config/music.json`:** скорости/амплитуды/частота, `lights_pulse`, `pulse_ms`, `blink_min_interval_ms`; клампы в vehicle.
- **Безопасность:** газ/тормоз/КПП не трогаются, `input.event` не вызывается; при stale/off/pain/pet приоритет у штатных систем; после respawn GE переотправляет start.
- **Проверки:** UI offscreen с `CABLE Output` — start/stop, JSON пишется, config сохраняется; GE-модуль в LuaJIT-моке — set/start/stop, stale→нули; vehicle-модуль в моке — пульс 1→0, park/drive offset, release при движении. Синтаксис Lua — luaparser OK.

**ФАЗА 11.1 (2026-10-25): Spotify/Audio-Reactive — Python-каркас (консоль).** Кроссплатформенный захват через `soundcard`: Windows — WASAPI loopback, Linux (Arch) — PulseAudio/PipeWire monitor-источники. Для Spotify на Windows используется VB-Audio Virtual Cable (Spotify → `CABLE Input`, захват `CABLE Output`).
- `ai/music/requirements.txt`: soundcard, numpy, PySide6 (GUI позже; консоли PySide6 не нужен).
- `ai/music/capture.py`: список устройств (`--list`), выбор по индексу/подстроке, `BassAnalyzer` — FFT 2048 + Hann, полоса 40–150 Гц, dB→0..1 по `[db_floor..db_ceil]` (по умолчанию −50..−3), attack 5 мс / release 150 мс. Beat: spectral flux + гистерезис (спад ниже порога, min gap 200 мс, beat держится 120 мс для Lua), BPM — медиана интервалов, fold 60–200. Кириллица в stdout не падает при перенаправлении.
- `ai/music/publisher.py`: атомарная запись `current.json` (temp + `os.replace`, 8 ретраев на Windows-лок Lua) + UDP 127.0.0.1:7771; поля `seq,t,bass,bass_db,beat,bpm,rms,rms_db,paused,rate,block,source`.
- `ai/music/app.py`: захват → анализ → публикация 20 Гц (фазовый аккумулятор, а не «не чаще 50 мс»), `paused=true` после 2 с тишины, финальный кадр `bass=0,paused=true`; флаги `--no-file/--no-udp/--out/--publish-hz`.
- Проверки: реальный loopback (WAV 120 BPM через динамики) — bass_max 0.92, BPM 117.8; синтетика 128 BPM — 127.8; атомарность при чтении 20/50 Гц — 0 ошибок; `--list` на Windows находит 7 устройств.
- Дальше: PySide6 UI (Фаза 11.2), затем GE `music.lua` + vehicle-реакции. Отложено: PipeWire-бэкенд через `parec`/`pw-record`, если soundcard не увидит monitor-источник.

**ФАЗА 9.2 (2026-10-24): Система Боли — калибровка и escalation.** Игрок замерил шкалу: целая машина `damageSum≈0`, разбитая в хлам — **4181.7** ⇒ это ОЧКИ, не проценты. `damage_threshold 0.5 → 2500` (pain.json + DEFAULTS GE/vehicle). STUCK больше не требует `ai.isDriving()`: газ (игрок или AI) + скорость ≤ порога дольше `stuck_time_s`. Status печатает raw `damageSum` и порог (GE и vehicle), плюс raw в консоль каждые 10 с при `auto`. DAMAGE: `be:resetVehicle(0)`, через 2 с проверка `getSectionDamageSum()`; escalation `spawn.teleportToLastRoad`. Коммит `cdc8267`; фикс синтаксиса `apl_pain` — `7fa4336`.

**ФАЗА 9.3 (2026-10-24): Система Боли — надёжное восстановление (ЗАКРЫТА).** `spawn.teleportToLastRoad` не поднимает полностью убитую машину (ok, но позиция не меняется). Новый порядок для ВСЕХ видов (DAMAGE/STUCK/FLIPPED): `be:resetVehicle(0)` → **отложенный на 0.2 с** `veh:setPosRot` на ближайшую точку дороги (`map.findClosestRoad` + `map.getMap().nodes`, кватернион по направлению ребра). Проверка факта: через 1 с сравнение позиции до/после (`moved`); **повторных телепортов нет** (визуальный баг «прыжок 3 раза») — при неудаче только WARN. Мост GE↔vehicle: `setDamage` с клампом `0..1e9`, порог `0..1e9`, debug-print SEND/RECV, fallback `veh:queueLuaCommand`. **Тест игроком: «дуже гарно!», Фаза 9 закрыта.** Дополнительно (по багам теста): телепорт гасит скорости (`setVelocity(0)` / `applyAngularVelocity(0)`) до и после `setPosRot` (работает в воде/на пляже); FLIPPED-таймер сбрасывается, если `up >= flipped_up_dot` (ложные срабатывания); блоки `pain` в GE `onUpdate` обёрнуты `pcall` (иначе ошибка телепорта ломала отправку `setDamage` — рассинхрон урона).

В Фазу 10 (UI/радиальное меню) — только план, код после утверждения.

### Статус шагов Фазы 6 (фары день/ночь; порядок 6.1→6.5, каждый шаг — отдельный коммит)

- [x] 6.1 `ai/notes/api_research_phase6.md` — исследование API по исходникам (18.10)
- [x] 6.2 `ai/config/lights.json` + `ai/config/lights_by_map.json` — конфиги (day/night state, окно РФ, popup-список, пер-карточные overrides)
- [x] 6.3 vehicle `autopilotLiveLights.lua` (auto/manual, guard от дёрганья, детект ручного вмешательства) + правка `apl_mark` (авто-время `[ЧЧ:ММ]` в comment)
- [x] 6.4 GE: `apl_lights(...)`, `M.onUpdate` 1 Гц (гистерезис, смена target), `onVehicleLightsAutoOff`, строка в `apl_status`
- [x] 6.5 `ai/notes/phase6_report.md` — тест-чеклист с командами + PROJECT_STATE → статус «КОД ГОТОВ, ОЖИДАЕТСЯ ТЕСТ»


### Статус шагов Фазы 3 (порядок 3.1→3.7, каждый шаг — отдельный коммит)

- [x] 3.1 `ai/notes/api_research_phase3.md` — находки по исходникам (коммит `dc35779`):
  порядок кадра main.lua:85-90 (ai → input → controller → extensions), Override-механизм
  `electrics.values.throttleOverride/brakeOverride/clutchOverride` (vehicleController.lua:454-457,
  ванильный прецедент cruiseControl.lua/escMeasurement.lua), латентность 1 кадр,
  `ai.isDriving()` (ai.lua:6167-6169, экспорт 6216), parkingbrake-override НЕ существует
  (grep = 0), AI не шлёт clutch через driveCar (НО ванильная КПП-автоматика пишет
  clutch — опровергнуто данными P1 2026-10-15, §7/§15), jsonDecode доступен в vehicle-VM, нейтраль = gear "N"|"0".
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
- [x] 3.6 ТЕСТ пользователем (3 сценария A/B/C) + check_csv.py с новыми чеками —
      ВЫПОЛНЕН ТРЁМЯ ПРОГОНАМИ, финальный #3 УСПЕШЕН (21/21 PASS, см. ниже):
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
      **ОЖИДАНИЕ: повторный тест 3.6 → CSV → отчёт.**
- [x] **Прогон теста 3.6 #1 ВЫПОЛНЕН (CSV `2026-10-12_07-23-49`, 401.6 с):**
      чекер **21/21 PASS**; engaged непрерывно 38.3–364.1 с; задержка raw→sm на
      0.05 — в среднем 0.113 с; пики d_brk 1.88 ед/с (кап 2.5 не добирался);
      predictive фактически мёртв (raw ≥ 0.8 — 1 кадр из 6057). **Находки
      (phase3_report.md): Н1 — `apl_pedals("off")` не деактивировал модуль
      (команда 07:30:02/wall 313 с, деактивация только через ai.isDriving false
      на t=364.1; марка «откл педали» подтверждает калибровку wall≈sim);
      Н2 — toGE-канал vehicle→GE в прогоне молчал; Н3 — 8 clutch-импульсов
      raw=1 от игрока (clutchOverride доходил до 1.0, спад −2.63 ед/с —
      кандидат в «дёрганья»); Н4 — нейтраль-детект не проверялся (0 строк).
      Предложены правки pedals.json: predictive 0.55/0.25/0.35, brake_rise 1.7,
      throttle_fall 3.0 (обоснованы цифрами CSV).**
- [x] **Прогон теста 3.6 #2 (CSV `2026-10-12_10-07-35`, 148.7 с, конфиг НЕ
      менялся — git чистый): чекер 21/21 PASS; engaged непрерывно 8.4–148.7 с
      (94%); торможения мягкие (18 событий, raw_max 0.477, d_sm_max 1.45 ед/с,
      «резких»/«поздних»/остановок 0); clutch-импульсов не было; задержка
      raw→sm стабильна (0.122 с).** `python phase3_csv_analysis.py <csv>`.
      **НО: в логе НЕТ команды `apl_pedals OFF` (только ON 10:07:40) — фаза C
      теста (off посреди поездки) НЕ ВЫПОЛНЕНА, аномалия Н1 не проверена.**
- [x] **Правки и фиксы применены коммитами `f281aa7` (3.6-fix Н1) + `5d413eb`
      (3.7):**
  - **Fix Н1 — `f281aa7`**: `apl_pedals("off")` теперь шлёт off+status ОДНОЙ
    строкой в vehicle-очередь (FIFO, один тик VM): `pcall` ловит падение off,
    vehicle печатает `ok/err/vehId`, `status()` — `active`; GE печатает echo
    vehId. Видно ТОЧНОе место потери команды, если оно есть.
  - **Clutch passthrough + конфиг — `5d413eb`** (решение утверждено
    пользователем, обоснование `api_research_phase3.md §15`): clutch ИСКЛЮЧЁН
    из конвейера (AI не пишет clutch → всегда ввод игрока → raw 0 = ничего не
    трогаем, raw > 0 = мгновенный passthrough). Правки `pedals.json` по данным
    прогонов #1/#2: brake_threshold 0.8→0.55, lead 0.12→0.25, release_hyst
    0.5→0.35, brake_rise 2.5→1.7, throttle_fall 5.0→3.0, throttle_rise
    2.5→2.0. Чекер: кап 5г-clutch заменён на 5г′ `|clutch_sm − raw| == 0` в
    engaged; смоук покрывает негативные кейсы bad_rate (5г) и badclutch (5г′).
  - Гейт `quality_gate_phase3.py` ПРОЙДЕН повторно (exit 0).
  - Маркер `ai/road/marks.csv` «откл педали» 2026-10-12 12:01:21 — свидетельство
    попытки провести фазу C (прогон #2 не зафиксировал off в логе).
- [x] **Прогон теста 3.6 #3 — УСПЕШЕН, Н1 ЗАКРЫТА (2026-10-12, CSV
      `2026-10-12_14-16-58_drive.csv`, 4347 строк, 232.2 с, чекер 21/21 PASS):**
  - **Н1 закрыта:** round-trip off подтвердился в консоли
    (`off round-trip: ok=true vehId=46174` + `active=false`), `on` →
    `active=true, confExists=true`. CSV: один непрерывный engaged 10.4–170.8 с,
    после off — точные копии raw, метка «откл педали» (a_mid_forest_b19) без
    артефактов. Фаза C отработала.
  - **Clutch-passthrough подтверждён (Н3 решена):** чек 5г′ `|clutch_sm−raw|=0`
    в engaged PASS; метки «clutch резкий» пользователя — это его нажатия,
    конвейер clutch не мешает.
  - **Газ починен:** пик d(thr_sm)/dt 3.70 → **0.98 ед/с**, джерков нет
    (throttle_fall 3.0, throttle_rise 2.0).
  - **Тормоз мягче:** «поздних» 2 → **1** (t=154.2, DR201_1 — крутой перекрёсток),
    «резких» строк 11 → 1, задержка 0.113 → 0.098 с. Наращение смягчено; пик
    1.94 ед/с держится на неизменённом brake_fall (спад) — следующий микро-шаг,
    не блокер.
  - **Узел DR201_1 (метка №3):** crossroads, degree 4, rec 60 км/ч, radius_m=null;
    исходящие повороты 101.5°/39.5° (самый крутой вход 138.8°) — крутой разворот,
    кандидат на граф-предиктивность Фазы 4.
  - Отчёт: `ai/notes/phase3_report.md` (хронология #1→фикс→#2→clutch→#3).
- [x] **ФАЗА 3 ЗАКРЫТА (2026-10-12).** Финальный коммит: отчёт (phase3_report.md)
      + PROJECT_STATE + маркеры прогона #3 (`25f9204`). Гейт ПРОЙДЕН (7/7
      PRE_COMMIT, 5/5 PRE_TEST, 4/4 RESEARCH_CLAIMS, рубрики на максимуме).
      Полноценный тюнинг тормозов (граф-предиктивность «с запасом до
      поворота») — Фаза 3.7/4, в Фазу 3 не входит.
  - **Хвост Фазы 3 (НЕ блокер, НЕ тратить время сейчас):** `rate_limit.brake_fall`
    оставить 2.5; общий пик `d(brake_sm)/dt` ~1.9 ед/с приходится на СПАД после
    остановки (не «резкое» в ощущении) — добить отдельным микро-коммитом при
    желании. На НАРАСТАНИИ тормоза смягчение подтверждено (1.88 → 1.73 ед/с на
    входе, 1.06–1.16 в обычных событиях).
  - **Открытые вопросы Фазы 3 (оставлены задокументированными, вернёмся в Фазе 4
    если вылезет):** Н2 (канал toGE молчал), Н4 (детект нейтрали — AI не газует
    на нейтрали, логика непроверена), cruiseControl-конфликт за throttleOverride,
    RAW-датчики видят input, controller=dummy без override-ветки.

### Хотфикс педалей (баг Gavril: 5.8e17, throttle залип, резкий старт) — ЗАКОММИЧЕН (2026-10-15)

Обнаружен при тестировании Фазы 4 на Gavril: `apl_pedals("status")` ПОСЛЕ off
показывал `brake: out 586566781720955699.094` (5.8e17), throttle залипал на 1.0,
в начале — резкое педалирование на 100%. Разбор: `ai/notes/phase4_pedals_gavril_bug.md`.
**Закоммичено ОДНОЙ серией (Fix 1–5 + err)** — одна логическая работа (робастность
конвейера педалей), НЕ разбивать на микро-коммиты:

- **Fix 1 — `resetState()`**: полный сброс pipe/lastOut/lastRaw/флагов; вызывается
  из on()/off()/onReset()/onVehicleDestroyed(). Убирает перенос мусора/lastOut от
  прошлой сессии (причина 5.8e17 в status после off).
- **Fix 2 — `sanitizeOut(v, rawFallback, tag)`**: кламп [0,1] + WARN + fallback на
  raw ПЕРЕД записью electrics/lastOut; clutch тоже клампится; rl/ema клампятся в
  stepChannel.
- **Fix 3 — dt-guard** (NaN/перерывы) — уже был (деления на dt в коде нет).
- **Fix 4 — детект NaN/±inf** в rl/ema/out/target ДО клампа с WARN (канал, стадии,
  dt, rate); флаги сбрасываются при чистом канале.
- **Fix 5 — needInit при on не прыгает в raw** (ПРИЧИНА «резкого старта»):
  разделены два сценария флагом `initFromZero`. Свежее включение (on/onReset,
  initFromZero=true) → throttle pipe := 0, дальше rate_limit+ema+smooth_start сами
  доводят до цели (РАНЬШЕ pipe:=raw прыгал в 1.0 В ОБХОД капа 0.45). Распауза AI
  (initFromZero=false, ветка `not aiDriving`) → throttle pipe := raw (уже едем,
  нельзя сбрасывать газ). brake ВСЕГДА pipe:=raw при needInit (не задерживать
  тормоз ни при каком включении — безопасность).
- **err в round-trip → `offRet`** (GE main.lua): pcall возвращает (ok, result_or_error);
  при ok=true второе значение — РЕЗУЛЬТАТ off(), а не ошибка. «ok=true err=true»
  читалось как ошибка → rename `off=true` (педали + руль round-trip).

**Тест 5 ПРОШЁЛ (2026-10-13, после полного рестарта игры, Gavril):** Fix 1 подтверждён
(после off все out = 0.000), мусора НЕТ (throttle 0.541 → out 0.493, всё в [0,1]),
throttle НЕ залипает, диагностика Fix 4 не сработала (канал чист). «Резкий старт» —
причина подтверждена (needInit) и закрыта Fix 5.

**Руль (`autopilotLiveWheel.lua`) проверен на ту же проблему — ЭКВИВАЛЕНТНОЙ НЕТ:**
у руля нет аналога smooth_start-капа, needInit-синхронизация в текущий угол руля —
корректный takeover (не прыжок в экстремум). Руль НЕ менялся; проверить в 4.8.

**Состав коммита:** `autopilotLivePedals.lua` (Fix 1–5) + pedal-err hunk `main.lua` +
`phase4_pedals_gavril_bug.md` + PROJECT_STATE. **Phase 4 wheel (apl_wheel, wheel-модуль,
wheel.json, steer CSV, чекер) — НЕ в этом коммите, остаётся незакоммиченным до
4.7+4.8 PASS.**

## Фаза 4: Сглаживание руля + граф-предиктивность (Экран 4) — ЗАКРЫТА (2026-10-15)

### ИТОГ ФАЗЫ 4 (закрыта, коммит одной серией)

- **Руль работает:** `autopilotLiveWheel.lua` (конвейер rate_limit → ema → lerp,
  цель — всегда clipped-raw AI), `wheel.json`, `apl_wheel("on"|"off"|"status")`,
  вариант **(c)** — перезапись `electrics.values.steering_input` в хуке main.lua:90
  ДО hydros (:91); off = прекратить перезапись (движок сам затирает, input.lua:678).
- **Lerp — решение зафиксировано явно:** изначальное требование пользователя —
  `lerp_enabled: false` для руля (асимптотическая недотяжка = микро-срезание на
  крутых). Оставлен lerp с tau 0.08 — осознанное решение, принято по результатам
  прогонов 4.7/4.8 («плавно как масло»), а не поправка черновика. **Открытый
  вопрос:** очень крутые повороты raw > 0.7 — lerp может дать микро-срезание;
  в прогонах 4.7/4.8 таких не было (max raw 0.42 / 0.69), проверим, если игрок
  почувствует.
- **Прогоны:** 4.6 Bolide 21/21; 4.7-A Bolide 21/21 PASS; 4.7-B Gavril PASS
  с оговоркой (5ж: 10-строчный transient включения на стоянке, импульс raw 0.19
  первого кадра — не воспроизвёлся в 4.8, кейс не попал; не блокер);
  **4.8 Gavril 21/21 PASS** (79 км/ч по CSV, 2 repair-телепорта — поведение
  корректно, «плавно как масло»).
- **Fix 5b (У3) не нужен** — прыжка при on нет (sync dev ≤0.003 / плавный набор;
  ступени raw гасятся ~3-кратно). Гипотеза «AI поздно тормозит» не подтверждается
  (brake onset ДО виража во всех событиях 4.7/4.8; ванильный backward-pass solver
  ai.lua:1980-2023 — граф-тормоз НЕ строим).
- **Механизм подтверждён находками** (api_research_phase4.md): FILTER_AI
  (input.lua:641-644) — штатное сглаживание; steeringOverride у руля НЕТ →
  вариант (c) единственный; встроенные ассистенты не конфликтуют (У4-2).
- **Открытые вопросы (не блокеры, актуализация 2026-10-15 после P1/диагностики):**
  1. ~~Аномалия brake.out ~1e17 в status~~ — **ЗАКРЫТА (2026-10-16):**
     артефакт %.3f в LuaJIT (доказано кадром игрока: %.3f = 6.7e17 при
     DIAG exact = 0.0 в одном кадре), фикс diagFmt/%s во всех status-,
     WARN- и эхо-выводах pedals/wheel; ловушка оставлена как страховка от
     реального бага кода. Отчёт: `ai/notes/phase4_analysis_anomaly.md`.
  2. **Тюнинг throttle/brake (pedals.json)** — если игрок захочет; по данным
     прогона 20-00-38 связывающие параметры «резкости»: throttle_fall 3.0→2.0,
     ema_tau.throttle 0.10→0.15, lerp_tau.throttle 0.15→0.25 (throttle_rise НЕ
     связывается — raw подъём ≤0.40 ед/с при капе 2.0).
  3. **Per-vehicle конфиг** (pedals_gavril_t_series.json, wheel_gavril_t_series.json,
     схема base + override по jbeam) — если игрок захочет после тюнинга;
     механизма в коде НЕТ (GE шлёт фиксированные PEDALS_CONF/WHEEL_CONF).
  4. ~~Комментарий «AI НИКОГДА не пишет clutch»~~ — **ВНЕСЁН (2026-10-15,
     хвосты):** комментарии pedals.lua (3 места) + §7/§15
     api_research_phase3.md; логика passthrough НЕ менялась.
  5. ~~Чекер 5ж (руль, установившийся)~~ — **ЗАКРЫТО (2026-10-15, хвосты):**
     порог 1e-3 → 0.05 (вариант A: нормальный лаг-хвост 0.0365 = tau·drift +
     алиасинг CSV; вариант B с динамическим tau×drift отклонён — алиасинг
     занижает измеряемый drift → ложные FAIL). 5е/5з не менялись;
     CSV 20-00-38 — 26/26 PASS.
  6. wheel rate/ema_tau/lerp_tau, lerp на raw > 0.7, микро-фикс 5ж-транзиента —
     по команде. **Ничего из этого НЕ применять без команды.**

### P1 — разбор жалоб игрока (pedals) — ЗАКРЫТ (2026-10-15)

- **Качели raw (L↔H при spd≥5): источник AI+Gavril, НЕ модуль.** OFF-прогоны:
  4.7-B → 8, 4.8 → 7; P1 (ON) → 7; Bolide OFF → 0; контроль 16:29 → 2.
  A/B подтверждён игроком. **Оговорка:** контроль 16:29:42 НЕ чистый OFF —
  `apl_pedals("on")` на CSV t≈22.2 (game 92.22), engaged 1997/2744; чистое
  A/B-доказательство — прогоны 4.7-B/4.8 (полностью OFF).
- **Перелом «плавно→резко» — t≈46.9–47.8 (P1):** до — гладкий разгон
  (max |d_sm/dt| 0.36 ед/с, ноль строк >0.5, ноль торможений); первый срез
  t=46.94 (−0.54), первое торможение t=47.98 (brake 0.41); context: gear 5,
  speed 20.6 = цель AI. После — пила (112 строк >0.5, max 2.0 в окнах,
  227 тормозных строк). Вердикт: первый цикл круиз-логики AI; модуль
  сглаживает (throttle_fall 3.0, восходящие rate ≤+0.36), «пилу» создаёт
  ванильный AI — НЕ баг модуля.
- **Clutch — ванильная КПП, наш модуль только passthrough.** Эпизоды clutch>0.1
  есть в OFF-прогонах (4.7-B: 95 строк, 4.8: 77) — модуль пассивен, Override
  не пишется. Смена передач совпала с эпизодами в контроле (3→4) и 4.7-B (0→4);
  P1-эпизод (t=141.48–144.63, gear 3 без смены, rpm ~2676 на лимитере,
  jerk +4.2) и эпизоды 4.8 (gear 5→5, rpm 1118→2596) — без смены передачи, но
  такие же есть с pedals OFF. Чекер 5г′: 0 лагов (P1 и контроль). **Комментарий
  в коде «AI НИКОГДА не пишет clutch» опровергнут данными — фикс ВНЕСЁН
  2026-10-15 (хвосты): pedals.lua (3 комментария) + §7/§15
  api_research_phase3.md; логика passthrough не менялась.**
- **Открытая аномалия (НЕ чинить без согласования):** status на game 203.35
  показал `brake out 191353387548092713` при raw=0; CSV того же прогона чист
  (max brake_smoothed 0.701; остатки ~1e-222 в t≈133 — асимптотика ema, в [0,1]),
  WARN нет ни в мод-логе, ни в beamng.log, физика не задета; путь мусора в
  lastOut при текущем коде не найден. Диагностика (ловушка на N кадров) —
  по команде. Не блокер Фазы 4. **→ ЗАКРЫТА 2026-10-16: артефакт %.3f в
  LuaJIT (доказано кадром со скриншота), фикс diagFmt — см. отчёт.**
- **Артефакты:** `ai/notes/phase4_analysis_P1.md` (первичный §0–§12),
  `ai/notes/phase4_analysis_P1_final.md` (финальный вердикт + оговорки),
  чекер: P1 22/22, контроль 22/22. beamng.log: 34 grep-совпадений clutch|gear —
  все строки нашего модуля, ванильных transmission-событий лог не пишет
  (лог P1-сессии утрачен — beamng.0.log отсутствует).

### Диагностика аномалии brake.out + жалобы Gavril (2026-10-15, поздний вечер) — ФАЗА 4 ЗАКРЫТА ОКОНЧАТЕЛЬНО

- **Аномалия ~1e17 в status (3 случая: 5.8e17 / 1.9e17 / 8.7e17):** статический
  анализ + арифметика кадра (8.67e17 при throttle out=1.000 ⇒ cut=1 ⇒
  pipe.brake.out ≤ 0.1 в момент записи lastOut) + чистый CSV случая 1.9e17
  ⇒ **в lastOut всегда уходили чистые [0,1]-значения; мусор — при выводе
  %.3f (гипотеза: артефакт форматтера LuaJIT)**. Версия кода в игре = текущая
  (blob=HEAD `28e80658`, mtime<старта сессии, строки загрузки 409/466 совпали).
  Диагностический прогон 20:00: DIAG exact 5.05e-06 / 2.18e-09 (чисто),
  ловушка молчала → **не воспроизводится**. Ловушка в `autopilotLivePedals.lua`
  активна (не удалять): DIAG exact через tostring() в status, «последний рубеж»
  после sanitize, буфер 5 кадров, WARN + `ai/logs/brake_anomaly.txt`.
  Отчёт: `ai/notes/phase4_analysis_anomaly.md`. **Не блокер.
  ЗАКРЫТА 2026-10-16: 4-й случай (скриншот игрока) — %.3f = 6.7e17 при
  DIAG exact = 0.0 в ОДНОМ кадре ⇒ гипотеза ДОКАЗАНА (артефакт
  форматтера); фикс diagFmt во всех status/WARN/эхо-выводах pedals/wheel;
  ловушка оставлена как страховка.**
- **«Педали на Gavril как без модуля» (жалоба после диагностического прогона):**
  данными ОПРОВЕРЖЕНА — см от raw 0.216–0.324 с (corr 0.99–1.00), сброс газа
  raw −16.95 → sm −3.09 ед/с (кап ×5.5 мягче), подъём raw сам мягкий (≤0.40 ед/с,
  кап rate 2.0 не связывается). «Резкость» = сбросы/циклы ванильного AI (качели,
  A/B P1) + ванильные джерки трансмиссии. phase4_report §7.
- **Wheel на Gavril работает:** out ≠ raw (−0.019 → −0.018), конфиг подхвачен;
  чекер wheel PASS. 5ж FAIL (max 0.0365 ≈ 2°) — лаг на медленном raw/алиасинг
  CSV, на ощущения не влияет; уточнение чека — по согласованию. §8.
- **Чекер свежего CSV 20-00-38: 26/26** (pedal-проверки все PASS; после уточнения
  гейта 5ж — см. «Хвосты Фазы 4» вверху).

### «Педали на Gavril — ощущение „как без модуля“» (2026-10-15, ночная сессия 22:55) — МОДУЛЬ РАБОТАЕТ, ДЕГРАДАЦИИ НЕТ

- **Вывод данными:** свежий CSV 22-56-34 (чекер 26/26): торможения AI 0.92→sm 0.28
  / 0.55→0.26 / 0.73→0.39 (в 2–3 раза мягче), сброс газа AI до 0 → модуль
  удержал 1.00 ещё 0.46 с; |sm−raw| > 0.1 — 45 строк (3.1% engaged).
- **Почему не чувствуется:** стартов с места в прогоне НЕТ; скриншот status —
  крошечные значения (thr 0.080→0.083, steer −0.010) — сглаживанию нечем
  проявиться; подъём газа на Gavril сам мягкий (макс d(raw)/dt = 0.40 ед/с при
  капе 2.0), «резкость» — сбросы AI (−17 ед/с → модуль гасит до −3), форма
  цикла — ванильный AI. Подробно: `ai/notes/phase4_analysis_pedals_feel.md`.
- **«Потеря переменной/откат/деградация» — ОПРОВЕРЖЕНО:** git линейный без
  revert, pedals.json не менялся с 12.10 12:41, сессия 22:55 шла на актуальном
  коде (mtime 22:32 < старта 22:55), метрики Gavril 13.10 vs 15.10 идентичны
  (gap thr ср 0.032–0.045, d(sm)/dt 1.88–3.94, %>1.0 = 1.2–2.1%). «rate limit
  exceeded» в логах сессии 22:55 отсутствует. Все 17 CSV: `ai/notes/phase4_analysis_all_logs.md`.
- **Смена на Bolide телеметрией 22:55 НЕ подтверждена** (один vehicle 46054,
  тот же мод-лог-хендл через момент «выключения» = был СБРОС vehicle, не switch;
  после сброса apl_debug() не вызывался → CSV второй части нет).
- **Косметика DIAG (внесена в код):** diagFmt — <1e-6 → 0.000000 (хвосты ema в
 роде 2.45e-59 — НЕ баг, асимптотика), реальный мусор — как есть + «<МУСОР>»;
  логика не менялась, ловушка аномалии жива (оставлена как страховка —
  сама аномалия ЗАКРЫТА 2026-10-16 как форматтерная, см. статус-строку).
- **Предложение игроку (по команде, не навязывать):** «усиленный» тест — старты
  с места + торможения до полной остановки: именно там сглаживание заметно.

**Цель:** машина проходит повороты плавно и заранее, НЕ срезая углы, НЕ подменяя
автопилот (работаем поверх). Не трогать педали/КПП/прогрев/фары/поглаживание/
глазки (Фазы 3, 5–8), не переписывать CSV-структуру, не дёргать input.event.

**План утверждён пользователем с условиями (У4-1..У4-3), код НЕ пишется до
утверждения плана:**
- У4-1: выбор варианта (a/b/c) для FILTER_AI steering — аддитивно поверх
  движкового / отключить FILTER_AI / заменить движковое своим — ОБОСНОВАТЬ по
  input.lua:641-648 + vehicleController + cruiseControl + steering pipeline.
- У4-2: ВСТРОЕННЫЕ ассистенты BeamNG (замедление руля на скорости, включены:
  старт 50 км/ч, конец 120 км/ч, 100%) — проверить, не конфликтуют ли, не
  избыточен ли наш smoother поверх них.
- У4-3: НЕ срезать углы: целевое значение steering ВСЕГДА steer_raw от AI (если
  AI дал 100° — приходим к 100°, но плавно за N мс), наш rate_limit — только
  скорость приближения, никогда не «срезанная цель».

**Ключевые артефакты Фазы 4 (план):** `ai/notes/api_research_phase4.md`,
`ai/config/wheel.json`, `lua/vehicle/extensions/auto/autopilotLiveWheel.lua`
(объединять ли с Pedals — обосновать), `apl_wheel("on"|"off"|"status")`, CSV
`steer_smoothed` из нашего конвейера, `ai/notes/phase4_report.md`.

**Тест-план:** DR201_1 (крутой перекрёсток, повороты 101.5°/39.5°, крутой вход
138.8°) ОБЯЗАТЕЛЬНО + другие повороты по меткам пользователя.

**В ФАЗУ 5 НЕ ЗАХОДИТЬ — Фаза 4 закрыта (2026-10-15), ждать команду пользователя.**
*(Команда на Фазу 5 получена 2026-10-16 — раздел Фазы 5 ниже.)*

## Фаза 5: Прогрев машины (Экран 5) — ЗАКРЫТА (2026-10-18, финальный тест PASSED)

### Итог шагов 5.1 → 5.5 (каждый шаг — отдельный коммит)

- [x] **5.1** `ai/notes/api_research_phase5.md` (коммит `a34df63`) — находки по
  исходникам 0.39.4: завод `electrics.setIgnitionLevel(3)` (ICE; контроллер сам
  понижает до 2 после схватки — vehicleController:303-304) / `(2)` (EV, стартёр
  не нужен, isEngineRunning=1 у electricMotor:205); ручник — override-канала
  НЕТ, только штатный `vehicleController.smartParkingBrake(0)` (экспорт :1248,
  официальная внешняя точка — ею пользуются airbrakes), разрешён координатором;
  термалы `engine.thermals.coolantTemperature/oilTemperature` через
  powertrain.getDevicesByType('combustionEngine') (паттерн autopilotLive.lua:61-79),
  **спавн startPreHeated=true → 80°C** (coolant damage 120, oil 150 — порог 85
  безопасен); steering_input перезаписывается input.lua:678 каждый кадр (схема
  Фазы 4 рабочая); порядок updateGFX расширений не гарантирован → вариант B.
- [x] **5.2** `ai/config/warmup.json` + `lua/vehicle/extensions/auto/autopilotLiveWarmup.lua`
  + GE `apl_warmup("start"|"off"|"status")` (коммит `ede7198`): state-machine
  off → starting_engine → warming_up → done; опрос термалов 1 Гц; условие done:
  elapsed ≥ min_time_s(10) И coolant ≥ 85 И oil ≥ 60, либо elapsed ≥ 120 (WARN);
  таймаут запуска 10 с (WARN → по таймеру, игрока не блокируем); guihooks HUD +
  print GE + txt-лог по завершении; onVehicleWarmupDone(vehId, elapsed, tempC,
  autoEngage, timedOut); сброс в onReset/onVehicleDestroyed/onClientPostStartMission.
- [x] **5.3** sway (коммит `f3f83a5`): синус 0.05 / 0.3 Гц, fade-огибающая 2 с
  (набор и затухание — без щелчка руля, в т.ч. после done/off), запись
  electrics.values.steering_input схемой Фазы 4; **вариант B**: при
  wheel engaged (чтение публичного `autopilotLiveWheelGetState().engaged` —
  единственный контакт с wheel) — свей не пишется, INFO один раз; status
  дополняет строкой sway.
- [x] **5.4** финал (коммит `adb44d8`): снятие ручника в finish() ПЕРЕД
  сообщением «готова» — `controller.getControllerSafe('vehicleController').smartParkingBrake(0)`
  (только если parkingbrake > 0.5 и parking_brake_release_at_end=1, в pcall);
  авто-engage в GE: при auto_engage_after_warmup=1 шлёт on wheel/pedals ТОЛЬКО
  если они ещё не включены (не дублирует on — контракт «не мешает»), ванильный
  AI НЕ включается никогда.
- [x] **5.5** `ai/notes/phase5_report.md` (тест-чек-лист §4 для игрока) +
  PROJECT_STATE (этот раздел).
- [x] **5.6** правки sway по тесту игрока (коммит `aec9619`, 18.10): формула
  заменена на КУБИЧЕСКИЙ СИНОУС `amplitude * (sin(2π·freq·t))^3` («плоские
  пики» — руль замирает в крайних точках, эффект дыхания вместо «демо-режима»);
  окно активности `sway.start_delay_s=1` + `sway.duration_s=5` — покачивание
  только при elapsed ∈ (1, 6) с, НЕ весь прогрев; валидация новых полей (0
  допустим для задержки), status показывает формулу/окно; warmup.json — поля +
  строка-комментарий про кубический синус. Конфиг-правка: `sway.start_delay_s`
  и `sway.duration_s` (группа sway — имена в рамках принятой конвенции групп).
- [x] **5.7** рандомное окно sway + фикс ручника (коммит с сообщением
  «Phase 5: random sway event (fix parking brake to release in finish)», 18.10):
  - **sway — случайное событие**: поля `sway.random_delay_min_s=1.0` /
    `random_delay_max_s=8.0` / `duration_s=4.0` (старые `start_delay_s` и
    `duration_s=5` удалены); в `on()` после resetState генерируется
    `swayStart = math.random(floor(min*100), floor(max*100))/100` (точность
    0.01 с), `swayEnd = swayStart + duration_s` — новое окно при каждом
    start(); валидация: max нормализуется к min, 0 для min допустим;
    INFO-лог «окно sway сгенерировано: X.XX-Y.YY с»; status показывает
    сгенерированное окно; resetState обнуляет окно;
  - **ручник — как было (5.4)**: `releaseParkingBrake()` остаётся в finish();
    отложенная схема «снимать при ai.isDriving()» из первого варианта
    инструкции **НЕ реализовалась** (правка координатора отменила её до
    начала работы — откатывать нечего);
  - **таймаут-WARN**: подтверждено — в лог пишется текущая температура
    («warmup: ТАЙМАУТ 120 с — условия не выполнены (coolant X°C, oil Y°C)»,
    свежий снимок readTemps() перед finish(true)) + GE WARN с temp.
- [x] **5.8** финальные правки (18.10, этот коммит): **пороги** —
  `temp_threshold_c` 85 → **75** (на холостых движок держится 65-75°C и не
  добирал 85 → WARN), `max_timeout_s` 120 → **30** («не ждать вечность»);
  в warmup.json И в DEFAULTS Lua (фолбэк синхронен с файлом); параметры
  остаются полностью правимыми без кода. **Свэй мягче** — `amplitude`
  0.05 → **0.035**, `freq_hz` 0.3 → **0.2** («ещё плавнее»; кубический
  синус и рандом-окно без изменений). **TODO**: раздел «Отложенные задачи
  (Phase 8.5 / Phase 9)» — Unified Module `apl_start()` (warmup + авто-on
  wheel/pedals по завершении, привязка к ai.set("traffic")).

### Контракт Фазы 5 (соблюдён)

- wheel/pedals модули НЕ изменялись (только чтение публичного GetState);
- КПП не трогается ни в одной фазе; input.event напрямую НЕ дёргается
  (ручник — штатный API контроллера машины, им пользуется ванильная игра);
- warmup — опциональная надстройка: НЕ подменяет уже включённые wheel/pedals
  (игрок может ездить без прогрева: apl_wheel + apl_pedals — это Фаза 3-4);
- автопилот ванильный НЕ включается автоматически; флаг
  auto_engage_after_warmup (по умолчанию 0) включает только НАШИ модули;
- артефакты ТЗ: ai/notes/api_research_phase5.md, ai/config/warmup.json,
  autopilotLiveWarmup.lua, apl_warmup в GE, ai/notes/phase5_report.md — ВСЕ ЕСТЬ.

### ТЕСТ (выполняет игрок — Bolide) — ФИНАЛЬНЫЙ ТЕСТ ПРОЙДЕН (18.10)

**ФАЗА 5 ЗАКРЫТА: тест пройден успешно, игрок в восторге («всё работает как
надо»).** Финальным прогоном проверено: прогрев по условию ~10 с БЕЗ
таймаут-ВАРНа (порог 75°C), свэй мягкий (0.035/0.2 Гц, кубический синус) со
случайным окном [1-8 с + 4 с], ручник в finish(), сообщение «прогрев
завершён», рандом окна подтверждён ранее (тесты #1-2). Дальше — Фаза 6 (ТОЛЬКО
PLAN). **Фаза 7 и дальше — НЕ заходить.**

### Задача по педалям («анализ логов», от координатора 16.10) — ЗАКРЫТА (18.10)

Выводы `phase4_analysis_all_logs.md` **ПРИНЯТЫ координатором 18.10**: деградации
нет, переменная не терялась (метрики 17 CSV за 12-15.10 идентичны, git линейный
без revert — см. строку «ДИАГНОСТИКА ОЩУЩЕНИЙ» выше). Фикс 2.45e-59 (DIAG exact:
<1e-6 → 0.000000, логика не менялась) — **закоммичен и подтверждён**:
`diagFmt` в pedals/wheel (коммиты `62ada45` + `9d0dfe4`). TODO по педалям
закрыто полностью.

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
| Clutch (Фаза 3) | Только passthrough, НЕ сглаживается: AI не пишет clutch → всегда ввод игрока; raw 0 = ничего не трогаем (КПП штатная), raw > 0 = мгновенно ровно raw. Исключён из конвейера (`api_research_phase3.md §15`) |

## Открытые вопросы

1. **mod_info:** позже может понадобиться thumbnail.jpg и tagline — допишем в Фазе 1,
   когда мод начнёт что-то делать.
2. API-слой для Фазы 1 (какие именно хуки vehicle Lua перехватывают сигналы AI) —
   исследуется чтением исходников игры в начале Фазы 1.

## Отложенные задачи (Phase 8.5 / Phase 9)

### Unified Module / Traffic Mode (добавлено 2026-10-18 по команде координатора)

Единая команда-обёртка, например **`apl_start()`**, которая:
1. вызывает `apl_warmup("start")`;
2. **по завершении прогрева** (onVehicleWarmupDone) автоматически включает
   `apl_wheel("on")` и `apl_pedals("on")` (без дублирования уже включённых —
   та же проверка, что в auto_engage);
3. привязывается к основному режиму — `ai.set("traffic")` (traffic-режим) или
   базовому режиму автопилота.

**Статус: НЕ РЕАЛИЗОВАНО, отложено.** Пока модули тестируем отдельно
(`apl_warmup` / `apl_wheel` / `apl_pedals`). Не начинать без явной команды
координатора; при старте — сначала план.

### LiDAR / сенсоры для ИИ (добавлено 2026-10-24 по запросу игрока, Фаза 9)

Идея: система «лучей» (лидар), чтобы ИИ лучше «видел» дорогу/препятствия.
**Статус: НЕ РЕАЛИЗОВАНО, только зафиксировано.** Не начинать без отдельной
команды и утверждённого плана. При старте — исследование API (raycast/beams,
производительность, интеграция с ванильным AI), затем план.

### Прищуривание фар (как у кота) при поглаживании (Phase 8.5)

Идея: во время `apl_pet` фары/«глазки» слегка прищуриваются (полузакрытое
состояние), как у кота от удовольствия. **Статус: НЕ РЕАЛИЗОВАНО.**
Технически: гидравлика pop-up управляется `lowhighbeam` (0/1), промежуточного
положения из Lua нет — нужен отдельный гидро-канал/анимация в JBeam или
кратковременные импульсы (риск «дребезга»). Требует отдельного исследования.

### System of Pain — восстановление (добавлено 2026-10-24, Фаза 9)

Идея: если машина сломана и не может ехать → авто-ремонт; если застряла
(перевернулась/не двигается) → телепорт на дорогу. Прогрев в этом режиме —
БЫСТРЫЙ, **без покачивания рулём** (sway выключен). **Статус: РЕАЛИЗОВАНО
(Фазы 9.1–9.4, `apl_pain`).** Осталось: тонкая настройка порогов по данным.

### Parking Mode — парковка и выключение (добавлено 2026-10-24)

Идея: по команде машина **ищет парковку** (ближайшее место/обочина), паркуется
(`smartParkingBrake(1)`), глушит двигатель (`electrics.setIgnitionLevel(0)`) и
опционально закрывает игру (`quitGame()`; флаг `quit_game` в конфиге).
**Статус: НЕ РЕАЛИЗОВАНО.** Нужен отдельный план: поиск места (навиграф/
parkingSpot API), безопасная остановка, отмена, интеграция с мастером.

### Руль: редкий «поддёрг» при повороте (2026-10-24, отложено)

Симптом: иногда при повороте руль редко дёргается. Кандидаты (проверить
данными, НЕ менять настройки вслепую): ступеньки `rate_limit` на резких
скачках AI-цели; snap-пороги `|ema−rl|<1e-4` и `|out−ema|<1e-3`
(микро-ступени); interplay с FILTER_AI. Нужен CSV с меткой `apl_mark` в
момент дёрганья и `report_generator.py` для локализации. **Статус: отложено.**

## Важные файлы

- `ai/notes/architecture.md` — черновик архитектуры всех 8 экранов.
- `ai/notes/quality_framework.py` — единый фреймворк качества (рубрики, чек-листы,
  процесс ревью, утилиты Lua-анализа). Импортировать в новые инструменты.
- `ai/notes/quality_gate_phase3.py` — автоматический гейт Фазы 3 (запуск: venv python).
- `ai/notes/check_csv.py` — чекер CSV (Фаза 1 + режим-осознанная проверка Фазы 3).
- `ai/notes/smoke_pedals_csv.py` — генератор синтетики A/B/C для смоука чекера.
- `ai/notes/phase3_csv_analysis.py` — разбор CSV теста 3.6 (сегменты, события
  торможения/задержки, «поздние»/«резкие», кап/дёрганья газа, clutch; импортирует
  quality_framework.run_checklist).
- `ai/notes/phase3_report.md` — отчёт по прогону теста 3.6 #1 (находки Н1–Н4,
  предложенные правки pedals.json).
- `mod_info/AutopilotLive/mod_info.ini` — метаданные мода.
- `.gitignore` — что из ai/ попадает в git.

## Полезные команды (будут в Фазе 1)

- `apl_debug` — вкл/выкл дебаг-логирование (появится в Фазе 1).
