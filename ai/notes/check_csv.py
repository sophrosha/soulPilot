# -*- coding: utf-8 -*-
"""Проверка CSV-лога вождения AutopilotLive (Фазы 1 + 3).

Запуск (только через venv проекта!):
    ai/venv/Scripts/python.exe ai/notes/check_csv.py <путь/к/файлу.csv>

Что проверяет (по ТЗ Фазы 1 и ai/notes/phase1_csv_schema.md):
  1. Все 24 колонки на месте, порядок как в схеме.
  2. Нет NaN/пустот там, где не должно (кроме gear — строка).
  2b. gear записан в КАВЫЧКАХ в тексте CSV (контракт «Lua пишет строку»,
      phase1_csv_schema.md) + значения gear из допустимого множества
      (иначе WARN — не FAIL; множество по vehicleController.getGearName).
  3. Дискретизация ~20 Гц: медианный dt между строками ≈ 0.05 c.
  4. Производные d_*/dt консистентны: |d_steer_dt| согласовано
     с численной производной steer_raw по времени.
  5. РЕЖИМ ОПРЕДЕЛЯЕТСЯ ПО ДАННЫМ (Фаза 3):
     - pedals off (все *_smoothed == *_raw): 5а — равенство по всем каналам
       (сценарии A/C теста 3.6: модуль не вмешивается / мгновенный возврат);
     - pedals on: 5б — строки ВНЕ работы модуля = точные копии raw;
       5в — *_smoothed в [0,1]; 5г — кап скорости изменения из pedals.json
       (rate×1.2, переходы между сегментами исключены); 5д — конвейер
       реально отличается от raw.
  6. Длительность × 20 ≈ число строк.
  7. Скорость/pos читаются, gear — строка, rpm — число.

Выход: список PASS/FAIL, код возврата 0 если всё ок, 1 если есть FAIL.
"""
import json
import sys
from pathlib import Path

import pandas as pd

# Windows-консоль по умолчанию cp1252/cp866 — кириллица падает с
# UnicodeEncodeError. Принудительно переключаем вывод в UTF-8.
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

# Точная схема колонок (phase1_csv_schema.md)
EXPECTED_COLUMNS = [
    'time', 'pos_x', 'pos_y', 'pos_z', 'speed', 'accel',
    'steer_raw', 'steer_smoothed', 'throttle_raw', 'throttle_smoothed',
    'brake_raw', 'brake_smoothed', 'clutch_raw', 'clutch_smoothed',
    'gear', 'gear_index', 'rpm',
    'engine_temp', 'oil_temp', 'water_temp', 'engine_thermal',
    'd_steer_dt', 'd_throttle_dt', 'd_brake_dt',
]

SMOOTHED_PAIRS = [
    ('steer_raw', 'steer_smoothed'),
    ('throttle_raw', 'throttle_smoothed'),
    ('brake_raw', 'brake_smoothed'),
    ('clutch_raw', 'clutch_smoothed'),
]

# Колонки, которые в Фазе 1 обязаны быть нулями/пустыми, если данных нет,
# но НЕ NaN: числовые, кроме gear
NUMERIC_EXCEPT_GEAR = [c for c in EXPECTED_COLUMNS if c != 'gear']

GEAR_IDX = EXPECTED_COLUMNS.index('gear')  # 14-я колонка (с 0)

# Допустимые значения gear (источник: vehicleController/shiftLogic getGearName):
#   manualGearbox/sequentialGearbox: gearIndex — ЧИСЛО (R = -1, N = 0, 1..N);
#   automaticGearbox/cvt/electricMotor: automaticHandling.mode из jbeam
#     automaticModes ("PRND" / "PRNDS21M"), плюс префиксы "M"+idx и "S"+idx;
#   dctGearbox: mode или префикс+индекс при включённой передаче;
#   dummy: "" (пустая строка).
# Всё, что вне этого множества, — WARN (не FAIL): новые машины не должны
# ломать прогон теста.
ALLOWED_GEAR = (
    {str(i) for i in range(-1, 11)}       # -1..10 как строки: '0', '1', ..., '-1'
    | {'', 'P', 'R', 'N', 'D', 'S', 'L', '2', '1'}
    | {f'M{i}' for i in range(1, 11)}      # M1..M10
    | {f'S{i}' for i in range(1, 11)}      # S1..S10
)


# === Фаза 3: капы rate_limit из ai/config/pedals.json (источник истины) ===
# Кап скорости изменения сглаженного: |Δsmoothed|/Δt ≤ rate (в секундах).
# Тонкость арбитража: thr_out = thr * cut(brake_smoothed) — при быстром
# торможении срез газа добавляет к скорости изменения throttle сверх
# throttle_fall: dcut/dt ≤ brake_rise/(brake_full−brake_start) — учитываем.
def load_rate_caps() -> dict:
    caps = {'throttle': 5.0 + 6.25, 'brake': 2.5, 'clutch': 5.0,
            'arbitration': 6.25, 'src': 'дефолты чекера'}
    conf_path = Path(__file__).resolve().parent.parent / 'config' / 'pedals.json'
    try:
        with conf_path.open(encoding='utf-8') as fh:
            conf = json.load(fh)
        rl = conf['rate_limit']
        arb = rl['brake_rise'] / max(
            conf['arbitration']['brake_full'] - conf['arbitration']['brake_start'], 1e-6)
        caps = {
            'throttle': max(rl['throttle_rise'], rl['throttle_fall']) + arb,
            'brake': max(rl['brake_rise'], rl['brake_fall']),
            'clutch': max(rl['clutch_rise'], rl['clutch_fall']),
            'arbitration': arb,
            'src': str(conf_path),
        }
    except Exception as e:  # noqa: BLE001
        caps['src'] = f'дефолты чекера (pedals.json не прочитан: {e})'
    return caps


def main() -> int:
    if len(sys.argv) < 2:
        print(__doc__)
        return 2
    path = Path(sys.argv[1])
    if not path.exists():
        print(f"FAIL: файл не найден: {path}")
        return 2

    results: list[tuple[bool, str]] = []

    def check(ok: bool, msg: str) -> None:
        results.append((bool(ok), msg))

    # --- чтение ---
    try:
        df = pd.read_csv(path)
    except Exception as e:  # noqa: BLE001
        print(f"FAIL: pandas не смог прочитать CSV: {e}")
        return 1

    # 1. колонки
    check(list(df.columns) == EXPECTED_COLUMNS,
          f"колонки (ожидалось {len(EXPECTED_COLUMNS)}, получено {len(df.columns)})")
    if list(df.columns) != EXPECTED_COLUMNS:
        missing = set(EXPECTED_COLUMNS) - set(df.columns)
        extra = set(df.columns) - set(EXPECTED_COLUMNS)
        if missing:
            print(f"  отсутствуют: {sorted(missing)}")
        if extra:
            print(f"  лишние: {sorted(extra)}")

    # 2. NaN
    nan_cols = {c: int(df[c].isna().sum()) for c in df.columns if df[c].isna().any()}
    check(not nan_cols, f"отсутствие NaN (найдены NaN: {nan_cols or 'нет'})")

    # 2b. gear — строка: Lua пишет значение в кавычках (schema У1).
    # pandas НЕ отличает Lua-строку "1" от числа 1 (dtype выводится по
    # содержимому, кавычки в CSV он игнорирует) — поэтому проверяем кавычки
    # напрямую в тексте: наш писатель всегда ставит их (autopilotLive.lua,
    # строка '"' .. gear .. '"').
    # Примечание: строка CSV не содержит запятых внутри полей (только gear
    # закавычен, а он не бывает с запятой) — split(',') безопасен.
    gear_quoted, gear_unquoted = 0, 0
    gear_values: set[str] = set()
    gear_note = ''
    try:
        with path.open('r', encoding='utf-8', newline='') as fh:
            fh.readline()  # заголовок
            for line in fh:
                line = line.rstrip('\r\n')
                if not line:
                    continue
                parts = line.split(',')
                if len(parts) != len(EXPECTED_COLUMNS):
                    continue  # чужая структура — не гадаем
                g = parts[GEAR_IDX]
                if len(g) >= 2 and g.startswith('"') and g.endswith('"'):
                    gear_quoted += 1
                    gear_values.add(g[1:-1])
                else:
                    gear_unquoted += 1
                    gear_values.add(g)
    except Exception as e:  # noqa: BLE001
        gear_quoted, gear_unquoted = 0, 0
        gear_note = f"[WARN] не смог разобрать текст CSV для проверки gear: {e}"
    check(gear_quoted > 0 and gear_unquoted == 0,
          f"gear в кавычках во всех строках "
          f"(с кавычками: {gear_quoted}, без: {gear_unquoted})")

    # 2c. gear из допустимого множества — иначе WARN (не FAIL), не чек
    # (при ошибке разбора gear_note уже установлен в except)
    if gear_quoted + gear_unquoted > 0:
        outside = sorted(v for v in gear_values if v not in ALLOWED_GEAR)
        if outside:
            gear_note = (f"[WARN] gear вне допустимого множества {sorted(outside)} "
                         f"(встречено: {sorted(gear_values)})")
        else:
            gear_note = (f"[info] gear все из допустимого множества "
                         f"(встречено: {sorted(gear_values)})")

    # 3. дискретизация ~20 Гц
    if len(df) >= 3:
        dts = df['time'].diff().dropna()
        med = float(dts.median())
        check(abs(med - 0.05) <= 0.02,
              f"медианный dt = {med:.4f} c (ожидание 0.05 ± 0.02)")
        # не должно быть гигантских дыр (кроме первой строки)
        max_dt = float(dts.max())
        check(max_dt < 1.0, f"максимальный dt = {max_dt:.4f} c (< 1.0)")
    else:
        check(False, f"слишком мало строк для проверки dt: {len(df)}")

    # 6. длительность × 20 ≈ строки
    if len(df) >= 2:
        dur = float(df['time'].iloc[-1] - df['time'].iloc[0])
        expected = dur * 20
        ratio = len(df) / expected if expected > 0 else 0
        check(0.8 <= ratio <= 1.25,
              f"строк = {len(df)}, длительность = {dur:.1f} c, ожидание ~{expected:.0f} (ratio {ratio:.2f})")

    # === 5. Фаза 3: режим определяется ПО ДАННЫМ ===
    # engaged = модуль реально писал Override в этот кадр. Определяем по
    # расхождению throttle/brake (clutch не участвует — ленивая запись).
    engaged = ((df['throttle_smoothed'] - df['throttle_raw']).abs() > 1e-9) | \
              ((df['brake_smoothed'] - df['brake_raw']).abs() > 1e-9)
    n_engaged = int(engaged.sum())
    caps = load_rate_caps()

    if n_engaged == 0:
        # 5а: pedals off — все пары обязаны быть копиями raw (сценарии A/C)
        for raw, sm in SMOOTHED_PAIRS:
            if raw in df.columns and sm in df.columns:
                max_diff = (df[raw] - df[sm]).abs().max()
                check(float(max_diff) < 1e-9,
                      f"5а {sm} == {raw} (макс. расхождение {max_diff:.3g}; pedals off)")
            else:
                check(False, f"нет колонок {raw}/{sm}")
        print("  [info] режим: pedals OFF (все *_smoothed == *_raw)")
    else:
        # 5б: строки ВНЕ работы модуля = точные копии raw (сценарии A/C)
        idle = ~engaged
        idle_rows = int(idle.sum())
        if idle_rows > 0:
            worst = 0.0
            for raw, sm in SMOOTHED_PAIRS:
                if raw in df.columns and sm in df.columns:
                    worst = max(worst, float((df.loc[idle, raw] - df.loc[idle, sm]).abs().max()))
            check(worst < 1e-9,
                  f"5б строки вне engaged = raw (строк: {idle_rows}, макс. расхождение {worst:.3g})")
        else:
            print("  [info] 5б пропущено: весь файл в режиме engaged")

        # 5в: диапазон [0,1] у сглаженных
        for sm in ('throttle_smoothed', 'brake_smoothed', 'clutch_smoothed'):
            lo, hi = float(df[sm].min()), float(df[sm].max())
            check(-0.001 <= lo and hi <= 1.001,
                  f"5в {sm} в [0,1] (min {lo:.3g}, max {hi:.3g})")

        # 5г: кап скорости изменения ВНУТРИ непрерывных сегментов engaged.
        # Границы сегментов ИСКЛЮЧЕНЫ: включение = синхронизация к raw (У2),
        # выключение = шаг к raw — это дизайн (nil/копия raw), не rate-limit.
        prev_engaged = engaged.shift(1).fillna(False).astype(bool)
        same_run = engaged & prev_engaged
        d_t_all = df['time'].diff()
        for raw, sm, cap in (('throttle_raw', 'throttle_smoothed', caps['throttle']),
                             ('brake_raw', 'brake_smoothed', caps['brake']),
                             ('clutch_raw', 'clutch_smoothed', caps['clutch'])):
            valid = same_run & (d_t_all > 1e-6)
            if valid.any():
                rates = (df[sm].diff()[valid].abs() / d_t_all[valid])
                r_max, n_viol = float(rates.max()), int((rates > cap * 1.2).sum())
            else:
                r_max, n_viol = 0.0, 0
            check(n_viol == 0,
                  f"5г {sm}: кап {cap:.2f} ед/с ×1.2 (нарушений {n_viol}, макс {r_max:.2f})")

        # 5д: конвейер реально отличается от raw (иначе модуль не работал)
        devs = []
        for c_r, c_s in SMOOTHED_PAIRS:
            if c_r != 'steer_raw' and c_r in df.columns and c_s in df.columns:
                devs.append(float((df.loc[engaged, c_s] - df.loc[engaged, c_r]).abs().max()))
        max_dev = max(devs) if devs else 0.0
        check(max_dev > 1e-9,
              f"5д конвейер отличается от raw (макс. расхождение {max_dev:.3g})")

        # INFO: сегменты работы и расхождения (для отчёта теста 3.6)
        switches = int((engaged != engaged.shift()).sum()) - 1  # без перехода NaN→bool
        print(f"  [info] режим: pedals ON — engaged строк {n_engaged}/{len(df)}, "
              f"переходов вкл/выкл: {switches}")
        print(f"  [info] капы (из {caps['src']}): thr {caps['throttle']:.2f}, "
              f"brk {caps['brake']:.2f}, clt {caps['clutch']:.2f} ед/с")
        for c_r, c_s in (('throttle_raw', 'throttle_smoothed'),
                         ('brake_raw', 'brake_smoothed')):
            dev = (df.loc[engaged, c_s] - df.loc[engaged, c_r]).abs()
            print(f"  [info] |{c_s} - {c_r}| на engaged: среднее {float(dev.mean()):.4f}, "
                  f"макс {float(dev.max()):.4f}")

        # INFO: строки нейтрали (gear N|0 + газ > 0.05 + почти стоим)
        gear_neutral = df['gear'].astype(str).isin(['N', '0'])
        neutral_rows = gear_neutral & (df['throttle_raw'] > 0.05) & (df['speed'] < 0.5)
        n_nr = int(neutral_rows.sum())
        if n_nr > 0:
            print(f"  [info] нейтраль: строк {n_nr}, max throttle_smoothed там = "
                  f"{float(df.loc[neutral_rows, 'throttle_smoothed'].max()):.3f} "
                  f"(ожидание ~0 после ~0.5 с стабилизации)")
        else:
            print("  [info] нейтраль: строк с газом на N|0 нет")

    # 4. производные
    if len(df) >= 3 and 'd_steer_dt' in df.columns:
        num_dsteer = df['steer_raw'].diff() / df['time'].diff()
        # допускаем расхождение: наши производные между 20 Гц-выборками,
        # pandas считает так же по строкам → должны почти совпасть
        common = num_dsteer.abs().max()
        ours = df['d_steer_dt'].abs().max()
        # первая строка у нас 0, у pandas NaN — ок
        check(abs(float(common) - float(ours)) < 0.5 * max(float(common), 1.0),
              f"d_steer_dt согласован с численной производной (наш max {ours:.4g}, pandas max {common:.4g})")

    # 7. разумные диапазоны
    if 'speed' in df.columns:
        check(float(df['speed'].min()) >= 0, f"speed >= 0 (min {float(df['speed'].min()):.3g})")
    for c in ['throttle_raw', 'brake_raw', 'clutch_raw']:
        if c in df.columns:
            lo, hi = float(df[c].min()), float(df[c].max())
            check(-0.01 <= lo and hi <= 1.01, f"{c} в [0,1] (min {lo:.3g}, max {hi:.3g})")
    if 'steer_raw' in df.columns:
        lo, hi = float(df['steer_raw'].min()), float(df['steer_raw'].max())
        check(-1.01 <= lo and hi <= 1.01, f"steer_raw в [-1,1] (min {lo:.3g}, max {hi:.3g})")
    if 'rpm' in df.columns:
        check(float(df['rpm'].min()) >= 0, f"rpm >= 0 (min {float(df['rpm'].min()):.3g})")

    # --- отчёт ---
    print(f"Файл: {path}")
    print(f"Строк: {len(df)}, колонок: {len(df.columns)}")
    print()
    fails = 0
    for ok, msg in results:
        mark = 'PASS' if ok else 'FAIL'
        if not ok:
            fails += 1
        print(f"  [{mark}] {msg}")
    if gear_note:
        print(f"  {gear_note}")
    print()
    if fails == 0:
        print(f"ИТОГ: все {len(results)} проверок пройдены.")
        return 0
    print(f"ИТОГ: {fails} из {len(results)} проверок НЕ пройдены.")
    return 1


if __name__ == '__main__':
    sys.exit(main())
