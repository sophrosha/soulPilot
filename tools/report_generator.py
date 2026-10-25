# -*- coding: utf-8 -*-
"""AutopilotLive — генератор глубокого отчёта по CSV (Фаза 8.1, 24.10).

В отличие от check_csv.py (быстрый гейт PASS/FAIL), даёт инженерную картину:
статистика каналов, использование лимитов, скачки, залипания, недоход руля.

Запуск (venv):
  ai\\venv\\Scripts\\python.exe ai\\notes\\report_generator.py <csv> [--md out.md] [--json out.json]

Колонки ищутся по суффиксам: <ch>_raw / <ch>_smoothed (throttle, brake, steer...).
 Выход: Markdown в stdout (+файл), опционально JSON. Код возврата 1 при FAIL.
"""
import argparse
import json
import os
import sys

import numpy as np
import pandas as pd

CONFIG_DIR = os.path.join(os.path.dirname(__file__), "..", "src", "config")

CAP_DEFAULT = {
    "throttle_rise": 2.0, "throttle_fall": 3.0,
    "brake_rise": 1.7, "brake_fall": 2.5,
    "steer_rise": 6.0, "steer_fall": 7.0,
}


def load_caps():
    caps = dict(CAP_DEFAULT)
    for fname, grp in (("pedals.json", "rate_limit"), ("wheel.json", "rate_limit")):
        path = os.path.join(CONFIG_DIR, fname)
        try:
            with open(path, encoding="utf-8") as f:
                data = json.load(f)
            for k, v in (data.get(grp) or {}).items():
                if isinstance(v, (int, float)) and k in caps:
                    caps[k] = float(v)
        except OSError:
            pass
    return caps


def stats_series(s: pd.Series):
    v = pd.to_numeric(s, errors="coerce").dropna().to_numpy()
    if v.size == 0:
        return None
    q = np.percentile(v, [50, 95, 99])
    return {
        "n": int(v.size), "min": float(v.min()), "max": float(v.max()),
        "mean": float(v.mean()), "std": float(v.std()),
        "p50": float(q[0]), "p95": float(q[1]), "p99": float(q[2]),
        "zeros_pct": float(100.0 * np.mean(np.abs(v) < 1e-9)),
    }


def lag_seconds(sm: pd.Series, raw: pd.Series, dt_med: float, max_lag_frames=40):
    """Лаг sm относительно raw по максимуму нормированной взаимной корреляции."""
    a = pd.to_numeric(raw, errors="coerce").fillna(0).to_numpy()
    b = pd.to_numeric(sm, errors="coerce").fillna(0).to_numpy()
    n = min(len(a), len(b))
    if n < 20:
        return None
    a, b = a[:n] - a[:n].mean(), b[:n] - b[:n].mean()
    denom = (np.linalg.norm(a) * np.linalg.norm(b)) or 1.0
    best, best_lag = -2.0, 0
    for lag in range(0, min(max_lag_frames, n // 3)):
        c = float(np.dot(a[: n - lag], b[lag:]) / denom)
        if c > best:
            best, best_lag = c, lag
    return best_lag * dt_med, best


def find_events(mask: np.ndarray, t: np.ndarray, min_gap_s=1.0):
    """Склеиваем True-маску в события: (t_start, t_end, длительность)."""
    events, start, last = [], None, None
    for i, flag in enumerate(mask):
        if flag:
            if start is None:
                start = t[i]
            last = t[i]
        elif start is not None:
            events.append((start, last, last - start))
            start = last = None
    if start is not None:
        events.append((start, last, last - start))
    return events


def longest_frozen(sm: pd.Series, t: np.ndarray, mask=None, eps=1e-9):
    """Самая длинная «заморозка» канала (только участки engaged, если mask дан)."""
    v = pd.to_numeric(sm, errors="coerce").to_numpy()
    m = mask.to_numpy() if mask is not None else np.ones(len(v), dtype=bool)
    best, cur, start = 0.0, 0.0, 0.0
    for i in range(1, len(v)):
        same = (np.isfinite(v[i]) and np.isfinite(v[i - 1])
                and abs(v[i] - v[i - 1]) < eps and m[i] and m[i - 1])
        if same:
            if cur == 0.0:
                start = t[i - 1]
            cur = t[i] - start
            best = max(best, cur)
        else:
            cur = 0.0
    return best


def build_report(path, df, caps):
    out = {"file": os.path.basename(path), "checks": [], "sections": {}}
    dur = None
    if "t" in df.columns:
        t = pd.to_numeric(df["t"], errors="coerce").to_numpy()
    else:
        t = np.arange(len(df), dtype=float) * 0.05
    if len(t) > 1:
        dur = float(t[-1] - t[0])
    dt_med = float(np.median(np.diff(t))) if len(t) > 1 else 0.05
    out["rows"] = int(len(df))
    out["duration_s"] = dur
    out["dt_median_s"] = dt_med
    out["sections"]["meta"] = [f"строк: {len(df)}", f"длительность: {dur:.1f} с" if dur else "",
                               f"dt медиана: {dt_med*1000:.1f} мс", f"колонок: {len(df.columns)}"]

    # 1. Статистика каналов
    ch_rows = []
    for col in df.columns:
        if col.endswith(("_raw", "_smoothed")):
            st = stats_series(df[col])
            if st:
                ch_rows.append((col, st))
    out["sections"]["channels"] = ch_rows

    # 2. Режим engaged
    def engaged_mask(ch):
        if f"{ch}_raw" not in df.columns or f"{ch}_smoothed" not in df.columns:
            return None
        r = pd.to_numeric(df[f"{ch}_raw"], errors="coerce")
        s = pd.to_numeric(df[f"{ch}_smoothed"], errors="coerce")
        return (s - r).abs() > 1e-9

    modes = {}
    for ch in ("throttle", "brake", "steer"):
        m = engaged_mask(ch)
        if m is not None:
            modes[ch] = float(100.0 * m.mean())
    out["sections"]["engaged_pct"] = modes

    # 3. Качество сглаживания и лимиты
    smooth_rows = []
    for ch in ("throttle", "brake", "steer"):
        if f"{ch}_raw" not in df.columns or f"{ch}_smoothed" not in df.columns:
            continue
        m = engaged_mask(ch)
        if m is None or not m.any():
            continue
        r = pd.to_numeric(df[f"{ch}_raw"], errors="coerce")
        s = pd.to_numeric(df[f"{ch}_smoothed"], errors="coerce")
        dev = (s - r)[m].abs()
        lag = lag_seconds(s[m], r[m], dt_med)
        sm_vals = s[m].to_numpy()
        tm_vals = t[m.to_numpy()]
        if len(sm_vals) > 2:
            dts = np.diff(tm_vals)
            dts[dts <= 1e-6] = dt_med
            dsm = np.abs(np.diff(sm_vals)) / dts
        else:
            dsm = np.array([0.0])
        rise = caps.get(f"{ch}_rise", CAP_DEFAULT.get(f"{ch}_rise", 0))
        fall = caps.get(f"{ch}_fall", CAP_DEFAULT.get(f"{ch}_fall", 0))
        cap = max(rise, fall) or 1.0
        at_cap = float(100.0 * np.mean(dsm >= 0.9 * cap))
        smooth_rows.append({
            "channel": ch, "engaged_pct": float(100.0 * m.mean()),
            "mean_dev": float(dev.mean()), "max_dev": float(dev.max()),
            "lag_s": lag[0] if lag else None, "corr": lag[1] if lag else None,
            "max_rate": float(dsm.max()), "cap": cap, "pct_at_cap": at_cap,
        })
        # лимит задран? (много кадров на капе — кап определяет поведение)
        ok = at_cap < 80.0
        out["checks"].append((f"лимит {ch}", ok,
                              f"кадров на капе {at_cap:.1f}% (кап {cap:.1f}/с, "
                              f"max {dsm.max():.1f}/с)"))
    out["sections"]["smoothing"] = smooth_rows

    # 4. Скачки: |d(sm)/dt| > 1.2*cap
    jumps = []
    for row in smooth_rows:
        ch = row["channel"]
        m = engaged_mask(ch)
        s = pd.to_numeric(df[f"{ch}_smoothed"], errors="coerce")
        if m is None or not m.any():
            continue
        idx = np.where(m.to_numpy())[0]
        v = s.to_numpy()
        thr = 1.2 * (row["cap"] or 1.0)
        for i in idx[1:]:
            if i <= 0 or not np.isfinite(v[i]) or not np.isfinite(v[i - 1]):
                continue
            # dt конкретной пары строк (не медиана!) — иначе алиасинг CSV
            # (кадр 40-60 мс при подписанных 50 мс) даёт ложные «скачки».
            dti = t[i] - t[i - 1]
            if not np.isfinite(dti) or dti <= 1e-6:
                dti = dt_med
            rate = abs(v[i] - v[i - 1]) / dti
            if rate > thr:
                jumps.append((ch, float(t[i]), rate))
    out["sections"]["jumps"] = jumps[:50]
    out["checks"].append(("скачки", len(jumps) == 0,
                          f"событий выше 1.2·кап: {len(jumps)}"
                          + (f" (макс {max(j[2] for j in jumps):.1f}/с)" if jumps else "")))

    # 5. Аномалии значений
    anomalies = []
    for ch in ("throttle", "brake", "steer"):
        col = f"{ch}_smoothed"
        if col not in df.columns:
            continue
        v = pd.to_numeric(df[col], errors="coerce")
        lo, hi = (-1.0, 1.0) if ch == "steer" else (0.0, 1.0)
        bad = int(((v < lo - 1e-6) | (v > hi + 1e-6)).sum()) + int(v.isna().sum())
        if bad:
            anomalies.append(f"{ch}: вне [{lo},{hi}]/NaN — {bad} строк")
        m = engaged_mask(ch)
        if m is not None and m.mean() >= 0.05:
            frozen = longest_frozen(v, t, mask=m)
            if frozen > 5.0 and ch != "brake":
                anomalies.append(f"{ch}: заморозка {frozen:.1f} с подряд (в engaged)")
    out["sections"]["anomalies"] = anomalies
    out["checks"].append(("аномалии", not anomalies, "; ".join(anomalies) or "нет"))

    # 6. Залипание газа: sm > 0.9 при raw < 0.05 дольше 2 с
    stuck = []
    if {"throttle_raw", "throttle_smoothed"}.issubset(df.columns):
        r = pd.to_numeric(df["throttle_raw"], errors="coerce")
        s = pd.to_numeric(df["throttle_smoothed"], errors="coerce")
        mask = ((s > 0.9) & (r < 0.05)).to_numpy()
        for start, end, d in find_events(mask, t):
            if d >= 2.0:
                stuck.append((float(start), float(end), float(d)))
    out["sections"]["stuck_throttle"] = stuck
    out["checks"].append(("залипание газа", not stuck,
                          f"эпизодов ≥2 с: {len(stuck)}"
                          + (f" (макс {max(s[2] for s in stuck):.1f} с)" if stuck else "")))

    # 6b. ГАЗ > 0.9 дольше 3 с (НЕЗАВИСИМО от raw) — жалоба «газ 99%, нет
    # переключения». Выводим передачи/rpm: видно, застряла ли КПП.
    high = []
    if "throttle_smoothed" in df.columns:
        s = pd.to_numeric(df["throttle_smoothed"], errors="coerce")
        mask = (s > 0.9).fillna(False).to_numpy()
        gcol = df["gear"].astype(str).to_numpy() if "gear" in df.columns else None
        rcol = (pd.to_numeric(df["rpm"], errors="coerce").to_numpy()
                if "rpm" in df.columns else None)
        rw = (pd.to_numeric(df["throttle_raw"], errors="coerce").to_numpy()
              if "throttle_raw" in df.columns else None)
        bcol = (pd.to_numeric(df["brake_smoothed"], errors="coerce").to_numpy()
                if "brake_smoothed" in df.columns else None)
        for a, b, dur in find_events(mask, t):
            if dur >= 3.0:
                i0 = int(np.searchsorted(t, a))
                i1 = min(len(t) - 1, int(np.searchsorted(t, b)))
                high.append({
                    "t0": float(a), "t1": float(b), "dur": float(dur),
                    "gears": sorted(set(gcol[i0:i1 + 1])) if gcol is not None else [],
                    "rpm_max": float(np.nanmax(rcol[i0:i1 + 1])) if rcol is not None else None,
                    "raw_min": float(np.nanmin(rw[i0:i1 + 1])) if rw is not None else None,
                    "brake_max": float(np.nanmax(bcol[i0:i1 + 1])) if bcol is not None else None,
                })
    out["sections"]["high_throttle"] = high
    stuck_gear = [h for h in high if len(h["gears"]) <= 1]
    out["checks"].append(("газ>0.9 ≥3с", not stuck_gear,
                          f"эпизодов: {len(high)}"
                          + (f", без переключения передач: {len(stuck_gear)}" if high else "")))

    # 7. Руль: недоход на пиках |raw| (окно ±1 с)
    undershoot = []
    if {"steer_raw", "steer_smoothed"}.issubset(df.columns):
        r = pd.to_numeric(df["steer_raw"], errors="coerce").abs().to_numpy()
        s = pd.to_numeric(df["steer_smoothed"], errors="coerce").abs().to_numpy()
        step = max(1, int(round(1.0 / dt_med)))
        for i in range(0, len(r), step):
            j0, j1 = max(0, i - step), min(len(r), i + step)
            if j1 <= j0:
                continue
            rp, sp = r[j0:j1].max(), s[j0:j1].max()
            if rp > 0.25 and sp < rp - 0.05:
                undershoot.append((float(t[j0 + int(np.argmax(r[j0:j1]))]), float(rp), float(sp)))
    # слияние соседних окон
    merged = []
    for ev in undershoot:
        if merged and ev[0] - merged[-1][0] < 1.5:
            if ev[2] < merged[-1][2]:
                merged[-1] = ev
        else:
            merged.append(list(ev))
    out["sections"]["wheel_undershoot"] = merged[:30]
    out["checks"].append(("недоход руля", len(merged) <= 2,
                          f"пиков с недоходом >0.05: {len(merged)}"
                          + (f" (макс {max(m[1]-m[2] for m in merged):.3f})" if merged else "")))

    return out


def render_md(rep):
    L = [f"# Отчёт AutopilotLive: {rep['file']}", ""]
    L.append(f"Строк: **{rep['rows']}**, длительность: **{rep['duration_s'] or 0:.1f} с**, "
             f"dt: {rep['dt_median_s']*1000:.1f} мс")
    L.append("")
    L.append("## Вердикты")
    L.append("")
    L.append("| Проверка | Итог | Детали |")
    L.append("|---|---|---|")
    fails = 0
    for name, ok, detail in rep["checks"]:
        if not ok:
            fails += 1
        L.append(f"| {name} | {'PASS' if ok else 'FAIL'} | {detail} |")
    L.append("")
    L.append("## Каналы")
    L.append("")
    L.append("| колонка | n | min | max | mean | std | p95 | p99 | нули, % |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for col, s in rep["sections"]["channels"]:
        L.append(f"| {col} | {s['n']} | {s['min']:.4f} | {s['max']:.4f} | {s['mean']:.4f} | "
                 f"{s['std']:.4f} | {s['p95']:.4f} | {s['p99']:.4f} | {s['zeros_pct']:.1f} |")
    L.append("")
    L.append("## Сглаживание")
    L.append("")
    L.append("| канал | engaged % | ср.откл | макс.откл | лаг, с | corr | макс.скор | кап | % на капе |")
    L.append("|---|---|---|---|---|---|---|---|---|")
    for r in rep["sections"]["smoothing"]:
        lag = f"{r['lag_s']:.2f}" if r["lag_s"] is not None else "-"
        corr = f"{r['corr']:.3f}" if r["corr"] is not None else "-"
        L.append(f"| {r['channel']} | {r['engaged_pct']:.1f} | {r['mean_dev']:.4f} | "
                 f"{r['max_dev']:.4f} | {lag} | {corr} | {r['max_rate']:.2f} | "
                 f"{r['cap']:.1f} | {r['pct_at_cap']:.1f} |")
    L += ["", "## Скачки", ""]
    if rep["sections"]["jumps"]:
        for ch, ts, rate in rep["sections"]["jumps"][:20]:
            L.append(f"- {ch}: t={ts:.1f} с, {rate:.2f}/с")
    else:
        L.append("Нет.")
    L += ["", "## Залипание газа", ""]
    if rep["sections"]["stuck_throttle"]:
        for a, b, d in rep["sections"]["stuck_throttle"]:
            L.append(f"- t={a:.1f}–{b:.1f} с ({d:.1f} с)")
    else:
        L.append("Нет.")
    L += ["", "## Газ > 0.9 дольше 3 с (независимо от raw)", ""]
    ht = rep["sections"].get("high_throttle") or []
    if ht:
        L.append("| t0, с | t1, с | длит, с | передачи | rpm max | raw min | brake max |")
        L.append("|---|---|---|---|---|---|---|")
        for h in ht:
            rpm = '-' if h["rpm_max"] is None else f"{h['rpm_max']:.0f}"
            rawm = '-' if h["raw_min"] is None else f"{h['raw_min']:.3f}"
            brkm = '-' if h["brake_max"] is None else f"{h['brake_max']:.3f}"
            L.append(f"| {h['t0']:.1f} | {h['t1']:.1f} | {h['dur']:.1f} | "
                     f"{','.join(h['gears']) or '?'} | {rpm} | {rawm} | {brkm} |")
    else:
        L.append("Нет.")
    L += ["", "## Недоход руля (пики)", ""]
    if rep["sections"]["wheel_undershoot"]:
        for ts, rp, sp in rep["sections"]["wheel_undershoot"]:
            L.append(f"- t={ts:.1f} с: |raw|={rp:.3f}, |sm|={sp:.3f} (недоход {rp-sp:.3f})")
    else:
        L.append("Нет.")
    L += ["", "## Аномалии", ""]
    L += [f"- {a}" for a in rep["sections"]["anomalies"]] or ["Нет."]
    return "\n".join(L) + "\n", fails


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("csv")
    ap.add_argument("--md", default=None)
    ap.add_argument("--json", default=None)
    args = ap.parse_args()

    if not os.path.exists(args.csv):
        print(f"FAIL: файл не найден: {args.csv}")
        return 1
    try:
        df = pd.read_csv(args.csv)
    except Exception as e:  # noqa: BLE001
        print(f"FAIL: pandas не смог прочитать CSV: {e}")
        return 1

    rep = build_report(args.csv, df, load_caps())
    md, fails = render_md(rep)
    print(md)
    if args.md:
        with open(args.md, "w", encoding="utf-8") as f:
            f.write(md)
    if args.json:
        with open(args.json, "w", encoding="utf-8") as f:
            json.dump(rep, f, ensure_ascii=False, indent=2)
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
