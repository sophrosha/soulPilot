# -*- coding: utf-8 -*-
"""phase3_csv_analysis.py — разбор теста 3.6 (Фаза 3) по CSV для тюнинга.

Импортирует quality_framework (единый фреймворк качества проекта): его
run_checklist используется для чек-листа «интерпретируемость данных» (честные
FAIL при непригодных данных, а не красивые цифры из воздуха).

Запуск (только venv проекта!):
    ai/venv/Scripts/python.exe ai/notes/phase3_csv_analysis.py <путь/к/файлу.csv>

Что выводит (числовая база для правок pedals.json, Фаза 3.7):
  1. Сегменты engaged (вкл/выкл модуля) по времени.
  2. События торможения: задержки raw→smoothed на порогах 0.05/0.3/0.5,
     пики d(smoothed)/dt, была ли остановка.
  3. «Позднее торможение» (критерий пользователя): brake_raw > 0.5 при
     speed < 10 м/с — когда, с какой скорости, сколько до полной.
  4. «Резкое торможение»: d_brk_sm/dt > 60% капа (1.5 ед/с).
  5. Кап газа: где |thr_raw−thr_sm| > 0.15 (время от включения, скорость).
  6. Дёрганья газа: пики d_thr_sm/dt в engaged.
  7. Контроль predictive (добавка к raw) и clutch (не вылез ли в engaged).
"""
import sys
from pathlib import Path

import pandas as pd

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

from quality_framework import run_checklist  # noqa: E402

BRAKE_CAP = 2.5          # brake_rise/fall из pedals.json (ед/с)
SHARP_THRESHOLD = 1.5    # «резко» = 60% капа
JERK_THRESHOLD = 2.0     # дёрганье газа: пики d_thr_sm/dt (ед/с)
CAP_GAP = 0.15           # «кап работает»: |raw-sm| > 0.15


def segs(mask: pd.Series) -> pd.Series:
    """Непрерывные runs маски -> Series с id сегмента (0 = вне)."""
    return (mask != mask.shift()).cumsum() * mask


def fmt(x: float, nd: int = 2) -> str:
    return f'{x:.{nd}f}'


def main(path: str) -> int:
    df = pd.read_csv(path, dtype={'gear': str})
    df['gear'] = df['gear'].str.strip('"')
    fails: list[str] = []

    def note(ok: bool, msg: str) -> None:
        print(f'  [{"ok" if ok else "PROBLEM"}] {msg}')
        if not ok:
            fails.append(msg)

    # engaged — модуль реально писал Override (по расхождению, как в чекере)
    eng = ((df.throttle_smoothed - df.throttle_raw).abs() > 1e-9) | \
          ((df.brake_smoothed - df.brake_raw).abs() > 1e-9)
    df['seg'] = segs(eng)
    work = df[eng].copy()
    # производные — только внутри сегмента (границы исключены)
    dt = work.time.diff()
    same = (work.seg == work.seg.shift()) & (dt > 1e-6)
    work['d_thr'] = (work.throttle_smoothed.diff() / dt).where(same)
    work['d_brk'] = (work.brake_smoothed.diff() / dt).where(same)

    n_seg = int(work.seg.max()) if len(work) else 0

    # --- чек-лист интерпретируемости (quality_framework.run_checklist) ---
    def validator(item: str):
        if 'сегменты' in item:
            return (n_seg >= 2, f'найдено сегментов engaged: {n_seg}')
        if 'доля engaged' in item:
            share = len(work) / len(df)
            return (share > 0.3, f'доля engaged: {share:.0%}')
        if 'clutch' in item:
            cm = float(work.clutch_raw.max()) if len(work) else 0.0
            return (cm < 1e-6, f'max clutch_raw в engaged = {cm:.3f}')
        return None

    res = run_checklist('интерпретируемость данных', [
        'сегменты engaged найдены (>= 2: вкл/выкл)',
        'доля engaged > 30% (есть что анализировать)',
        'clutch_raw в engaged == 0 (AI не шлёт сцепление — ожидание §7)',
    ], validator)
    print(res.report())
    fails.extend(m for ok, m in res.items if not ok)

    print(f'\n=== 1. Сегменты engaged (файл: {Path(path).name}) ===')
    for sid, g in work.groupby('seg'):
        t0, t1 = float(g.time.iloc[0]), float(g.time.iloc[-1])
        print(f'  сегмент {sid}: {t0:.1f}..{t1:.1f} с (длит. {t1 - t0:.1f} с, строк {len(g)})')

    # --- 2. События торможения ---
    print('\n=== 2. События торможения (brake_raw > 0.05, engaged) ===')
    print('  #   t_start  t_end   raw_max  sm_max  spd_start  задерж.05  задерж.30  задерж.50  d_sm_max  остановка')
    brk_on = work.brake_raw > 0.05
    events = []
    for sid, g in work[brk_on].groupby(segs(brk_on)[brk_on]):
        t0, t1 = float(g.time.iloc[0]), float(g.time.iloc[-1])
        spd0 = float(g.speed.iloc[0])
        raw_max, sm_max = float(g.brake_raw.max()), float(g.brake_smoothed.max())
        delays = {}
        for th in (0.05, 0.3, 0.5):
            r = g[g.brake_raw > th]
            delays[th] = (float(g[g.brake_smoothed > th].time.iloc[0]) - float(r.time.iloc[0])) \
                if len(r) and len(g[g.brake_smoothed > th]) else float('nan')
        dmax = float(g.d_brk.max())
        # остановка: speed < 0.5 в пределах 3 с после конца торможения
        tail = work[(work.time >= t1) & (work.time <= t1 + 3)]
        stopped = bool(len(tail) and (tail.speed < 0.5).any()) or bool((g.speed < 0.5).any())
        events.append(dict(t0=t0, t1=t1, raw_max=raw_max, sm_max=sm_max, spd0=spd0,
                           d05=delays[0.05], d30=delays[0.3], d50=delays[0.5],
                           dmax=dmax, stopped=stopped, g=g))
        print(f'  {len(events):<3} {t0:8.1f} {t1:7.1f} {raw_max:8.2f} {sm_max:7.2f} {spd0:10.1f}'
              f' {delays[0.05]:9.3f} {delays[0.3]:9.3f} {delays[0.5]:9.3f} {dmax:9.2f}'
              f'  {"да" if stopped else "нет"}')

    # --- 3. Позднее торможение ---
    print('\n=== 3. «Позднее торможение»: brake_raw > 0.5 при speed < 10 м/с ===')
    late = work[(work.brake_raw > 0.5) & (work.speed < 10)]
    if len(late):
        # агрегация: непрерывные серии late-строк (гэп < 1 с)
        gap = late.time.diff() > 1.0
        for i, (_, g) in enumerate(late.groupby(gap.cumsum()), 1):
            t_first = float(g.time.iloc[0])
            spd = float(g.speed.iloc[0])
            sm_first = float(g.brake_smoothed.iloc[0])
            # время от этого момента до speed < 0.5
            after = work[work.time >= t_first]
            to_stop = float(after[after.speed < 0.5].time.iloc[0] - t_first) \
                if (after.speed < 0.5).any() else float('nan')
            print(f'  серия {i}: t={t_first:.1f} с, speed={spd:.1f} м/с, '
                  f'raw={float(g.brake_raw.max()):.2f}, sm_при_входе={sm_first:.2f}, '
                  f'до полной остановки ~{to_stop:.1f} с, строк {len(g)}')

    # --- 4. Резкое торможение ---
    print(f'\n=== 4. «Резкое торможение»: d(brake_sm)/dt > {SHARP_THRESHOLD} ед/с ===')
    sharp = work[work.d_brk > SHARP_THRESHOLD]
    if len(sharp):
        for t, row in sharp.iterrows():
            print(f'  t={row.time:.2f} с: d_brk={row.d_brk:.2f} ед/с, speed={row.speed:.1f} м/с, '
                  f'raw={row.brake_raw:.2f} sm={row.brake_smoothed:.2f}')
    else:
        print('  нет строк')
    print(f'  (для справки: кап brake_rise={BRAKE_CAP} ед/с, максимум d_brk за тест = '
          f'{fmt(float(work.d_brk.max()))} ед/с)')

    # --- 5. Кап газа ---
    print(f'\n=== 5. Кап/срез газа: |thr_raw - thr_sm| > {CAP_GAP} (engaged) ===')
    cap_rows = work[(work.throttle_raw - work.throttle_smoothed).abs() > CAP_GAP]
    if len(cap_rows):
        # агрегация по сегментам: время от начала сегмента
        for sid, g in cap_rows.groupby('seg'):
            seg_t0 = float(work[work.seg == sid].time.iloc[0])
            t_rel = g.time - seg_t0
            print(f'  сегмент {sid}: строк {len(g)}, первое {t_rel.iloc[0]:.2f} с от вкл., '
                  f'последнее {t_rel.iloc[-1]:.2f} с, скорость {g.speed.min():.1f}..{g.speed.max():.1f} м/с, '
                  f'max (raw-sm) = {float((g.throttle_raw - g.throttle_smoothed).max()):.2f}')
    else:
        print('  нет строк')

    # --- 6. Дёрганья газа ---
    print(f'\n=== 6. Дёрганья газа: |d(thr_sm)/dt| > {JERK_THRESHOLD} ед/с (engaged) ===')
    jerk = work[work.d_thr.abs() > JERK_THRESHOLD]
    if len(jerk):
        for _, row in jerk.iterrows():
            print(f'  t={row.time:.2f} с: d_thr={row.d_thr:.2f} ед/с, speed={row.speed:.1f} м/с, '
                  f'raw={row.throttle_raw:.2f} sm={row.throttle_smoothed:.2f}')
    else:
        print('  нет строк')
    print(f'  (справка: максимум |d_thr| за тест = {fmt(float(work.d_thr.abs().max()))} ед/с, '
          f'медиана = {fmt(float(work.d_thr.abs().median()), 3)} ед/с)')

    # --- 7. predictive и clutch ---
    print('\n=== 7. Контроль predictive / clutch ===')
    add = work.brake_smoothed - work.brake_raw
    pred_rows = work[add > 0.05]
    print(f'  predictive: строк с добавкой к raw > 0.05: {len(pred_rows)}'
          + (f', макс. добавка {float(add.max()):.2f}, t {float(pred_rows.time.iloc[0]):.1f}..{float(pred_rows.time.iloc[-1]):.1f} с'
             if len(pred_rows) else ''))
    print(f'  clutch: max raw в engaged = {float(work.clutch_raw.max()):.3f}, '
          f'max smoothed = {float(work.clutch_smoothed.max()):.3f}')

    # --- сводка для тюнинга ---
    brk_delays = [e['d05'] for e in events if not pd.isna(e['d05'])]
    print('\n=== СВОДКА (для тюнинга 3.7) ===')
    if brk_delays:
        print(f'  задержка raw→sm на пороге 0.05: средняя {sum(brk_delays) / len(brk_delays):.3f} с '
              f'(min {min(brk_delays):.3f}, max {max(brk_delays):.3f})')
    print(f'  событий торможения: {len(events)}, из них до остановки: {sum(1 for e in events if e["stopped"])}')
    print(f'  «поздних» серий (raw>0.5 при <10 м/с): {len(late.groupby((late.time.diff() > 1.0).cumsum())) if len(late) else 0}')
    print(f'  «резких» строк (>{SHARP_THRESHOLD} ед/с): {len(sharp)}, «дёрганых» газа: {len(jerk)}')

    if fails:
        print(f'\nИТОГ: проблемы интерпретируемости: {fails}')
        return 1
    print('\nИТОГ: данные интерпретируемы, цифры выше — основа для правок pedals.json.')
    return 0


if __name__ == '__main__':
    if len(sys.argv) != 2:
        print('Запуск: python ai/notes/phase3_csv_analysis.py <путь/к/файлу.csv>')
        sys.exit(2)
    sys.exit(main(sys.argv[1]))
