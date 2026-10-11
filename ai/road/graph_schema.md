# СХЕМА ГРАФА ДОРОГ — ai/road/graph.json (Фаза 2)

Утверждение: план Фазы 2 утверждён пользователем 2026-10-12, уточнения — там же.
Источник данных: навиграф уровня `map.json` → `map.nodes` (ge/map.lua:789,2141,2506).
Исследование: `ai/notes/api_research_phase2.md`.

## Формат хранения: JSON — обоснование

- Один самодостаточный документ `nodes[]` + `edges[]` (в CSV потребовалось бы
  2 файла + join по id, типы полей потерялись бы — всё стало строками).
- В GE есть готовая `jsonWriteFile(filename, obj, pretty)` (common/utils.lua:458),
  в Python — `json`, для чтения агентом/человеком — удобнее структура.
- Путь записи: **относительный от userPath** (sandbox-правило Фазы 1):
  `mods/unpacked/AutopilotLive/ai/road/graph.json`.
- `graph.json` большой — НЕ коммитить (.gitignore); коммитируются:
  эта схема, `graph.example.json` (срез 20 узлов), `marks.csv`.

## Конфиг: ai/config/graph.json

```json
{ "friction_mu": 0.75, "turn_angle_threshold_deg": 20, "speed_round_kph": 5 }
```

| Поле | Назначение |
|---|---|
| `friction_mu` | коэффициент трения для физического предела скорости (μ=0.75 — сухой асфальт с запасом). Хранится ЗДЕСЬ, не в коде (решение пользователя) |
| `turn_angle_threshold_deg` | порог: |угол излома| больше → узел типа `turn` (по умолчанию 20°) |
| `speed_round_kph` | округление рекомендованной скорости ВНИЗ до этого шага (5 км/ч) |

Отсутствующий конфиг → дефолты выше (лог WARN «используются дефолты»).

## Файл graph.json — верхний уровень

```json
{
  "meta": {
    "format_version": 1,
    "created": "2026-10-12 12:00:00",
    "level": "<имя уровня из getLevelInfo или 'unknown'>",
    "build_serial": 123,
    "mu": 0.75,
    "node_count": 0,
    "edge_count": 0,
    "warnings": ["isolated: id=..."]
  },
  "nodes": [ ... ],
  "edges": [ ... ]
}
```

`build_serial` — `map.buildSerial` (map.lua:2667): если карта перезагрузилась,
граф устарел — Фаза 4 сверяет.

## Узел (nodes[])

| Поле | Тип | Правило вывода | Источник |
|---|---|---|---|
| `id` | string | id узла в навграфе (как есть, string — ключи Lua-таблиц) | map.nodes key |
| `x, y, z` | number | координаты узла, м | `pos` (map.lua:175-181) |
| `type` | string | см. правила ниже: `straight / turn / fork / crossroads / dead_end / isolated` | выводится |
| `degree` | int | число связей `links` | `tableSize(links)` |
| `junction_type` | string\|null | только degree ≥ 3: `crossroads` (degree ≥ 4) / `fork` (degree == 3); иначе null | выводится |
| `angle_deg` | number\|null | **ТОЛЬКО degree == 2**: угол излома (см. ниже). degree ≠ 2 → **null** ⚠️ критично для Фазы 4 | выводится |
| `links` | array | для degree ≥ 3 — полный список исходящих рёбер, чтобы Фаза 4 считала углы любой пары на лету: `[{ "edge_id": "n1_n2", "to_id": "...", "direction_deg": 123.4 }]`. Для degree ≤ 2 — пустой массив `[]` (всё есть в рёбрах) | выводится |

### Правила `type` (по degree и углу излома, порог из конфига)

| degree | условие | type |
|---|---|---|
| 0 | — | `isolated` (**WARN в meta.warnings, не FAIL**) |
| 1 | — | `dead_end` |
| 2 | \|angle_deg\| > `turn_angle_threshold_deg` (20°) | `turn` |
| 2 | иначе | `straight` |
| 3 | — | `fork` (+ `junction_type: "fork"`) |
| ≥ 4 | — | `crossroads` (+ `junction_type: "crossroads"`) |

### `angle_deg` (degree == 2 только)

Угол между вектором ВХОДА `v_in = pos(from) − pos(prev)` и ВЫХОДА
`v_out = pos(to) − pos(from)`, где `prev`/`to` — два соседа узла:

```
angle_deg = deg(acos( clamp( dot(v_in, v_out) / (|v_in|·|v_out|), -1, 1 ) ))
```

- Диапазон: 0..180 (0 = прямая, 180 = разворот).
- **degree ≥ 3 → `null`**: вход неоднозначен (сколько входов — столько и
  углов). Фаза 4 берёт азимуты рёбер (`edges[].direction_deg` или
  `nodes[].links[].direction_deg`) и считает углы ЛЮБОЙ пары на лету:
  `Δ = |az1 − az2| mod 360`, меньший угол = `min(Δ, 360 − Δ)`.

## Ребро (edges[])

Источник: `map.nodes[from].links[to]` (map.lua:175-201). Каждая связь даёт
одно ребро; при `oneWay = false` ребро проходимо в обе стороны (поле
`direction`), но в массиве оно ОДНО (from_id/to_id — как в навграфе, порядок
не важен для both-way: направления задаются `direction`).

| Поле | Тип | Правило вывода | Источник |
|---|---|---|---|
| `edge_id` | string | `"<min(id)>_<max(id)>"` (детерминированный порядок, чтобы метки совпадали) | выводится |
| `from_id, to_id` | string | узлы связи (как в `links`, порядок: от `from` к `to` по ключу) | links key |
| `length_m` | number | `\|pos(to) − pos(from)\|` (учитывать inPos/outPos, если есть — длина дуги ≈ хорда; расхождение мало, но берём inPos/outPos если заданы: `length = \|outPos − inPos\|`) | map.lua:175-181 |
| `direction_deg` | number | **азимут from→to: 0° = север (+Y), по часовой**: `(deg(atan2(dx, dy)) + 360) % 360`, dx = x_to − x_from, dy = y_to − y_from | выводится (решение пользователя) |
| `direction` | string | `one-way` если `edge.oneWay` истино, иначе `both` | map.lua:161, links.oneWay |
| `angle_deg` | number\|null | угол излома НА ВХОДЕ в ребро = `angle_deg` узла `from_id`, если degree(from)==2, иначе null (дубликат для удобства: «поворот перед этим ребром») | выводится |
| `radius_m` | number\|null | радиус описанной окружности по трём точкам `(prev, from, to)` (см. ниже); на прямых (S≈0) → **null** | выводится |
| `curvature` | number\|null | `1 / radius_m`; на прямых → **null** | выводится |
| `speed_limit_kph` | number | `edge.speedLimit` (м/с, map.lua:204-231) × 3.6, округлить вниз до `speed_round_kph` | links.speedLimit |
| `recommended_speed_kph` | number | `min(speed_limit_kph, физика)`, шаг вниз до `speed_round_kph`, где физика = `sqrt(μ·g·R)·3.6` (g=9.81, μ из конфига); **если radius_m == null (прямая) → физики нет, только speed_limit_kph** | выводится |

### `radius_m` (три точки)

`prev` — сосед `from` (второй, кроме `to`; только если degree(from)==2,
иначе радиус не определён однозначно → null). Треугольник (prev, from, to):

```
a = |from→to|, b = |prev→to|, c = |prev→from|
S = 0.5 · |cross(prev→from, prev→to)|   (площадь через cross-произведение)
S < 1e-6 → radius_m = null, curvature = null   (коллинеарные = прямая)
иначе: radius_m = a·b·c / (4·S), curvature = 1 / radius_m
```

Примечание: для ребер с `inPos/outPos` (дуги навграфа) тройку точек берём
от позиций концов: `(inPos_prev, inPos_from, outPos_from)` — уточнение
реализации: считаем по pos узлов (дуги между узлами редки и малы), в
`graph_check.py` — статистика по числу null.

## Файл меток: ai/road/marks.csv (CSV, коммитится)

Шапка (создаётся при первом `apl_mark`):

```
time,x,y,z,comment,nearest_node_id,node_dist_m,edge_id
```

| Колонка | Источник |
|---|---|
| `time` | `os.date('%Y-%m-%d %H:%M:%S')` |
| `x,y,z` | позиция машины игрока (`getPlayerVehicle(0):getPosition()`) |
| `comment` | аргумент `apl_mark("текст")` (кавычки экранируются) |
| `nearest_node_id` | ближайший узел — перебор `map.nodes` (min евклид. дистанции) |
| `node_dist_m` | та дистанция, м |
| `edge_id` | `map.findClosestRoad(pos)` → `(n1id, n2id, dist)` → `"<min>_<max>"` — ТОТ ЖЕ формат `edge_id` графа (map.lua:2691). Если API вернул nil → пусто + WARN в консоль |

Связь с графом: `nearest_node_id` и `edge_id` — это id из того же навграфа,
что и `nodes[].id`/`edges[].edge_id` в graph.json ⇒ метка привязана к узлу
И участку дороги графа.

## Критично для Фазы 4 (зафиксировано пользователем)

1. **`angle_deg` определён ТОЛЬКО для degree == 2**; для degree ≥ 3 —
   `null`, используем `junction_type` + `direction_deg` рёбер
   (своих и в `nodes[].links`) — углы любой пары считаются на лету.
2. `direction_deg` — азимут: 0° = север (+Y), по часовой стрелке.
3. Рекомендованная скорость = min(игровой лимит, физика μ из конфига);
   замер из CSV — Фаза 4.
4. На прямых `radius_m = curvature = null` (не 0), если jsonWriteFile
   корректно пишет null — проверяется на первом же экспорте (иначе
   возврат к 0 с WARN в meta).
