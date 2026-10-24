# -*- coding: utf-8 -*-
"""Смоук check_csv.py: синтетический CSV с сегментами A(off)/B(on)/C(off).

Генерирует «хороший» файл (конвейер в пределах капов) и «плохой» (скачок
smoothed — нарушение rate_limit). Ожидание: хороший = все PASS,
плохой = FAIL 5г (код возврата 1).

Режимы запуска:
  * CLI (нужен путь к каталогу): python smoke_pedals_csv.py <outdir>
  * импорт из quality_gate_phase3.py: from smoke_pedals_csv import gen
Пайплайн внутри — копия stepChannel из autopilotLivePedals.lua (для
консистентности капов с ai/config/pedals.json).
"""
import math
import sys
from pathlib import Path

DT = 0.05
HEADER = [
    'time', 'pos_x', 'pos_y', 'pos_z', 'speed', 'accel',
    'steer_raw', 'steer_smoothed', 'throttle_raw', 'throttle_smoothed',
    'brake_raw', 'brake_smoothed', 'clutch_raw', 'clutch_smoothed',
    'gear', 'gear_index', 'rpm',
    'engine_temp', 'oil_temp', 'water_temp', 'engine_thermal',
    'd_steer_dt', 'd_throttle_dt', 'd_brake_dt',
]

# капы как в pedals.json (clutch-ключей нет — passthrough, api_research §15)
RATE = {'throttle': (2.0, 3.0), 'brake': (1.7, 2.5)}
TAU_EMA = {'throttle': 0.10, 'brake': 0.08}
TAU_LERP = {'throttle': 0.15, 'brake': 0.12}


def pipeline(state, target, dt):
    """Копия stepChannel из autopilotLivePedals.lua."""
    up, down = RATE[state['name']]
    rate = up if target > state['rl'] else down
    d = target - state['rl']
    state['rl'] += max(-rate * dt, min(rate * dt, d))
    state['ema'] += (state['rl'] - state['ema']) * (1 - math.exp(-dt / TAU_EMA[state['name']]))
    state['out'] += (state['ema'] - state['out']) * (1 - math.exp(-dt / TAU_LERP[state['name']]))
    return max(0.0, min(1.0, state['out']))


def gen(path, bad_rate=False, bad_clutch=False):
    states = {k: {'name': k, 'rl': 0.0, 'ema': 0.0, 'out': 0.0}
              for k in ('throttle', 'brake')}
    rows = []
    t = 0.0
    for i in range(600):  # 30 секунд
        t = i * DT
        # --- raw-профиль (эмитация AI) ---
        if t < 10:            # A: ручное вождение, модуль off
            thr_r = 0.3 + 0.2 * math.sin(t * 2)
            brk_r = 0.0
            clt_r = 0.2 if 4 <= t < 5 else 0.0  # игрок жмёт сцепление
            gear, speed, engaged = '1', 5.0 + math.sin(t), False
        elif t < 20:          # B: модуль on, ступени газа/тормоза
            thr_r = 1.0 if 11 <= t < 15 else 0.0
            brk_r = 1.0 if 17 <= t < 19 else 0.0
            clt_r = 1.0 if 16 <= t < 16.5 else 0.0  # clutch игрока: passthrough
            gear, speed, engaged = 'D', 12.0, True
        elif t < 22:          # B: нейтраль-ситуация (газ на N, стоим)
            thr_r, brk_r, clt_r = 0.4, 0.0, 0.0
            gear, speed, engaged = '0', 0.1, True
        else:                 # C: off посреди поездки
            thr_r = 0.25 + 0.1 * math.sin(t * 3)
            brk_r, clt_r = 0.0, 0.0
            gear, speed, engaged = '2', 8.0, False

        clt_s = clt_r  # clutch — passthrough: ровно raw и в engaged, и вне его
        if bad_clutch and engaged and 16 <= t < 16.5:
            clt_s = 0.25  # НАРУШЕНИЕ 5г': clutch «сглажен» ≠ raw (0.25 vs 1.0)

        if engaged:
            thr_target = 0.0 if 20 <= t < 22 else thr_r  # нейтраль: цель газа 0
            thr_s = pipeline(states['throttle'], thr_target, DT)
            brk_s = pipeline(states['brake'], brk_r, DT)
            if bad_rate and abs(t - 13.0) < DT / 2:
                thr_s = 0.0  # скачок вниз ~20 ед/с > капа 8.7 — нарушение 5г
        else:
            thr_s, brk_s = thr_r, brk_r
            for k in states.values():  # синхронизация при включении (У2)
                k['rl'] = k['ema'] = k['out'] = 0.0

        d_thr = (thr_r - (float(rows[-1][8]) if rows else thr_r)) / DT
        rows.append([
            f'{t:.3f}', '100', '200', '5', f'{speed:.3f}', '0',
            '0.1', '0.1',
            f'{max(0.0, min(1.0, thr_r)):.6f}', f'{thr_s:.6f}',
            f'{brk_r:.6f}', f'{brk_s:.6f}', f'{max(0.0, min(1.0, clt_r)):.6f}', f'{clt_s:.6f}',
            f'"{gear}"', '1', '2500', '85', '80', '85', '90',
            '0', f'{d_thr:.3f}', '0',
        ])

    with open(path, 'w', newline='', encoding='utf-8') as fh:
        # пишем вручную, как Lua-писатель: gear в кавычках без экранирования
        fh.write(','.join(HEADER) + '\r\n')
        for r in rows:
            fh.write(','.join(r) + '\r\n')
    print(f'generated: {path} ({len(rows)} rows, bad_rate={bad_rate}, bad_clutch={bad_clutch})')


if __name__ == '__main__':
    out = Path(sys.argv[1])
    gen(out / 'apl_smoke_good.csv')
    gen(out / 'apl_smoke_bad.csv', bad_rate=True)
    gen(out / 'apl_smoke_badclutch.csv', bad_clutch=True)
