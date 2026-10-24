#!/usr/bin/env python3
"""graph_viz.py — визуализация graph.json из навиграфа (Фаза 2.5).

Генерирует три файла рядом с graph.json:
  graph_full.png  — весь граф сверху (matplotlib): узлы точками с цветом по
                    типу, рёбра (толщина = speed_limit_kph, цвет = radius_m
                    по log10-шкале viridis; radius_m == null — серые тонкие,
                    one-way — пунктир), метки marks.csv красными звёздочками,
                    легенда, заголовок «<level>: N узлов, M рёбер».
  graph_zoom.png  — кроп ±100 м вокруг первого узла type == 'crossroads'
                    (fallback: первый turn): подписи узлов, у рёбер —
                    radius/скорость. Для отладки Фазы 4.
  graph.html      — интерактивная версия (plotly, offline — plotly.js
                    инлайнится): зум/пан/hover; hover на узле — id, type,
                    degree, angle_deg, junction_type; hover на ребре — edge_id,
                    length_m, direction_deg, speed_limit/recommended/radius;
                    чекбоксы типов узлов сбоку; метки — красные звёздочки
                    с комментарием.

Запуск:
  ai/venv/Scripts/python.exe ai/notes/graph_viz.py <graph.json> [marks.csv]

marks.csv опционален: файла нет или только шапка — граф рисуется без меток,
без ошибок. Все сообщения в консоль — только ASCII (кодировка консоли Windows).
"""
from __future__ import annotations

import csv
import json
import os
import sys
from pathlib import Path

import matplotlib

matplotlib.use('Agg')  # без дисплея — генерация файлов
import matplotlib.pyplot as plt
import numpy as np
import plotly.graph_objects as go
import plotly.io as pio
from matplotlib.cm import ScalarMappable
from matplotlib.collections import LineCollection
from matplotlib.lines import Line2D

# Кириллица в заголовках/легендах PNG: DejaVu Sans встроен в matplotlib
plt.rcParams['font.family'] = 'DejaVu Sans'
plt.rcParams['axes.unicode_minus'] = False

# --- Палитры ----------------------------------------------------------------
# Цвета типов узлов (PNG и HTML)
NODE_COLORS = {
    'straight': '#9e9e9e',   # серый — задний план (большинство)
    'turn': '#ff9800',       # оранжевый
    'fork': '#9c27b0',       # фиолетовый
    'crossroads': '#e45756', # красный
    'dead_end': '#4e79a7',   # синий
    'isolated': '#000000',   # чёрный
}
NODE_TYPES = ['straight', 'turn', 'fork', 'crossroads', 'dead_end', 'isolated']
NULL_EDGE_COLOR = '#cccccc'  # рёбра без radius_m (прямые/junction)
MARK_COLOR = '#d62728'       # метки marks.csv
# Бины radius_m для HTML-легенды (null рисуется отдельно, серым)
RADIUS_BINS = [15.0, 30.0, 60.0, 120.0, 300.0, 1000.0]
ZOOM_HALF = 100.0  # полубокс кропа, м


def fmt(v, spec='{:.1f}'):
    """Число в строку, None -> '—' (для hover/подписей)."""
    if v is None:
        return '—'
    try:
        return spec.format(v)
    except (ValueError, TypeError):
        return str(v)


def load_marks(path: Path | None) -> list[dict]:
    """marks.csv -> список меток; нет файла/пусто/битые строки -> []."""
    if path is None or not path.exists():
        return []
    marks = []
    try:
        with path.open('r', encoding='utf-8', newline='') as f:
            for row in csv.DictReader(f):
                try:
                    marks.append({
                        'x': float(row['x']),
                        'y': float(row['y']),
                        'comment': (row.get('comment') or '').strip(),
                        'time': (row.get('time') or '').strip(),
                        'node': (row.get('nearest_node_id') or '').strip(),
                        'edge': (row.get('edge_id') or '').strip(),
                    })
                except (KeyError, ValueError, TypeError):
                    continue  # битая строка — пропускаем
    except OSError:
        return []
    return marks


def edge_geometry(graph: dict):
    """Геометрия рёбер: сегменты + атрибуты (скорость, radius, one-way)."""
    nodes = {n['id']: n for n in graph['nodes']}
    segs, speeds, radii, one_way = [], [], [], []
    for e in graph['edges']:
        a, b = nodes[e['from_id']], nodes[e['to_id']]
        segs.append([(a['x'], a['y']), (b['x'], b['y'])])
        speeds.append(e.get('speed_limit_kph'))
        radii.append(e.get('radius_m'))
        one_way.append(e.get('direction') == 'one-way')
    return segs, speeds, radii, one_way


def speed_widths(speeds: list, lo=0.3, hi=1.8) -> list:
    """Толщина линии по speed_limit_kph (маппинг min..max -> lo..hi pt)."""
    known = [s for s in speeds if s]
    if not known:
        return [lo] * len(speeds)
    smin, smax = min(known), max(known)
    span = (smax - smin) or 1.0
    return [lo + (hi - lo) * (s - smin) / span if s else lo for s in speeds]


def radius_norm(radii: list):
    """LogNorm по измеренным radius_m (null исключены)."""
    known = [r for r in radii if r]
    vmin, vmax = min(known), max(known)
    if vmax <= vmin:
        vmax = vmin * 1.1
    return vmin, vmax


def level_label(graph: dict) -> str:
    """Имя карты для заголовка: meta.level, fallback — целевая карта проекта."""
    lvl = (graph.get('meta') or {}).get('level')
    if lvl and lvl != 'unknown':
        return str(lvl)
    # Экспортёр Фазы 2 не получил имя миссии (meta.level = 'unknown') —
    # используем проектную целевую карту (см. PROJECT_STATE).
    return 'East Coast'


def draw_png(graph: dict, marks: list[dict], out_path: Path,
             zoom_node: dict | None = None) -> None:
    """PNG: весь граф (zoom_node=None) или кроп вокруг узла (zoom_node=узел)."""
    segs, speeds, radii, one_way = edge_geometry(graph)
    widths = speed_widths(speeds)
    vmin, vmax = radius_norm(radii)
    norm = plt.Normalize(vmin=vmin, vmax=vmax)

    big = zoom_node is not None
    fig, ax = plt.subplots(figsize=(16, 16), dpi=150)

    # Рёбра без radius_m — сначала (подложка), серые тонкие
    null_mask = [r is None for r in radii]
    null_segs = [s for s, m in zip(segs, null_mask) if m]
    if null_segs:
        ax.add_collection(LineCollection(
            null_segs, colors=NULL_EDGE_COLOR, linewidths=0.3,
            linestyles=['--' if w else '-' for s, w, m in zip(segs, one_way, null_mask) if m],
            zorder=1))
    # Измеренные radius — градиент viridis по log10
    col_segs = [s for s, m in zip(segs, null_mask) if not m]
    col_radii = [r for r, m in zip(radii, null_mask) if not m]
    col_styles = ['--' if w else '-' for w, m in zip(one_way, null_mask) if not m]
    col_widths = [w for w, m in zip(widths, null_mask) if not m]
    lc = LineCollection(col_segs, cmap='viridis', norm=norm,
                        linewidths=col_widths, linestyles=col_styles, zorder=2)
    lc.set_array(np.array(col_radii, dtype=float))
    ax.add_collection(lc)

    # Узлы: по типам (для легенды)
    node_size = 60 if big else 7
    for t in NODE_TYPES:
        pts = [(n['x'], n['y']) for n in graph['nodes'] if n['type'] == t]
        if pts:
            xs, ys = zip(*pts)
            ax.scatter(xs, ys, s=node_size, c=NODE_COLORS[t], label=t,
                       linewidths=0, zorder=4)

    # Метки marks.csv — красные звёздочки (+ комментарий)
    if marks:
        xs = [m['x'] for m in marks]
        ys = [m['y'] for m in marks]
        ax.scatter(xs, ys, s=260 if big else 200, c=MARK_COLOR, marker='*',
                   edgecolors='black', linewidths=0.6, zorder=6,
                   label='метка (marks.csv)')
        if big:  # в кропе подписи не мешают
            for m in marks:
                ax.annotate(m['comment'], (m['x'], m['y']),
                            textcoords='offset points', xytext=(7, 7),
                            fontsize=8, zorder=7,
                            bbox=dict(boxstyle='round,pad=0.2', fc='white',
                                      ec='none', alpha=0.75))

    meta = graph.get('meta') or {}
    if not big:
        # Подписи узлов и radius/скорость у рёбер — только в кропе
        title = f"{level_label(graph)}: {len(graph['nodes'])} узлов, {len(graph['edges'])} рёбер"
    else:
        cx, cy = zoom_node['x'], zoom_node['y']
        for n in graph['nodes']:
            if abs(n['x'] - cx) <= ZOOM_HALF and abs(n['y'] - cy) <= ZOOM_HALF:
                ax.annotate(f"{n['id']} ({n['type']})", (n['x'], n['y']),
                            textcoords='offset points', xytext=(5, 5),
                            fontsize=7, zorder=7)
        nodes = {n['id']: n for n in graph['nodes']}
        for e in graph['edges']:
            a, b = nodes[e['from_id']], nodes[e['to_id']]
            mx, my = (a['x'] + b['x']) / 2, (a['y'] + b['y']) / 2
            if abs(mx - cx) <= ZOOM_HALF and abs(my - cy) <= ZOOM_HALF:
                ax.annotate(f"R={fmt(e.get('radius_m'), '{:.0f}')} м  "
                            f"v={fmt(e.get('speed_limit_kph'), '{:.0f}')} км/ч",
                            (mx, my), textcoords='offset points',
                            xytext=(3, -9), fontsize=6.5, zorder=7, alpha=0.85)
        ax.set_xlim(cx - ZOOM_HALF, cx + ZOOM_HALF)
        ax.set_ylim(cy - ZOOM_HALF, cy + ZOOM_HALF)
        title = (f"Кроп ±{ZOOM_HALF:.0f} м: узел {zoom_node['id']} "
                 f"({zoom_node['type']})")

    ax.set_aspect('equal')
    ax.set_title(title, fontsize=16)
    ax.grid(True, alpha=0.15)
    # Цветовая шкала radius_m
    cbar = fig.colorbar(ScalarMappable(norm=norm, cmap='viridis'),
                        ax=ax, shrink=0.55, pad=0.02)
    cbar.set_label('radius_m, м (log10)', fontsize=10)
    # Легенда: типы узлов + спецслучаи линий
    handles, labels = ax.get_legend_handles_labels()
    handles += [Line2D([], [], color='black', ls='--', lw=1.2, label='one-way'),
                Line2D([], [], color=NULL_EDGE_COLOR, lw=1.2, label='radius_m = null')]
    labels += ['one-way', 'radius_m = null']
    ax.legend(handles=handles, labels=labels, loc='lower left',
              fontsize=9, title='Типы узлов / линии', title_fontsize=9)
    fig.savefig(out_path, bbox_inches='tight', facecolor='white')
    plt.close(fig)


def pick_zoom_node(graph: dict) -> dict | None:
    """Первый crossroads (по порядку файла); нет — первый turn; нет — None."""
    for want in ('crossroads', 'turn'):
        for n in graph['nodes']:
            if n['type'] == want:
                return n
    return None


def make_html(graph: dict, marks: list[dict], out_path: Path) -> None:
    """plotly HTML: зум/пан/hover, чекбоксы типов, метки-звёздочки."""
    nodes = {n['id']: n for n in graph['nodes']}
    fig = go.Figure()
    edge_trace_count = 0

    # --- Рёбра: линии по бинам radius_m (NaN-разделители), hover по серединкам
    def bin_index(r):
        if r is None:
            return len(RADIUS_BINS)  # последняя группа — null
        for i, edge in enumerate(RADIUS_BINS):
            if r < edge:
                return i
        return len(RADIUS_BINS)

    n_groups = len(RADIUS_BINS) + 1
    cmap = plt.get_cmap('viridis')
    group_xy = [[[], []] for _ in range(n_groups)]
    for e in graph['edges']:
        a, b = nodes[e['from_id']], nodes[e['to_id']]
        gi = bin_index(e.get('radius_m'))
        group_xy[gi][0] += [a['x'], b['x'], None]
        group_xy[gi][1] += [a['y'], b['y'], None]
    for i, (gx, gy) in enumerate(group_xy):
        if not gx:
            continue
        if i < len(RADIUS_BINS):
            lo = 0 if i == 0 else RADIUS_BINS[i - 1]
            color = 'rgb' + str(tuple(int(255 * c) for c in cmap(i / (n_groups - 2))[:3]))
            name = f"R {lo:.0f}–{RADIUS_BINS[i]:.0f} м"
        else:
            color, name = NULL_EDGE_COLOR, 'R null (прямые)'
        fig.add_trace(go.Scatter(x=gx, y=gy, mode='lines', name=name,
                                 line=dict(color=color, width=1.2),
                                 hoverinfo='skip'))
        edge_trace_count += 1

    # Невидимые середины рёбер — hover с полями ребра
    mid_x, mid_y, custom = [], [], []
    for e in graph['edges']:
        a, b = nodes[e['from_id']], nodes[e['to_id']]
        mid_x.append((a['x'] + b['x']) / 2)
        mid_y.append((a['y'] + b['y']) / 2)
        custom.append([e['edge_id'], fmt(e.get('length_m')),
                       fmt(e.get('direction_deg'), '{:.0f}'),
                       fmt(e.get('speed_limit_kph'), '{:.0f}'),
                       fmt(e.get('recommended_speed_kph'), '{:.0f}'),
                       fmt(e.get('radius_m'), '{:.0f}')])
    fig.add_trace(go.Scatter(
        x=mid_x, y=mid_y, mode='markers', name='_edge_hover',
        marker=dict(size=9, opacity=0), customdata=custom, showlegend=False,
        hovertemplate=(
            'edge_id: %{customdata[0]}<br>'
            'length_m: %{customdata[1]}<br>'
            'direction_deg: %{customdata[2]}<br>'
            'speed_limit_kph: %{customdata[3]}<br>'
            'recommended_kph: %{customdata[4]}<br>'
            'radius_m: %{customdata[5]}<extra></extra>')))

    # --- Узлы: trace на тип (чекбоксы toggлят видимость по индексу trace)
    node_trace_index: dict[str, int] = {}
    hover_tmpl_node = (
        'id: %{customdata[0]}<br>type: %{customdata[1]}<br>'
        'degree: %{customdata[2]}<br>angle_deg: %{customdata[3]}<br>'
        'junction: %{customdata[4]}<extra></extra>')
    for t in NODE_TYPES:
        pts = [n for n in graph['nodes'] if n['type'] == t]
        if not pts:
            continue
        node_trace_index[t] = len(fig.data)
        fig.add_trace(go.Scatter(
            x=[n['x'] for n in pts], y=[n['y'] for n in pts], mode='markers',
            name=t, marker=dict(color=NODE_COLORS[t], size=6, opacity=0.85),
            customdata=[[n['id'], n['type'], n['degree'],
                         fmt(n.get('angle_deg'), '{:.0f}'),
                         n.get('junction_type') or '—'] for n in pts],
            hovertemplate=hover_tmpl_node))

    # --- Метки marks.csv — красные звёздочки
    if marks:
        fig.add_trace(go.Scatter(
            x=[m['x'] for m in marks], y=[m['y'] for m in marks],
            mode='markers', name='метки',
            marker=dict(symbol='star', color=MARK_COLOR, size=15,
                        line=dict(color='black', width=1)),
            text=[f"{m['comment']}<br>{m['time']}<br>узел: {m['node']}<br>"
                  f"ребро: {m['edge']}" for m in marks],
            hovertemplate='%{text}<extra>метка</extra>'))

    meta = graph.get('meta') or {}
    fig.update_layout(
        title=f"{level_label(graph)}: {len(graph['nodes'])} узлов, "
              f"{len(graph['edges'])} рёбер (интерактив, Фаза 2.5)",
        template='plotly_white', width=1500, height=1000,
        legend=dict(bgcolor='rgba(255,255,255,0.85)'),
        uirevision='apl-graph')
    fig.update_yaxes(scaleanchor='x', scaleratio=1)

    # div_id фиксирован — JS панель чекбоксов обращается к нему
    plot_div = pio.to_html(fig, full_html=False, include_plotlyjs=True,
                           div_id='apl-graph', config={'responsive': True})

    # Панель чекбоксов (тип узлов -> индекс trace)
    boxes = []
    for t in NODE_TYPES:
        if t in node_trace_index:
            boxes.append(
                f'<label><input type="checkbox" data-idx="{node_trace_index[t]}" '
                f'checked> {t}</label><br>')
    html = f"""<!DOCTYPE html>
<html lang="ru">
<head><meta charset="utf-8"><title>AutopilotLive: граф (Фаза 2.5)</title></head>
<body style="margin:0; font-family:sans-serif; display:flex; flex-wrap:wrap;">
<div id="apl-filters" style="min-width:150px; padding:10px;">
  <b>Типы узлов:</b><br>{''.join(boxes)}
  <hr>
  <span style="font-size:12px; color:#666;">звёздочки — метки marks.csv;<br>
  hover на линии графа — поля ребра</span>
</div>
<div id="apl-graph-wrap" style="flex:1;">{plot_div}</div>
</body>
<script>
document.querySelectorAll('#apl-filters input[type=checkbox]').forEach(cb => {{
  cb.addEventListener('change', function() {{
    Plotly.restyle('apl-graph', {{visible: cb.checked}}, [parseInt(cb.dataset.idx, 10)]);
  }});
}});
</script>
</html>
"""
    out_path.write_text(html, encoding='utf-8')


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    graph_path = Path(sys.argv[1])
    marks_path = Path(sys.argv[2]) if len(sys.argv) > 2 else None
    if not graph_path.exists():
        print(f"FAIL: graph.json not found: {graph_path}")
        return 2
    try:
        graph = json.loads(graph_path.read_text(encoding='utf-8'))
    except Exception as e:  # noqa: BLE001
        print(f"FAIL: cannot read JSON: {e}")
        return 1
    if not isinstance(graph.get('nodes'), list) or not isinstance(graph.get('edges'), list):
        print("FAIL: graph.json has no nodes/edges lists")
        return 1

    marks = load_marks(marks_path)
    out_dir = graph_path.parent

    full_png = out_dir / 'graph_full.png'
    zoom_png = out_dir / 'graph_zoom.png'
    html_out = out_dir / 'graph.html'

    print(f"graph_viz: graph = {graph_path}")
    print(f"graph_viz: nodes {len(graph['nodes'])}, edges {len(graph['edges'])}, "
          f"marks {len(marks)}" + ('' if marks_path else ' (no marks path)'))
    meta = graph.get('meta') or {}
    if meta.get('level') in (None, 'unknown'):
        print("graph_viz: meta.level = unknown -> title fallback 'East Coast'")

    draw_png(graph, marks, full_png)
    zn = pick_zoom_node(graph)
    if zn is not None:
        draw_png(graph, marks, zoom_png, zoom_node=zn)
        print(f"graph_viz: zoom around {zn['id']} ({zn['type']}, +-{ZOOM_HALF:.0f} m)")
    else:
        print("graph_viz: no crossroads/turn nodes -> graph_zoom.png skipped")
    make_html(graph, marks, html_out)

    for p in (full_png, zoom_png, html_out):
        if p.exists():
            print(f"graph_viz: {p.name} -> {p} ({os.path.getsize(p) / 1e6:.1f} MB)")
    return 0


if __name__ == '__main__':
    sys.exit(main())
