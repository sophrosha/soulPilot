# -*- coding: utf-8 -*-
"""Проверка graph.json (Фаза 2, шаг 2.4) — граф дорог AutopilotLive.

Запуск (только через venv проекта!):
    ai/venv/Scripts/python.exe ai/notes/graph_check.py <путь/к/graph.json> [--example]

Что проверяет (по ai/road/graph_schema.md):
  1. JSON парсится, есть meta/nodes/edges.
  2. meta: format_version == 1, node_count/edge_count сходятся с содержимым,
     isolated_count == числу узлов type='isolated', mu > 0,
     warnings — список не более 11 записей (лимит 10 + отсылка).
  3. Узлы: id — строки и уникальны, x/y/z числа, type из множества схемы,
     degree — целое >= 0.
  4. angle_deg: число [0..180] ТОЛЬКО при degree == 2, иначе null.
  5. junction_type: 'fork' при degree == 3, 'crossroads' при >= 4, иначе null.
  6. links: при degree >= 3 — список длины degree (edge_id/to_id/direction_deg
     в [0..360)), при degree < 3 — пусто.
  7. Ссылки links разрешаются в существующие узлы (иначе WARN — битая ссылка
     навиграфа; экспортёр такие рёбра пропускает).
  8. Рёбра: edge_id уникальны и == min(from,to)_max(from,to), from ~= to,
     оба узла существуют, length_m > 0.
  9. direction из {'one-way','both'}, direction_deg число [0..360].
  10. radius_m: null или > 0; curvature: null <=> radius_m null, иначе = 1/radius.
  11. speed_limit_kph / recommended_speed_kph: null или > 0;
      recommended <= limit, если оба числа.
  12. angle_from_deg / angle_to_deg: null либо равны angle_deg
      соответствующего узла from_id/to_id (дубликат-инвариант схемы).
  13. Степени: phantom = sum(degree) - 2*edge_count == 0 (иначе WARN —
      битые ссылки в links).
  14. Покрытие: каждый узел с degree >= 1 встречается хотя бы в одном ребре;
      узлы с degree == 0 (isolated) не участвуют в рёбрах.

Примечание про пустые таблицы: Lua-пустая таблица сериализуется как {},
а не [] (utils.lua:394) — экспортёр пишет links={} при degree<3 и
warnings={} при отсутствии предупреждений. Чекер принимает оба варианта.

Флаг --example дополнительно прогоняет ПОЛУРЯДНЫЙ контроль graph.example.json
(срез 20 узлов): инварианты полного графа (счётчики meta, phantom, покрытие)
пропускаются — срез их заведомо нарушает.

Выход: список PASS/FAIL, код возврата 0 если всё ок, 1 если есть FAIL.
"""
import json
import sys
from pathlib import Path

# Windows-консоль по умолчанию cp1252/cp866 — кириллица падает с
# UnicodeEncodeError. Принудительно переключаем вывод в UTF-8.
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

NODE_TYPES = {'straight', 'turn', 'fork', 'crossroads', 'dead_end', 'isolated'}
DIRECTIONS = {'one-way', 'both'}


def is_num(v) -> bool:
    """Число (но не bool — bool в Python это подкласс int)."""
    return isinstance(v, (int, float)) and not isinstance(v, bool)


def edge_id_of(a: str, b: str) -> str:
    return f'{a}_{b}' if a <= b else f'{b}_{a}'


def as_list(v):
    """Lua пишет пустую таблицу как {} — принимаем и {} (нет ссылок), и []."""
    if isinstance(v, list):
        return v
    if v == {}:
        return []
    return None


def validate(data, relaxed: bool = False):
    results: list[tuple[bool, str]] = []
    warns: list[str] = []

    def check(ok: bool, msg: str) -> None:
        results.append((bool(ok), msg))

    # --- 1. структура верхнего уровня ---
    check(isinstance(data, dict), 'JSON — объект')
    if not isinstance(data, dict):
        return results, warns, {}
    meta = data.get('meta')
    nodes = data.get('nodes')
    edges = as_list(data.get('edges')) if relaxed else data.get('edges')
    check(isinstance(meta, dict), 'meta — объект')
    check(isinstance(nodes, list) and len(nodes) > 0,
          f'nodes — непустой список (получено: {len(nodes) if isinstance(nodes, list) else type(nodes).__name__})')
    check(isinstance(edges, list), 'edges — список')
    if not isinstance(nodes, list) or not isinstance(edges, list):
        return results, warns, {}

    # --- 2. meta ---
    if isinstance(meta, dict):
        check(meta.get('format_version') == 1,
              f"meta.format_version == 1 (получено {meta.get('format_version')!r})")
        mu = meta.get('mu')
        check(is_num(mu) and mu > 0, f'meta.mu > 0 (получено {mu!r})')
        warnings = as_list(meta.get('warnings'))
        check(warnings is not None and len(warnings) <= 11,
              'meta.warnings — список <= 11 записей (лимит 10 + отсылка; '
              f'получено {meta.get("warnings")!r})'
              if warnings is None else
              f'meta.warnings — список <= 11 записей (получено {len(warnings)})')
        if not relaxed:
            check(meta.get('node_count') == len(nodes),
                  f'meta.node_count == {len(nodes)} (получено {meta.get("node_count")!r})')
            check(meta.get('edge_count') == len(edges),
                  f'meta.edge_count == {len(edges)} (получено {meta.get("edge_count")!r})')

    # --- 3. узлы: базовые поля ---
    node_by_id: dict = {}
    dup_ids, bad_id, bad_pos, bad_type, bad_degree = [], [], [], [], []
    for nd in nodes:
        if not isinstance(nd, dict):
            bad_id.append(repr(nd)[:40])
            continue
        nid = nd.get('id')
        if not isinstance(nid, str):
            bad_id.append(f'id={nid!r}')
            continue
        if nid in node_by_id:
            dup_ids.append(nid)
        node_by_id[nid] = nd
        if not all(is_num(nd.get(k)) for k in ('x', 'y', 'z')):
            bad_pos.append(nid)
        if nd.get('type') not in NODE_TYPES:
            bad_type.append(f'{nid}:{nd.get("type")!r}')
        deg = nd.get('degree')
        if not (isinstance(deg, int) and not isinstance(deg, bool) and deg >= 0):
            bad_degree.append(f'{nid}:{deg!r}')
    check(not dup_ids, f'узлы: id уникальны (дубликаты: {dup_ids[:5] or "нет"})')
    check(not bad_id, f'узлы: id — строки (проблемы: {bad_id[:5] or "нет"})')
    check(not bad_pos, f'узлы: x/y/z числа (проблемы: {bad_pos[:5] or "нет"})')
    check(not bad_type, f'узлы: type из {sorted(NODE_TYPES)} (проблемы: {bad_type[:5] or "нет"})')
    check(not bad_degree, f'узлы: degree — целое >= 0 (проблемы: {bad_degree[:5] or "нет"})')

    # --- 4-6. угол/развязка/ссылки узла ---
    bad_angle, bad_junction, bad_links, bad_azimuth, bad_link_ref = [], [], [], [], []
    for nd in nodes:
        if not isinstance(nd, dict):
            continue
        nid, deg = nd.get('id'), nd.get('degree')
        if not (isinstance(deg, int) and not isinstance(deg, bool)):
            continue
        if 'angle_deg' not in nd:
            bad_angle.append(f'{nid}: ключ отсутствует (нужен явный null)')
        else:
            ang = nd.get('angle_deg')
            if deg == 2:
                if not (is_num(ang) and 0 <= ang <= 180):
                    bad_angle.append(f'{nid}: degree==2, а angle_deg={ang!r}')
            elif ang is not None:
                bad_angle.append(f'{nid}: degree={deg}, а angle_deg={ang!r} (ожидался null)')
        want_jt = 'fork' if deg == 3 else ('crossroads' if deg >= 4 else None)
        if nd.get('junction_type') != want_jt:
            bad_junction.append(f'{nid}: degree={deg}, junction_type={nd.get("junction_type")!r} '
                                f'(ожидалось {want_jt!r})')
        links = as_list(nd.get('links'))
        if deg >= 3:
            if links is None or len(links) != deg:
                bad_links.append(f'{nid}: degree={deg}, links={nd.get("links")!r}'[:70])
                continue
            for lnk in links:
                ok = (isinstance(lnk, dict) and isinstance(lnk.get('edge_id'), str)
                      and isinstance(lnk.get('to_id'), str) and is_num(lnk.get('direction_deg'))
                      and 0 <= lnk['direction_deg'] < 360)
                if not ok:
                    bad_azimuth.append(f'{nid}: {lnk!r}'[:70])
                elif lnk['to_id'] not in node_by_id:
                    bad_link_ref.append(f"{nid}->{lnk['to_id']}")
        elif links != []:  # None (пустая Lua-таблица -> {}) уже == [] через as_list
            bad_links.append(f'{nid}: degree={deg}, а links не пуст: {nd.get("links")!r}'[:70])
    check(not bad_angle, f'angle_deg только при degree==2, диапазон [0..180] (проблемы: {bad_angle[:5] or "нет"})')
    check(not bad_junction, f'junction_type по degree (проблемы: {bad_junction[:5] or "нет"})')
    check(not bad_links, f'links: пуст при degree<3, длина == degree при >=3 (проблемы: {bad_links[:5] or "нет"})')
    check(not bad_azimuth, f'links: edge_id/to_id/direction_deg [0..360) (проблемы: {bad_azimuth[:5] or "нет"})')
    if bad_link_ref:
        warns.append(f'[WARN] битые ссылки в links (нет узла): {bad_link_ref[:5]}'
                     + (f' ... всего {len(bad_link_ref)}' if len(bad_link_ref) > 5 else ''))

    # --- 8-12. рёбра ---
    edge_ids_seen: set = set()
    dup_edges, bad_pair, bad_len, bad_dir, bad_az = [], [], [], [], []
    bad_radius, bad_curv, bad_speed, bad_angle_dup = [], [], [], []
    no_radius = 0
    for e in edges:
        if not isinstance(e, dict):
            bad_pair.append(repr(e)[:40])
            continue
        eid, fid, tid = e.get('edge_id'), e.get('from_id'), e.get('to_id')
        if not all(isinstance(s, str) for s in (eid, fid, tid)):
            bad_pair.append(f'{eid!r}/{fid!r}/{tid!r}')
            continue
        if eid in edge_ids_seen:
            dup_edges.append(eid)
        edge_ids_seen.add(eid)
        if fid == tid:
            bad_pair.append(f'{eid}: from_id == to_id')
        if fid not in node_by_id or tid not in node_by_id:
            bad_pair.append(f'{eid}: узел не найден ({fid}/{tid})')
        if eid != edge_id_of(fid, tid):
            bad_pair.append(f'{eid}: не совпадает с min_max({fid},{tid})')
        ln = e.get('length_m')
        if not (is_num(ln) and ln > 0):
            bad_len.append(f'{eid}:{ln!r}')
        if e.get('direction') not in DIRECTIONS:
            bad_dir.append(f'{eid}:{e.get("direction")!r}')
        az = e.get('direction_deg')
        if not (is_num(az) and 0 <= az <= 360):
            bad_az.append(f'{eid}:{az!r}')
        rad, curv = e.get('radius_m'), e.get('curvature')
        if rad is None:
            no_radius += 1
            if curv is not None:
                bad_curv.append(f'{eid}: radius null, а curvature={curv!r}')
        elif not (is_num(rad) and rad > 0):
            bad_radius.append(f'{eid}:{rad!r}')
        else:
            want_curv = 1.0 / rad
            if not (is_num(curv) and abs(curv - want_curv) <= 1e-6 * max(1.0, want_curv)):
                bad_curv.append(f'{eid}: curvature={curv!r}, ожидалось {want_curv:.6g}')
        lim, rec = e.get('speed_limit_kph'), e.get('recommended_speed_kph')
        if lim is not None and not (is_num(lim) and lim > 0):
            bad_speed.append(f'{eid}: speed_limit_kph={lim!r}')
        if rec is not None:
            if not (is_num(rec) and rec > 0):
                bad_speed.append(f'{eid}: recommended_speed_kph={rec!r}')
            elif is_num(lim) and rec > lim:
                bad_speed.append(f'{eid}: recommended {rec} > limit {lim}')
        for k, node_key in (('angle_from_deg', fid), ('angle_to_deg', tid)):
            v = e.get(k)
            if v is not None:
                nd = node_by_id.get(node_key)
                na = nd.get('angle_deg') if isinstance(nd, dict) else None
                if not (is_num(v) and is_num(na) and abs(v - na) < 1e-6):
                    bad_angle_dup.append(f'{eid}:{k}={v!r} vs узел {node_key} angle_deg={na!r}')
    check(not dup_edges, f'рёбра: edge_id уникальны (дубликаты: {dup_edges[:5] or "нет"})')
    check(not bad_pair, f'рёбра: min_max-формат id, узлы существуют, from~=to (проблемы: {bad_pair[:5] or "нет"})')
    check(not bad_len, f'length_m > 0 (проблемы: {bad_len[:5] or "нет"})')
    check(not bad_dir, f"direction из {sorted(DIRECTIONS)} (проблемы: {bad_dir[:5] or 'нет'})")
    check(not bad_az, f'direction_deg в [0..360] (проблемы: {bad_az[:5] or "нет"})')
    check(not bad_radius and not bad_curv,
          f'radius_m/curvature согласованы (radius: {bad_radius[:3] or "нет"}, curvature: {bad_curv[:3] or "нет"})')
    check(not bad_speed, f'скорости > 0, recommended <= limit (проблемы: {bad_speed[:5] or "нет"})')
    check(not bad_angle_dup, f'angle_from/to == angle_deg узла (проблемы: {bad_angle_dup[:5] or "нет"})')

    # --- 13-14. инварианты полного графа (пропускаются для среза) ---
    if not relaxed:
        deg_sum = 0
        isolated_real = 0
        missing_cov = []
        involved: set = set()
        for e in edges:
            if isinstance(e, dict):
                involved.add(e.get('from_id'))
                involved.add(e.get('to_id'))
        for nd in nodes:
            if not isinstance(nd, dict):
                continue
            deg = nd.get('degree')
            if isinstance(deg, int) and not isinstance(deg, bool):
                deg_sum += deg
                if deg >= 1 and nd.get('id') not in involved:
                    missing_cov.append(nd.get('id'))
            if nd.get('type') == 'isolated':
                isolated_real += 1
                if nd.get('id') in involved:
                    missing_cov.append(f"{nd.get('id')}: isolated, но есть ребро")
        phantom = deg_sum - 2 * len(edges)
        if phantom != 0:
            warns.append(f'[WARN] phantom = sum(degree) - 2*edges = {phantom} '
                         '(битые ссылки в links — экспортёр пропускает такие рёбра)')
        check(not missing_cov,
              f'каждый узел с degree>=1 есть в рёбрах, isolated — нет (проблемы: {missing_cov[:5] or "нет"})')
        if isinstance(meta, dict):
            check(meta.get('isolated_count') == isolated_real,
                  f"meta.isolated_count == {isolated_real} (получено {meta.get('isolated_count')!r})")

    # --- статистика ---
    stats = {
        'nodes': len(nodes),
        'edges': len(edges),
        'no_radius': no_radius,
        'types': {},
        'one_way': 0,
    }
    for nd in nodes:
        if isinstance(nd, dict):
            t = nd.get('type')
            stats['types'][t] = stats['types'].get(t, 0) + 1
    for e in edges:
        if isinstance(e, dict) and e.get('direction') == 'one-way':
            stats['one_way'] += 1
    return results, warns, stats


def run_one(path: Path, relaxed: bool) -> int:
    try:
        data = json.loads(path.read_text(encoding='utf-8'))
    except Exception as e:  # noqa: BLE001
        print(f"FAIL: не смог прочитать JSON: {e}")
        return 1
    results, warns, stats = validate(data, relaxed=relaxed)
    print(f"Файл: {path}{' (полулярный контроль среза)' if relaxed else ''}")
    if stats:
        pct = (100.0 * stats['no_radius'] / stats['edges']) if stats['edges'] else 0.0
        print(f"Узлов: {stats['nodes']}, рёбер: {stats['edges']}, "
              f"без radius_m: {stats['no_radius']} ({pct:.1f}%), one-way: {stats['one_way']}")
        print(f"Типы узлов: {stats['types']}")
    print()
    fails = 0
    for ok, msg in results:
        mark = 'PASS' if ok else 'FAIL'
        if not ok:
            fails += 1
        print(f"  [{mark}] {msg}")
    for w in warns:
        print(f"  {w}")
    print()
    if fails == 0:
        print(f"ИТОГ: все {len(results)} проверок пройдены.")
        return 0
    print(f"ИТОГ: {fails} из {len(results)} проверок НЕ пройдены.")
    return 1


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    if not path.exists():
        print(f"FAIL: файл не найден: {path}")
        return 2
    code = run_one(path, relaxed=False)
    if '--example' in sys.argv[2:]:
        example = path.parent / 'graph.example.json'
        if not example.exists():
            print(f"FAIL: --example задан, но файла нет: {example}")
            return 1
        print('=' * 60)
        code_example = run_one(example, relaxed=True)
        code = max(code, code_example)
    return code


if __name__ == '__main__':
    sys.exit(main())
