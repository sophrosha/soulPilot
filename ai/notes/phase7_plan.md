# ФАЗА 7 — «Кнопка Погладить» — ПЛАН (2026-10-18, код НЕ писать до утверждения)

Статус: PLAN. Фокус — ТОЛЬКО Civetta Bolide (Gavril/Wigeon — позже).
Состав: 7а — механика без звука; 7б — звук мурчания (fmod).

## 1. Что исследовано в исходниках 0.39 (чтение, read-only)

### 1.1 Микро-управление педалями — ШТАТНЫЙ override (без input.event!)
- `vehicle/controller/vehicleController/vehicleController.lua:455-456`:
  `inputValues.throttle = electrics.values.throttleOverride or min(max(input.throttle or 0,0),1)`
  и `inputValues.brake = electrics.values.brakeOverride or ...`
- Т.е. vehicle-слой может ставить `electrics.values.throttleOverride = 0..1`
  (или `nil` — вернуть управление игроку). Штатные потребители:
  `vehicle/extensions/cruiseControl.lua`, `gameplay/drag/phaseHandlers.lua`,
  `gameplay/crashTest/scenarioManager.lua` — именно так делают ванильные режимы.
- НЕ дёргаем input.event (правило проекта) — override идёт штатной цепочкой
  vehicleController → powertrain, обороты реагируют естественно (просадка
  при микро-сбросе газа — «обороты слегка сбрасываются» из ТЗ).
- Clutch override в ванили НЕТ — clutch не трогаем.

### 1.2 Руль плавнее
- Наш Фаза-4 модуль `autopilotLiveWheel.lua` строит конвейер
  rate_limit → ema → lerp из `ai/config/wheel.json`
  (`rate_limit.steer_rise = 3.5`, `steer_fall = 5.0`, норм. единицы/сек).
- «Руль становится плавнее на время действия» = временное снижение rate
  (предлагается scale ×0.4–0.6 на время pet-эффекта, с плавным возвратом).
- Механизм (вопрос 3 к игроку): новый API wheel-модуля
  `autopilotLiveWheelCmd.setRateScale(s)` + команда GE→vehicle на время
  эффекта; либо проще — pet-модуль сам пишет сглаженный steering поверх
  (конфликт с wheel-модулем — не рекомендуется).

### 1.3 Скоростной гейт
- `electrics.values.wheelspeed` (м/с) × 3.6 < 5 км/ч — иначе отказ
  «нельзя гладить на ходу» (WARN + лог). Также проверки: ignitionLevel==2
  (мотор заведён), машина игрока найдена.

### 1.4 Защита от спама («усталость»)
- Счётчик активаций за скользящее окно + кулдаун после серии
  (петер игнорирует и пишет WARN «кошачье устало»). Все пороги — в pet.json.

### 1.5 Звук (7б) — как устроен FMOD в 0.39
- GE-API (lua/ge): `Engine.Audio.playOnce(channel, 'event:>UI>Main>Pause', {volume=, pitch=, fadeInTime=, fadeOutTime=, position=vec3(x,y,z)})`
  — одноразовые; `Engine.Audio.createSource(channel, event)` + `source:play(-1)`
  — ЛУП (пример: `ge/main.lua:605` музыка, `ui/credits.lua:47`); остановка —
  `Engine.Audio.deleteSource(id)`. Каналы: 'AudioGui' (2D/UI), 'AudioMusic';
  позиционирование — параметр position (пример: freeroam/gasStations.lua:158).
- Звуки двигателя Bolide СИНТЕЗИРУЮТСЯ FMOD-синтезатором по параметрам из
  engineData jbeam (см. editor/engineAudioDebug.lua) — отдельных wav/сэмплов
  двигателя в установке НЕТ; .sbeam soundbank у bolide.zip тоже нет
  (проверено). «Утробное кошачье мурчание» нельзя получить из ванильных
  звуков двигателя как есть.
- **Встроенный прослушиватель: Ctrl+E (редактор) → окно «SFX Previewer»**
  (lua/ge/extensions/editor/audioEventsList.lua) — ДЕРЕВО всех FMOD-событий
  игры с поиском и проигрыванием кликом. Основной инструмент подбора.
- Варианты7б:
  - (A) ванильное «похожее» событие (ambience/purr-категории) + луп
    createSource + pitch-модуляция синусоидой (~4-8 Гц, depth ~0.05) —
    имитация мурчания; быстро, без внешних инструментов;
  - (B) НАСТОЯЩЕЕ кошачье мурчание — свой FMOD-банк мода (FMOD Studio →
    .bank + подключение в мод) — отдельный research-шаг, нужен FMOD Studio
    у координатора; вопрос 4 к игроку.

## 2. Архитектура 7а (предложение на утверждение)

- GE `main.lua`: `apl_pet("on"|"off"|"status")` — как apl_lights/warmup.
  - on: guard'ы (скорость, мотор, кулдаун/усталость) → команда vehicle
    `autopilotLivePetCmd.start({...params})`;
  - off: `autopilotLivePetCmd.stop()` — немедленный возврат (throttleOverride
    = nil, руль — штатный rate);
  - status: состояние + остаток кулдауна.
- vehicle `lua/vehicle/extensions/auto/autopilotLivePet.lua` (автозагрузка,
  как lights): таймлайн эффекта в updateGFX (длительность ~6 с):
  1. fade-in микро-газа (sin, амплитуда из pet.json, напр. 0.05) — педали
     слегка подёргиваются;
  2. одновременно — микро-пульс brakeOverride (опция, по умолчанию off);
  3. финал: override → nil (управление возвращается чисто).
- `ai/config/pet.json` (дефолты в DEFAULTS, паттерн warmup/lights):
  duration_s, throttle_amp, throttle_hz, brake_amp (0), steer_rate_scale,
  cooldown_s, spam_window_s, spam_max.
- CSV-24 колонки НЕ меняются; wheel/pedals/КПП/ручник — не трогаем.

## 3. Шаги (после утверждения плана)

- 7.1 Уточняющий research: source:stop() vs deleteSource; выбор событий
  (игрок слушает через SFX Previewer); записи в api_research_phase7.md.
- 7.2 `pet.json` + vehicle-модуль pet (микро-газ/тормоз, таймлайн, guard'ы).
- 7.3 GE `apl_pet` + интеграция (статус/лог/ProjectState), тест на Bolide.
- 7.4 Руль: rate-scale API wheel-модуля + плавное включение/возврат.
- 7.5 Защита от спама (кулдаун/усталость) + WARN-сообщения.
- 7.6 (7б) Звук: вариант A (ванильное событие + pitch-модуляция) или B
  (свой банк) — по выбору игрока.
- 7.7 Тест-отчёт (phase7_report.md) + PROJECT_STATE.

## 4. ВОПРОСЫ К ИГРОКУ (ответить до кода)

1. **Как выглядит «подергивание педалей»?** Предлагаю: синусоида на
   `throttleOverride`, амплитуда 0.03–0.08 (по умолчанию 0.05), частота
   ~0.5–2 Гц (медленно). Альтернатива: чередование газ↔тормоз (щелчки).
   Какой вариант/параметры?
2. **Нужен ли HUD-индикатор мурчания?** По умолчанию предлагаю НЕТ —
   только ощущения от руля/педалей (+ печать в консоль при on/off/усталости).
3. **Руль:** согласен с механизмом «временное снижение rate_limit нашего
   wheel-модуля (×~0.5 на время эффекта, плавный возврат)»?
4. **Звук 7б:** (A) ванильное событие из SFX Previewer + pitch-имитация
   мурчания — быстро; (B) настоящий сэмпл кошачьего мурчания — свой FMOD-банк
   мода (нужен FMOD Studio у того, кто собирает мод). Что предпочитаете?
   Или: послушать SFX Previewer и решить по факту?
5. **Длительность/сила:** «поглаживание» ~5–8 секунд достаточно?

## 5. Команды для прослушивания звуков на Bolide (7б, для игрока)

- **SFX Previewer (рекомендуется)**: в игре Ctrl+E (редактор) → окно
  «SFX Previewer» — дерево всех FMOD-событий, поиск (напр. engine, ambient,
  purr, fan, exhaust), клик = проигрывание. Событие с понравившимся путём
  (вид вида `event:>Категория>Имя`) — сообщить нам для 7б.
- **Консоль** (Ctrl+C, GE-Lua):
  - `Engine.Audio.playOnce('AudioGui', 'event:UI_Checkpoint')` — проверка
    канала (щелчок «чекпоинт»);
  - `Engine.Audio.playOnce('AudioGui', 'event:>UI>Main>Pause')` — щелчок паузы;
  - `Engine.Audio.playOnce('AudioGui', 'event:>UI>Career>Fueling_Petrol')` —
    звук заправки (похож на «фырканье»);
  - `Engine.Audio.playOnce('AudioGui', 'event:>Music>main_theme')` — тема;
  - с позицией машины: `Engine.Audio.playOnce('AudioGui', 'event:...', {position = vec3(0,0,0)})` (подставить координаты);
  - луп: `soundTestSrc = Engine.Audio.createSource('AudioGui', 'event:...'); soundTestSrc:play(-1)`, стоп — `Engine.Audio.deleteSource(soundTestSrc)`.
- Звуки САМОЙ Bolide (двигатель/выхлоп) — синтез FMOD по engineData jbeam,
  отдельными событиями не проигрываются; их слушаем как обычно — заведённой
  машиной на разных оборотах (для варианта A подбираем «похожий» тембр).
