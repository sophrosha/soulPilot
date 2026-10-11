# ИССЛЕДОВАНИЕ API BEAMNG 0.39.4 — Фаза 2 (граф дорог)

Дата: 2026-10-12. Источник: чтение исходников `D:\SteamLibrary\steamapps\common\BeamNG.drive\lua\`
(ТОЛЬКО чтение — правило проекта). Цель: найти готовый road network и API для
построения графа-справочника (узлы/рёбра, углы, рекомендованные скорости).

## 1. КЛЮЧЕВОЕ: готовый навиграф уровня — `ge/map.lua`

**Граф дорог в игре СУЩЕСТВУЕТ в открытом виде** — это делает траекторный
сбор (cluster позиций) ненужным: берём навиграф как источник, траектория —
только резерв на случай невалидного `map.json`.

- Источник данных: `mapFilename = levelDir .. 'map.json'` (map.lua:789),
  пустой/невалидный файл обрабатывается с WARN (map.lua:806) — значит,
  **защита «карта не загружена» в экспортёре обязательна**.
- Построение: `loadMap()` (map.lua:2497) → `linkMap()` (map.lua:2141) →
  `map.nodes` (map.lua:2506-2518). Выполняется при загрузке уровня.
- Структура узла: `map.nodes[id] = { pos = vec3, radius = num, links = {...},
  manual, noMerge, endNode, ... }` (map.lua:175-201, 261-278).
- Структура ребра = `map.nodes[n1id].links[n2id]`:
  `{ inNode, outNode, inPos, outPos, inRadius, outRadius, oneWay,
     drivability, speedLimit, ... }`
  - `inPos/outPos` — позиции концов ребра, если отличаются от pos узлов (дуги);
  - `oneWay` — одностороннее движение (map.lua:161 `isOneWay(lanes)`);
  - `radius` узла/`inRadius`/`outRadius` — РАДИУС ДОРОЖНОГО ПОЛОТНА
    (используется в формуле скорости, map.lua:213-216) — НЕ радиус поворота;
  - `drivability` — проходимость (0..1+, влияет на speedLimit).

## 2. Рекомендованная скорость есть готовая — `edge.speedLimit`

`createSpeedLimits(true)` (map.lua:204-231), вызывается из `linkMap()`
(map.lua:2153) → **гарантированно заполнен после загрузки уровня**:

- `autoSpeed = 70км/ч × clamp(((radius × highway + 5) / 8) × drivability, 0.4, 2)`,
  `highway = oneWay and 2 or 1`;
- округление ВНИЗ до стандартного списка метрических лимитов
  `{30, 50, 60, 80, 100, 120}` км/ч (map.lua:205);
- **хранится в м/с** (unit = 3.6, map.lua:206,219) — при экспорте × 3.6.

Собственная физическая модель в движке (для калибровки):
`targetSpeed = sqrt(2 × g × aggression × staticFrictionCoef × dist)`
(vehicle/ai.lua:766) — тот же корень из μ·g, что и наша формула
`v = sqrt(μ × g × R)`.

## 3. API навиграфа (GE-слой, всё читаемое из мода)

| API | Где | Что делает |
|---|---|---|
| `map.nodes` | глобальное расширение `map` | прямой обход узлов/links (наш экспорт) |
| `map.findClosestRoad(pos, r?)` | map.lua:2691, экспорт :3977 | `(n1id, n2id, dist)` — ближайшее ребро: 2 узла + дистанция → для `edge_id` меток |
| `map.findBestRoad(pos, dir)` | map.lua:2718 | ребро по позиции + направлению (fallback → findClosestRoad) |
| `map.getPath(start, target, ...)` | map.lua:2755, :3979 | маршрутизация по узлам |
| `map.getPathPositions(path)` | map.lua:2814 | позиции маршрута |
| `map.buildSerial` | map.lua:2667 | версия карты (для детекта перезагрузки) |

Предупреждение: map.lua:2830 (комментарии в коде) — `findClosestRoad`
расширяет радиус поиска итеративно; на пустой карте возвращает nil — обернуть
в pcall + проверка nil.

## 4. vehicle-side копия — НЕ использовать для экспорта

`vehicle/mapmgr.lua:45-66`: vehicle получает карту через
`obj:getLastMailbox('mapData')` → `lpack.decode` → packed-бинарный формат
(`graphpath` + `kdTreeBox2D` + `nodeAliases`). Человекочитаемых x/y/z там
нет. **Экспорт делаем в GE-слое** (там `map.nodes` в открытом виде).

## 5. AI-маршрут (уточнение по заданию)

- Текущий маршрут конкретной поездки: `vehicle/ai.lua` —
  `currentRoute.plan.targetSpeed` (:191), waypoints-API
  `ai.startup({waypoints, targetSpeeds...})` (:5911-5924), `M.routeSpeed`
  (:11, :255). GE: `ai.driveUsingPath`, `map.getPath`.
- **«Где AI реально ездил за всё время» игра не хранит** — только текущая
  поездка. ⇒ источник графа — НАВИГРАФ, не траектория (решение утверждено
  пользователем).

## 6. Запись JSON из GE

`jsonWriteFile(filename, obj, pretty)` — глобальная (common/utils.lua:458,
вернутия :431-458). Внутри — обычный `io.open` ⇒ действует sandbox-правило
Фазы 1: **ТОЛЬКО относительный путь от userPath** (`mods/unpacked/...`),
иначе FAIL (диагностика apl_diag, пробы 3-4).
Поддержка `nil` в таблицах Lua при сериализации: NULL → `null` в JSON
(стандартное поведение json-библиотеки) — проверить на прямых (radius_m/curvature = null).

## 7. Геометрия (наши формулы)

- `direction_deg` (азимут from→to): **0° = север (+Y), по часовой стрелке**
  (решение пользователя): `(deg(atan2(dx, dy)) + 360) % 360`,
  dx = x_to − x_from, dy = y_to − y_from (BeamNG: X восток, Y север сверху).
- Угол излома на стыке рёбер (degree == 2): угол между
  `v_in = from − prev` и `v_out = to − from`:
  `angle = deg(acos(clamp(dot/(len1×len2), -1, 1)))`.
- Радиус по трём точкам (prev, u, to): `R = a·b·c / (4·S)` (a,b,c — стороны
  треугольника, S — площадь через cross); на прямых (S≈0) → `radius_m = null`,
  `curvature = null` (решение пользователя; если jsonWriteFile ломает null —
  вернёмся к 0, но сначала проверить).

## 8. Принятые решения пользователя (2026-10-12, утверждение плана Фазы 2)

1. `angle_deg` определён ТОЛЬКО для degree == 2; для degree ≥ 3 — `null` +
   поле узла `junction_type` (crossroads / fork) + в узле полный список
   links с азимутами; в ребрах — `direction_deg` (азимут from→to), чтобы
   Фаза 4 считала углы любой пары рёбер на лету.
2. Типы узлов: `straight, turn, fork, crossroads, dead_end, isolated`
   (degree 2 c углом > 20° → turn; ==3 → fork; ≥4 → crossroads; ==1 →
   dead_end; ==0 → isolated, WARN при экспорте, не FAIL).
3. `recommended_speed_kph = min(игровой speedLimit, sqrt(μ·g·R)·3.6)`,
   **μ = 0.75 вынести в `ai/config/graph.json`** (не хардкод); округление
   вниз до 5 км/ч; замер фактической скорости из CSV — в Фазу 4.
   `radius_m`/`curvature` на прямых → `null`.
4. Бинда `apl_mark` — НЕ в Фазе 2 (позже, отдельно).
5. Хранение: `ai/road/graph.json` (не коммитить — большой),
   `marks.csv` (коммитить), `graph_schema.md` + `graph.example.json`
   (срез 20 узлов, коммитить). Формат графа — JSON (обоснование в схеме).
6. `marks.csv`: колонки включая `edge_id` (ближайшее ребро через
   `map.findClosestRoad`).

## 9. Правила проекта (напоминание после сжатия)

- ТОЛЬКО русский в общении и комментариях; имена переменных — английские.
- НЕ править `D:\...\BeamNG.drive\lua\*` (только читать).
- НЕ запускать игру самому, не лезть в личные файлы, не в интернет кроме
  документации BeamNG.
- AutopilotLive = оверлей: НЕ дёргать input.event, НЕ трогать КПП,
  НЕ подменять AI, НЕ менять исходники игры.
- Фазы: план → утверждение → код → тест → коммит (рус.). PROJECT_STATE.md
  читать в начале сессии, обновлять после каждого коммита.
- Данные — в ai/ папки мода; Python — только через ai/venv/.
- Пути записи в Lua — ТОЛЬКО относительные от userPath (sandbox io.open).
- После 2.2 (graph_schema.md) — СТОП на утверждение пользователя.
- В Фазу 3 не заходить без команды.
