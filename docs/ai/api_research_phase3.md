# api_research_phase3.md — Исследование исходников для Фазы 3 (сглаживание педалей)

Дата исследования: 2026-10-12. Игра: BeamNG.drive 0.39.4, карта: East Coast.
Цель: найти точку перехвата throttle/brake/clutch от ванильного AI, НЕ подменяя AI
и НЕ трогая КПП. Ответы на критичные вопросы — с файлами и строками.

## 1. Порядок кадра в vehicle-слое (КЛЮЧЕВОЙ ФАКТ)

`lua/vehicle/main.lua:80-90` — `onGraphicsStep(dtSim)`:

| Строка | Вызов | Что происходит |
|---|---|---|
| 82 | `sensors.updateGFX` | датчики |
| 85 | `ai.updateGFX` | AI считает управление и зовёт `input.event(..., "FILTER_AI", ..., "ai")` |
| 86 | `input.updateGFX` | маппинг `input.state.<k>.val → input.<k>` и `electrics.values.<k>_input` |
| 87 | `electrics.updateGFX` | шина электрикса |
| 88 | `controller.updateGFX` | контроллер ЧИТАЕТ педали → мотор/тормоза |
| 90 | `extensions.hook("updateGFX")` | НАШИ vehicle-расширения тут (после контроллера!) |

Физический шаг (`onPhysicsStep`, :67-78): `controller.update(dtPhys)` на :72 —
там контроллер работает с уже закешированными `inputValues` (см. §2).

## 2. Точка перехвата: `electrics.values.*Override`

`lua/vehicle/controller/vehicleController/vehicleController.lua:454-457`
(`updateGFXGeneric`):

```lua
inputValues.throttle = electrics.values.throttleOverride or min(max(input.throttle or 0, 0), 1)
inputValues.brake    = electrics.values.brakeOverride    or min(max(input.brake    or 0, 0), 1)
inputValues.clutch   = electrics.values.clutchOverride   or min(max(input.clutch   or 0, 0), 1)
```

**Override имеет приоритет над `input.<k>`; nil → штатный вход.** Это штатный
механизм перекрытия, ванильные прецеденты использования:

- `lua/vehicle/extensions/cruiseControl.lua:27,54,67,100` — пишет/снимает
  `throttleOverride` каждый кадр, при выключении ставит nil;
- `lua/vehicle/extensions/escMeasurement.lua:83-112` — то же самое.

**Почему Override, а не `input.throttle` (для Фазы 4 — не переоткрывать):**

1. Наш хук `updateGFX` идёт на строке 90 — ПОСЛЕ контроллера (строка 88).
   Запись в `input.throttle` в нашем хуке была бы прочитана контроллером
   только в следующем кадре, НО строка 86 (`input.updateGFX`) перезатирает
   `input.throttle` свежим AI-значением ДО того, как контроллер прочитает —
   запись в `input.throttle` в принципе никогда не доходит до мотора.
2. Override не входит в конвейер input.lua и не перезатирается ничьей строкой
   86: `electrics.values` — общая таблица, её контроллер читает напрямую.
3. При `nil` контроллер мгновенно возвращается на штатный вход (тот же `or`).
4. Прецедент: cruiseControl — ванильный модуль делает ровно нашу операцию.

**Латентность: 1 кадр (~16.7 мс при 60 FPS).** AI пишет `state.val` в кадре N
(строка 85), мы читаем его в хуке (строка 90) и пишем Override; контроллер
прочитает Override в кадре N+1 (строка 88). На временах сглаживания 100-600 мс
латентность незаметна. Прецедент cruiseControl имеет ту же латентность.

## 3. Конвейер AI → мотор (пешком по строкам)

1. `lua/vehicle/ai.lua:427-436` (`driveCar`):
   `input.event("throttle"/"brake"/"parkingbrake", v, "FILTER_AI", nil,nil,nil, "ai")`
   — каждый кадр AI-езды.
2. `lua/vehicle/input.lua:709-728` (`event`): `M.state[itype].val = ivalue`.
3. `lua/vehicle/input.lua:641-648` (ветка `FILTER_AI` в `updateGFX`):
   - steering (:643): движок САМ сглаживает (`smootherPAD:getWithRateCapped(4*rateMult)`);
   - **throttle/brake/clutch (:646): чистый passthrough `ival = e.val or 0`** —
     движок НЕ сглаживает наши каналы, наш smoothed дойдёт до мотора как есть.
4. `input.lua:675`: `M[k] = ival` → `input.<k>`; `:678`:
   `electrics.values[k.."_input"] = ival`.
5. `vehicleController.lua:454-457` (см. §2) → `inputValues.*` → мотор/сцепление.

## 4. Петли нет: AI не читает свои же «перекрытые» сигналы

AI формирует команды из СЕНСОРОВ (позиция/скорость/цель по навиграфу), а не из
`input.throttle`. Подтверждение — `ai.lua:434-436`: `lastCommand` заполняется из
АРГУМЕНТОВ `driveCar`, а не из обратного чтения input. ⇒ мы перекрываем ВЫХОД
контроллера, AI продолжает слать свои raw-цели, петли нет.

## 5. ai.isDriving — точная проверка (У4)

`lua/vehicle/ai.lua:6167-6169`:

```lua
local function isDriving()
  return M.updateGFX == updateGFX or (scriptai ~= nil and scriptai.isDriving())
end
```

Экспорт: `ai.lua:6216` — `M.isDriving = isDriving`. Истинно, пока активна
штатная функция AI-обновления (т.е. ИИ реально ведёт машину); при ручном
управлении `M.updateGFX` подменён → false. **Используем `ai and ai.isDriving and
ai.isDriving()` с безопасным fallback false** (нет модуля AI → не перекрываем).

## 6. Parkingbrake — конфликта нет (У3)

`grep parkingbrakeOverride` по всему `lua/vehicle` — **0 совпадений**.
Контроллер обрабатывает ручник отдельной веткой (`vehicleController.lua:435-451`:
`input.event("parkingbrake", ...)` / `input.toggleEvent`), override-ключа у
ручника НЕ существует. Наш мод пишет ТОЛЬКО `throttleOverride/brakeOverride/
clutchOverride` — канал ручника не затрагивается.

## 7. Clutch: AI его не шлёт (важно для дизайна)

`ai.lua:427-436` — `driveCar(steering, throttle, brake, parkingbrake)`: аргумента
clutch НЕТ. Под ИИ `input.state.clutch.val` = 0 (остаток от init/reset:
`dynamicVehicleData.lua:880-902` шлёт clutch 1→0 при спавне/сбросе). ⇒ наше
сглаживание clutch под ИИ — безвредный no-op (0→0). Ленивая запись
`clutchOverride` (только если smoothed > 0.001) гарантирует, что штатная работа
КПП не затрагивается вовсе.

> **АКТУАЛИЗАЦИЯ 2026-10-15 (данные P1):** утверждение «под ИИ clutch = 0»
> опровергнуто — clutch-пульсы до 1.0 есть в CSV ПРИ AI-движении в OFF-прогонах
> (4.7-B: 95 строк, 4.8: 77). Источник — НЕ driveCar, а ванильный
> трансмиссионный стек (КПП-автоматика/защита при переключениях). Вывод §7
> «сглаживание под ИИ было бы no-op» неверен, но РЕШЕНИЕ §15 (passthrough) —
> верно и подтверждено данными: модуль пробрасывает raw без вреда (5г′: 0 лагов).

## 8. jsonDecode доступен в vehicle-VM

`lua/vehicle/controller/drivingDynamics/CMU.lua:146,155`,
`lua/vehicle/extensions/api.lua:46`, `lua/vehicle/partCondition.lua:570` —
vehicle-слой свободно зовёт глобальный `jsonDecode`. Конфиг pedals.json может
парситься прямо в vehicle-слое.

## 9. Формат electrics.values.gear — детект нейтрали

`vehicleController.lua:549`: `electrics.values.gear = gearName`, где gearName из
`shiftLogic.<box>.getGearName()`:

- `manualGearbox.lua:84-86`: **возвращает число** `gearbox.gearIndex`
  (R = -1, **нейтраль = 0**, передачи 1..N);
- `automaticGearbox.lua:97-105`: строка режима ("P"/"R"/"N"/"D"/"L") или
  префикс "M"/"S" + индекс.

⇒ **детект нейтрали: `tostring(electrics.values.gear) == "N" или == "0"**
("N" — автомат, "0" — manual/sequential gearIndex 0). Краевой случай "M0"
(автомат в ручном режиме, индекс 0) не обрабатываем — редкий режим, зафиксировано.

## 10. Потребители input.throttle / electrics.values.throttle_input (для отчёта)

Греп по `lua/vehicle`: `input.throttle` читают посторонние модули
(`postCrashBrake.lua:41-51`, `controlModes.lua:22-24`, `jato.lua:41`,
`telemetryLogger.lua:18`, `cruiseControl.lua:51-54`, `dynamicVehicleData.lua:765`,
`dummy.lua:41` — контроллер-заглушка БЕЗ override-ветки). `throttle_input`
читают дисплей/симуляция (`RacingDisplay.lua:88`, `activeCenterDiff.lua:28`,
`vehicleSystemsCoupling.lua:94`). Выводы:

- основной потребитель управления (vehicleController) — перехвачен Override'ом;
- остальные читатели — датчики/логгеры/краш-логика: видят RAW (AI-команду), это
  НЕ ломает поведение (назначение не «управлять мотором»); зафиксировано как
  известное ограничение, в Фазе 4 не пересматриваем без нужды;
- **критично: `dummy.lua` (controller=dummy) НЕ имеет override-ветки** — машины
  с таким контроллером наш мод не перехватывает; для тестируемых легковых машин
  (East Coast, AI едет) используется vehicleController — проверяется в тесте 3.6.

## 11. Схема кадра нашего мода (итог)

```
кадр N:   ai.updateGFX (85) → input.updateGFX (86) → controller (88, читает
          Override кадра N-1) → extensions.hook (90): мы читаем
          input.state.<k>.val (raw кадра N), сглаживаем, пишем Override.
кадр N+1: контроллер применяет наш Override.
```

Снятие Override: каждый кадр проверяем `ai.isDriving()`; при false (или
`apl_pedals("off")`, onReset) → `electrics.values.*Override = nil` (ИМЕННО nil,
не 0 и не последнее значение — иначе педаль залипает; vehicleController.lua:455
читает `or input.<k>`, т.е. nil = возврат на штатный вход). Условие
«кто-то уже вычистил» отслеживаем флагом, nil пишем один раз.

## 12. Карта ограничений/конфликтов Фазы 3

- cruiseControl.lua и escMeasurement.lua тоже пишут `throttleOverride`:
  конфликт возможен только при одновременном включении круиз-контроля и нашего
  мода (круиз при AI-езде — штатно не используется). Порядок хуков расширений —
  по алфавиту (autopilotLivePedals < cruiseControl) — при конфликте последним
  пишет cruiseControl. Фиксируем как известное ограничение, НЕ чиним в Фазе 3.
- `input.state.<k>.val` может нести «залипший» ввод игрока по клавишам: клавиша
  отпущена → input шлёт 0 через event → val обновляется. Стабильная проблема
  не выявлена, при выявлении — фикс в Фазе 4.

## 13. Соответствие условиям пользователя (У1-У5)

| Условие | Как закрыто |
|---|---|
| У1: запись каждый кадр + сброс в nil при off/not-ai | §11: флаг overridesWritten, nil при off/ai-стоп/onReset |
| У2: инициализация первого кадра smoothed_prev = raw | флаг needInit: rl=ema=out=raw на первом кадре после on/резюме AI |
| У3: parkingbrake не трогаем | §6: override-ключа у ручника нет, наш мод его не создаёт |
| У4: ai.isDriving проверен | §5: ai.lua:6167-6169, экспорт :6216, fallback false |
| У5: rate_limit → ema → lerp | конвейер §11 (порядок утверждён): жёсткий кап скорости первым, ema скругляет, lerp дотягивает; все коэффициенты — time-constant (frame-rate независимые) |

## 14. Принятые микро-решения (в рамках утверждённого плана, для вето в тесте 3.6)

1. **Плавный старт не применяется, если машина уже едет в момент `on`**
   (speed ≥ speed_mps): «начало поездки» = трогание; кап на скорости — не старт,
   а подрезание хода. Иначе — обе рампы (время И скорость, min).
2. **Нейтраль = gear "N" ИЛИ "0"** (§9: manual возвращает число 0).
   Краевой "M0" не обрабатывается.
3. **Арбитраж brake>throttle — ПОСЛЕ сглаживания** (по плану): множитель на
   выход throttle от уже сглаженного brake ⇒ непрерывность гарантирована.
4. **Predictive**: флаг с гистерезисом 0.8→вкл / 0.5→выкл, аддитивный lead
   только при скорости > min_speed; молчит «в горке».
5. **CSV `*_smoothed` = финальные значения модуля** (после арбитража) при
   engaged, иначе копия raw (Фаза-1 поведение).

## 15. Решение по clutch: ТОЛЬКО passthrough (2026-10-12, утверждено пользователем)

**Решение:** clutch ИСКЛЮЧЁН из конвейера сглаживания (rate_limit → ema → lerp).
Поведение: `raw clutch == 0` → модуль не пишет `clutchOverride` вовсе (штатная КПП
работает сама); `raw clutch > 0` → мгновенный passthrough ровно raw (без инерции,
без «плавных 0.3 с»).

**Обоснование — AI сам clutch не пишет, НО ванильная КПП пишет (актуализация
2026-10-15 по данным P1; исходная формулировка «clutch всегда игрок» — неверна):**
- `ai.lua:427-436` — `driveCar(steering, throttle, brake, parkingbrake)`: аргумента
  clutch НЕТ (§7). AI сам через driveCar/scriptai clutch не пишет.
- `ai.lua:5098`, `scriptai`, КПП (`gearbox*`) — clutch только читается/пишется
  штатной логикой трансмиссии, но НЕ из ветки AI-управления.
- **НО empirical (P1, 2026-10-15):** ванильный трансмиссионный стек (КПП-
  автоматика/защита при переключениях) ПИШЕТ clutch при определённых условиях —
  clutch-пульсы есть в OFF-прогонах (4.7-B: 95 строк, 4.8: 77), где модуль
  пассивен. ⇒ `input.state.clutch` в engaged — ввод ИГРОКА **ИЛИ ванильной
  КПП**. Решение passthrough от этого НЕ меняется: raw > 0 → проброс raw
  (лаг 1 кадр), raw = 0 → nil — ноль вреда для обоих источников (5г′: 0 лагов).

**Почему passthrough, а не сглаживание (данные прогона #1, `phase3_report.md`):**
- Прогон #1: 8 clutch-импульсов, `clutchOverride` до 1.0, спад −2.63 ед/с при
  7400 об/мин. Сглаживание clutch растягивает нажатие игрока → машина едет
  «внатяг» дольше, чем игрок задумал, и ощущается как «резкая подача газа с
 цеплением после поворота».
- Мод НИКОГДА не дёргает `input.event` (дизайн-инвариант Фаз 1–2) и не трогает
  КПП/ручник (У3, parkingbrake-override в ванилле не существует — §6). Passthrough
  clutch через `clutchOverride` это подтверждает: игрок выжимает/отпускает сразу,
  латентность только архитектурная 1 кадр (`main.lua:88` контроллер vs `:90` наш
  хук, §1).

**Реализация:** `autopilotLivePedals.lua` — clutch-канал убран из `pipe`/`DEFAULTS`/
`validateConfig`/`stepChannel`; в `updateGFX` блок: `if cltRaw > 0 →
clutchOverride = cltRaw; else if писали → clutchOverride = nil`.

**Следствие для тестов:** кап `clutch_rise/fall` не применим → чекер `check_csv.py`
заменяет проверку 5г-clutch на 5г′ `|clutch_smoothed − clutch_raw| == 0` в engaged
(ожидание passthrough). Смоук `smoke_pedals_csv.py`: clutch-пульсы генерируются
нормально (good), и негативный файл `apl_smoke_badclutch.csv` ловится ровно 1 FAIL
по 5г′. `phase3_csv_analysis.py` — clutch-пункт чек-листа тоже переключён на
passthrough-равенство.
