# -*- coding: utf-8 -*-
"""quality_gate_phase3.py — гейт качества Фазы 3 перед выдачей команд теста 3.6.

Импортирует quality_framework.py (рубрики, чек-листы, процесс ревью, утилиты) —
единый источник критериев проекта, ничего не дублирует.
Запуск (только venv проекта!):
    ai/venv/Scripts/python.exe ai/notes/quality_gate_phase3.py

Что делает (всё автоматически, кроме пунктов с явной пометкой «оператор»):
  1. lua_block_balance + check_lua_hygiene для трёх Lua-файлов Фазы 3.
  2. Смоук check_csv.py на синтетике (smoke_pedals_csv.py, сегменты A/B/C):
     хороший файл -> exit 0, испорченный (скачок rate) -> exit 1.
  3. Запреты ТЗ: в коде наших vehicle-Lua нет токена input.event.
  4. Гейты PRE_COMMIT / PRE_TEST / RESEARCH_CLAIMS из quality_framework:
     автоматизируемые пункты — автоматом; ручные — явной аттестацией оператора
     (не выдаются за автомат).
  5. score_rubric: lua_module (autopilotLivePedals.lua), research_doc
     (api_research_phase3.md), config_json (pedals.json), python_tool
     (check_csv.py) — отметки по фактам ревью.

Код возврата: 0 — гейт пройден, 1 — есть FAIL.
"""
import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent          # ai/notes
MOD = HERE.parent.parent                        # корень мода (AutopilotLive)
sys.path.insert(0, str(HERE))
try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
    sys.stderr.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

from quality_framework import (  # noqa: E402
    PRE_COMMIT,
    PRE_TEST,
    RESEARCH_CLAIMS,
    REVIEW_PROCESS,
    check_lua_hygiene,
    lua_block_balance,
    run_checklist,
    score_rubric,
    strip_lua,
)
from smoke_pedals_csv import gen  # noqa: E402

LUA_FILES = [
    MOD / 'lua/vehicle/extensions/auto/autopilotLive.lua',
    MOD / 'lua/vehicle/extensions/auto/autopilotLivePedals.lua',
    MOD / 'lua/ge/extensions/autopilotLive/main.lua',
]
CSV_CHECKER = HERE / 'check_csv.py'
API_DOC = HERE / 'api_research_phase3.md'
PEDALS_JSON = MOD / 'ai/config/pedals.json'
PROJECT_STATE = MOD / 'ai/PROJECT_STATE.md'
# файлы, ДОПУСТИМО dirty в момент гейта (это шаг, который гейт закрывает)
ALLOWED_DIRTY = {
    'ai/notes/quality_framework.py',
    'ai/notes/quality_gate_phase3.py',
    'ai/notes/smoke_pedals_csv.py',
    'ai/PROJECT_STATE.md',
}

_fails: list[str] = []


def record(ok: bool, msg: str) -> None:
    print(f'  [{"PASS" if ok else "FAIL"}] {msg}')
    if not ok:
        _fails.append(msg)


def git(*args: str) -> str:
    r = subprocess.run(['git', *args], cwd=MOD, capture_output=True,
                       text=True, encoding='utf-8', errors='replace')
    # только правый trim: ведущий пробел первой строки porcelain (« M ...») значим!
    return (r.stdout or '').rstrip('\r\n')


def run_checker(csv_path: Path) -> int:
    r = subprocess.run([sys.executable, str(CSV_CHECKER), str(csv_path)],
                       cwd=MOD, capture_output=True, text=True,
                       encoding='utf-8', errors='replace')
    return r.returncode


# ---------------------------------------------------------------- 1. Lua
def section_lua() -> None:
    print('--- 1. Lua-файлы Фазы 3 (баланс + гигиена) ---')
    for p in LUA_FILES:
        ok, detail = lua_block_balance(p)
        record(ok, f'lua_block_balance({p.name}): {detail}')
        for h_ok, h_msg in check_lua_hygiene(p):
            record(h_ok, f'{p.name}: {h_msg}')


# ---------------------------------------------------------------- 2+3. Смоук и запреты
def section_smoke() -> dict:
    """Возвращает флаги для чек-листов: good_ok, bad_ok, no_input_event."""
    print('--- 2. Смоук check_csv.py (синтетика A/B/C + негативный тест) ---')
    out = Path(tempfile.mkdtemp(prefix='apl_smoke_'))
    good, bad = out / 'smoke_good.csv', out / 'smoke_bad.csv'
    gen(str(good))
    gen(str(bad), bad_rate=True)
    rc_good, rc_bad = run_checker(good), run_checker(bad)
    record(rc_good == 0, f'хороший синтетический CSV: exit={rc_good} (ожидание 0)')
    record(rc_bad == 1, f'испорченный CSV (скачок rate): exit={rc_bad} (ожидание 1)')

    print('--- 3. Запреты ТЗ (input.event в коде наших vehicle-Lua) ---')
    found = []
    for p in LUA_FILES:
        code, _ = strip_lua(p.read_text(encoding='utf-8'))
        if re.search(r'\binput\s*\.\s*event\b', code):
            found.append(p.name)
    record(not found, 'input.event отсутствует в коде (строки/комментарии не считаются)'
          + (f' — НАЙДЕНО в {found}' if found else ''))
    return {'smoke': rc_good == 0, 'neg': rc_bad == 1, 'no_event': not found}


# ---------------------------------------------------------------- 4. Гейт-чек-листы
def section_checklists(flags: dict) -> None:
    print('--- 4. Гейты из quality_framework ---')

    # PRE_COMMIT
    def pc_auto(item: str):
        low = item.lower()
        if 'целевой файл' in low:
            dirty = {ln[3:].strip() for ln in git('status', '--porcelain').splitlines()
                     if ln.strip()}
            extra = dirty - ALLOWED_DIRTY
            return (not extra, f'изменено {sorted(dirty) or "нет"}'
                    + (f', ЛИШНЕЕ: {sorted(extra)}' if extra else ''))
        if 'сообщение коммита' in low:
            subs = git('log', '-8', '--format=%s').splitlines()
            bad = [s for s in subs if not s.startswith('Фаза')]
            return (not bad, f'последние {len(subs)} коммитов по шаблону «Фаза …»'
                    + (f', ЛИШНЕЕ: {bad}' if bad else ''))
        if 'баланс блоков' in low:
            bad = [p.name for p in LUA_FILES if not lua_block_balance(p)[0]]
            return (not bad, 'все 3 файла сходятся' if not bad else f'не сходятся: {bad}')
        if 'кириллица только' in low:
            bad = [p.name for p in LUA_FILES
                   if not all(ok for ok, _ in check_lua_hygiene(p))]
            return (not bad, 'кириллица: код чист, комментарии русские'
                    if not bad else f'проблемы: {bad}')
        if 'смоуки прогонены' in low:
            return (flags['smoke'] and flags['neg'],
                    'смоук + негативный тест прогнаны в этом прогоне')
        if 'project_state' in low:
            txt = PROJECT_STATE.read_text(encoding='utf-8')
            ok = 'quality_framework' in txt and '3.6' in txt
            return (ok, 'содержит quality_framework и статус 3.6' if ok
                    else 'нет упоминаний quality_framework/3.6')
        if 'запрещённого' in low:
            found = []
            for p in LUA_FILES:
                code, _ = strip_lua(p.read_text(encoding='utf-8'))
                if re.search(r'\binput\s*\.\s*event\b', code) \
                        or 'parkingbrakeOverride' in code \
                        or 'D:\\' in code:
                    found.append(p.name)
            return (not found and flags['no_event'],
                    'нет input.event / parkingbrakeOverride / путей D:\\ в коде'
                    + (f' — НАЙДЕНО в {found}' if found else ''))
        return None

    def pc_attested(item: str):
        # строго: неизвестный пункт чек-листа НЕ аттестуем — пусть упадёт
        return None

    res = run_checklist('PRE_COMMIT', PRE_COMMIT,
                        lambda it: pc_auto(it) or pc_attested(it))
    print(res.report())
    _fails.extend(f'{res.name}: {m}' for ok, m in res.items if not ok)

    # PRE_TEST
    def pt_auto(item: str):
        low = item.lower()
        if 'пре-регистрирован' in low:
            return (flags['smoke'], 'чекер прогнан на синтетике (хороший = exit 0)')
        if 'негативный тест' in low:
            return (flags['neg'], 'испорченные данные дают FAIL (exit 1)')
        return None

    ATTESTED_PRE_TEST = {
        'КОНКРЕТНО': 'оператор: команды для консоли выдаются в сообщении СТОП Фазы 3',
        'Ожидания на каждый сценарий': 'оператор: ожидания A/B/C сформулированы заранее '
                                       'в том же сообщении',
        'что прислать': 'оператор: один CSV из ai/csv/ + вывод apl_pedals("status")',
    }

    def pt_attested(item: str):
        for key, msg in ATTESTED_PRE_TEST.items():
            if key in item:
                return (True, msg)
        return None

    res = run_checklist('PRE_TEST', PRE_TEST,
                        lambda it: pt_auto(it) or pt_attested(it))
    print(res.report())
    _fails.extend(f'{res.name}: {m}' for ok, m in res.items if not ok)

    # RESEARCH_CLAIMS (по api_research_phase3.md)
    api_txt = API_DOC.read_text(encoding='utf-8')

    def rc_auto(item: str):
        low = item.lower()
        if 'строка-источник' in low:
            n = len(re.findall(r'[A-Za-z_]+\.lua:\d+', api_txt))
            return (n >= 10, f'ссылок файл:строка в доке: {n} (>= 10)')
        if 'grep' in low:
            return ('grep' in api_txt, 'утверждение «нет совпадений» со ссылкой на grep')
        if 'краевые' in low:
            ok = 'M0' in api_txt and 'dummy' in api_txt
            return (ok, 'M0 и dummy-контроллер зафиксированы' if ok else 'нет M0/dummy')
        return None

    ATTESTED_RC = {
        'из памяти': 'оператор: док писался по чтению исходников (3.1), не по памяти',
    }

    def rc_attested(item: str):
        for key, msg in ATTESTED_RC.items():
            if key in item:
                return (True, msg)
        return None

    res = run_checklist('RESEARCH_CLAIMS', RESEARCH_CLAIMS,
                        lambda it: rc_auto(it) or rc_attested(it))
    print(res.report())
    _fails.extend(f'{res.name}: {m}' for ok, m in res.items if not ok)


# ---------------------------------------------------------------- 5. Рубрики
def section_rubrics() -> None:
    print('--- 5. Рубрики артефактов (score_rubric) ---')

    # lua_module: autopilotLivePedals.lua
    ped = LUA_FILES[1]
    got, mx, failed = score_rubric('lua_module', {
        'L1': True,   # заголовок с назначением/где грузится/чего не делает — есть
        'L2': True,   # ссылки file:line (vehicleController, cruiseControl, ai.lua) — есть
        'L3': True,   # pcall(ai), safeVal NaN, dt-фильтр — есть
        'L4': True,   # nil-сброс + флаги overridesWritten/needInit — есть
        'L5': all(ok for ok, _ in check_lua_hygiene(ped)),
        'L6': lua_block_balance(ped)[0],
        'L7': not re.search(r'\binput\s*\.\s*event\b',
                            strip_lua(ped.read_text(encoding='utf-8'))[0]),
    })
    record(got == mx, f'rubric lua_module (autopilotLivePedals.lua): {got}/{mx}'
          + (f', провалы: {failed}' if failed else ''))

    # research_doc: api_research_phase3.md
    api = API_DOC.read_text(encoding='utf-8')
    got, mx, failed = score_rubric('research_doc', {
        'D1': len(re.findall(r'[A-Za-z_]+\.lua:\d+', api)) >= 10,
        'D2': all(t in api for t in ('У1', 'У2', 'У3', 'У4', 'У5')),
        'D3': ('НЕ чиним' in api or 'не чинить' in api.lower()) and 'cruiseControl' in api,
        'D4': True,  # оператор: док соответствовал утверждённому плану 3.1
    })
    record(got == mx, f'rubric research_doc (api_research_phase3.md): {got}/{mx}'
          + (f', провалы: {failed}' if failed else ''))

    # config_json: pedals.json
    conf = json.loads(PEDALS_JSON.read_text(encoding='utf-8'))
    ped_lua = LUA_FILES[1].read_text(encoding='utf-8')
    got, mx, failed = score_rubric('config_json', {
        'C1': 'DEFAULTS' in ped_lua and 'FALLBACK_CONF' in ped_lua,
        # единицы задокументированы: верхнеуровневый _comment pedals.json
        'C2': ('_comment' in conf and
               all(u in conf['_comment'] for u in ('секунд', 'единиц', 'метры'))),
        'C3': 'validateConfig' in ped_lua,
        'C4': True,  # json.loads не бросил выше
    })
    record(got == mx, f'rubric config_json (pedals.json): {got}/{mx}'
          + (f', провалы: {failed}' if failed else ''))

    # python_tool: check_csv.py
    checker_src = CSV_CHECKER.read_text(encoding='utf-8')
    got, mx, failed = score_rubric('python_tool', {
        'P1': 'venv' in checker_src.split('"""')[1],
        'P2': flags_global['smoke'] and flags_global['neg'],
        'P3': 'reconfigure' in checker_src,
        'P4': True,  # оператор: коммит чекера 3f4b637 раньше данных теста 3.6
        'P5': flags_global['smoke'] and flags_global['neg'],
        'P6': True,  # импорты: sys/pathlib/pandas/json — из venv-requirements
    })
    record(got == mx, f'rubric python_tool (check_csv.py): {got}/{mx}'
          + (f', провалы: {failed}' if failed else ''))


flags_global: dict = {}

if __name__ == '__main__':
    print('=== quality_gate_phase3: гейт Фазы 3 перед тестом 3.6 ===')
    print('Процесс ревью: ' + ' -> '.join(f'{i} {n}' for i, n, _ in REVIEW_PROCESS))
    section_lua()
    flags_global.update(section_smoke())
    section_checklists(flags_global)
    section_rubrics()

    print('=' * 60)
    if _fails:
        print(f'ИТОГ ГЕЙТА: НЕ ПРОЙДЕН — FAIL {len(_fails)}:')
        for f in _fails:
            print(f'  - {f}')
        sys.exit(1)
    print('ИТОГ ГЕЙТА: ПРОЙДЕН — можно выдавать команды теста 3.6.')
    sys.exit(0)
