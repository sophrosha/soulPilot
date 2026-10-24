# -*- coding: utf-8 -*-
"""quality_framework.py — единый фреймворк качества проекта AutopilotLive.

СОВМЕСТИМОСТЬ: Python 3.13 (ai/venv), только стандартная библиотека.
ИСПОЛЬЗОВАНИЕ: импортировать из последующих скриптов (чекеров, гейтов,
генераторов) — from quality_framework import <функция>; либо запустить
самостоятельно для самопроверки фреймворка: python quality_framework.py.

Содержимое (реиспользуемые сущности, НЕ дублируются в других скриптах):
  * REVIEW_PROCESS — упорядоченный процесс ревью артефакта (7 шагов);
  * RUBRICS — рубрики оценки по типам артефактов (Lua-модуль, Python-инструмент,
    research-док, JSON-конфиг, план/отчёт) с весами критериев;
  * CHECKLISTS — гейт-чек-листы (pre_commit, pre_test, research_claims);
  * утилиты: lua_block_balance() (грубый баланс блоков, проверен на известно-
    хороших файлах мода), has_cyrillic(), check_lua_hygiene() (язык комментариев,
    кириллица вне комментариев/строк), run_checklist(), score_rubric().

ФИЛОСОФИЯ: честность (утверждения проверяются по источникам, а не по памяти),
воспроизводимость (каждый инструмент запускаем и показывает вывод),
минимальность (каждая проверка — конкретное правило с обоснованием).
"""
from __future__ import annotations

import re
from dataclasses import dataclass, field
from pathlib import Path
from typing import Callable, Iterable

# ============================================================
# 1. ПРОЦЕСС РЕВЬЮ (порядок обязателен: сначала факты, потом стиль)
# ============================================================
# Каждый шаг: (id, название, что сделать). Итог ревью — таблица соответствия.
REVIEW_PROCESS = [
    ('R1', 'Факты по источникам',
     'Каждое утверждение «в файле X строка Y делает Z» проверено чтением '
     'реального файла; цитаты и номера строк согласованы.'),
    ('R2', 'Соответствие требованиям/условиям',
     'Все пункты ТЗ/условия пользователя (У1, У2, …) закрыты и помечены где именно.'),
    ('R3', 'Безопасность и гварды',
     'pcall на внешних API, NaN/nil-проверки, отсутствие жёстких путей, '
     'сброс состояния (nil, не залипшие значения), отсутствие запрещённых '
     'операций (input.event, КПП, правка файлов игры).'),
    ('R4', 'Идентичность и стиль',
     'Имена по-английски, комментарии по-русски, кириллицы в коде/строках нет, '
     'форматирование единообразно.'),
    ('R5', 'Граничные случаи',
     'Поведение при nil/NaN/пустом вводе/отсутствии машины/смене миссии определено.'),
    ('R6', 'Тестируемость',
     'Есть способ проверить (смоук на синтетике, негативный тест, чекер) — и он пройден.'),
    ('R7', 'Документация',
     'Отвечает за «почему», а не «что»; ссылки на источники; состояние в PROJECT_STATE.'),
]

# ============================================================
# 2. РУБРИКИ ОЦЕНКИ ПО ТИПАМ АРТЕФАКТОВ
# ============================================================
# Критерий: (id, формулировка, вес 1..3, проверяемая функция может быть None).
RUBRICS: dict[str, list[tuple[str, str, int]]] = {
    'lua_module': [
        ('L1', 'Заголовок: назначение, где грузится, чего НЕ делает', 2, None),
        ('L2', 'Каждый неочевидный блок объясняет «почему» + ссылка на источник (файл:строка)', 3, None),
        ('L3', 'Гварды: pcall на внешних API, NaN/nil на входах, dt-фильтр', 3, None),
        ('L4', 'Состояние сбрасывается корректно (nil-критичность, флаги one-shot)', 2, None),
        ('L5', 'Имена по-английски; комментарии по-русски; кириллицы в коде нет', 2, 'cyrillic_free_code'),
        ('L6', 'Баланс блоков Lua (грубая эвристика — после правок)', 1, 'lua_balance'),
        ('L7', 'Нет запрещённого: input.event, трогание КПП/руля, файлы игры', 3, None),
    ],
    'python_tool': [
        ('P1', 'Docstring: запуск (через venv!), что делает, формат вывода', 2, None),
        ('P2', 'Код возврата: 0 — всё ок, 1 — есть FAIL, 2 — аргументы/чтение', 2, None),
        ('P3', 'Кириллица в консоли Windows защищена (reconfigure utf-8)', 1, None),
        ('P4', 'Проверки пре-регистрированы ДО данных (не подгонка под результат)', 3, None),
        ('P5', 'Смоук на синтетике + негативный тест (ломаю данные → ловит)', 3, None),
        ('P6', 'Только venv-зависимости из ai/requirements.txt', 1, None),
    ],
    'research_doc': [
        ('D1', 'Каждый факт снабжён ссылкой файл:строка из реального исходника', 3, None),
        ('D2', 'Ответы на все поставленные критичные вопросы (включая «проверь, что нет»)', 3, None),
        ('D3', 'Зафиксированы ограничения/конфликты «не чиним» с обоснованием', 2, None),
        ('D4', 'Соответствует утверждённому плану (нет самовольного расширения объёма)', 2, None),
    ],
    'config_json': [
        ('C1', 'Все параметры в файле, дубли в коде — явный fallback с пометкой', 3, None),
        ('C2', 'Единицы измерения задокументированы (_comment)', 2, None),
        ('C3', 'Валидация на границах: деления на ноль, диапазоны, отрицательные тау', 3, None),
        ('C4', 'JSON валиден (парсится) — проверка запуском', 2, None),
    ],
    'plan_report': [
        ('G1', 'Структура: контекст → решения → шаги → риски → ожидаемый результат', 2, None),
        ('G2', 'Каждый шаг имеет артефакт и критерий «как понять, что готов»', 2, None),
        ('G3', 'Вопросы/вето пользователя вынесены явно, а не спрятаны', 2, None),
        ('G4', 'Числа и ожидания конкретны (не «плавно», а «N мс из конфига»)', 2, None),
    ],
}

# ============================================================
# 3. ГЕЙТ-ЧЕК-ЛИСТЫ (проходятся ПЕРЕД коммитом / перед выдачей теста)
# ============================================================
PRE_COMMIT = [
    'git status: в коммит попадает только целевой файл(ы) шага',
    'Сообщение коммита: русское, «Фаза X (Y.N): суть»',
    'Lua: баланс блоков сходится (quality_framework.lua_block_balance)',
    'Lua/Python: кириллица только в комментариях/докстрингах',
    'Проверки/смоуки ПРОГОНЕНЫ, вывод показан (не «должно работать»)',
    'PROJECT_STATE.md обновлён (статус шага + хеш коммита)',
    'Ничего запрещённого не добавлено (input.event, файлы игры, КПП)',
]

PRE_TEST = [
    'Команды теста написаны КОНКРЕТНО (копипаст в консоль)',
    'Ожидания на каждый сценарий сформулированы заранее',
    'Чекер пре-регистрирован (готов ДО данных) и просмоулен на синтетике',
    'Негативный тест чекера пройден (испорченные данные ловятся)',
    'Пользователю ясно, что прислать (файлы/логи) и куда смотреть',
]

RESEARCH_CLAIMS = [
    'Каждая строка-источник («file.lua:NNN») проверена чтением файла',
    'Утверждение «нет совпадений» поддержано grep с указанием паттерна',
    'Нет выводов из памяти игры — только из прочитанного кода',
    'Краевые случаи (M0, dummy-контроллер, cruiseControl) зафиксированы',
]

# ============================================================
# 4. УТИЛИТЫ (переиспользуемые проверки)
# ============================================================

_CYR = re.compile(r'[\u0400-\u04FF]')


def has_cyrillic(text: str) -> bool:
    """Есть ли кириллица в тексте (для поиска её вне комментариев)."""
    return bool(_CYR.search(text))


def strip_lua(src: str) -> tuple[str, str]:
    """Разбирает Lua одним проходом: убирает комментарии и строки.

    Возвращает (код_без_строк, содержимое_строк).
    Порядок важен: строка может содержать '--' (например '--- статус'),
    поэтому строки и комментарии разбираются СОСТОЯТЕЛЬНЫМ автоматом слева
    направо, а не последовательными regex (regex-вариант 2026-10-12 съедал
    закрывающую кавычку у '--- ...' — ложный FAIL гигиены).
    """
    out: list[str] = []
    strings: list[str] = []
    i, n = 0, len(src)
    # строки копим поэлементно, счётчик считает по списку (не по склейке)
    while i < n:
        c = src[i]
        two = src[i:i + 2]
        if two == '--':
            if src[i:i + 4] == '--[[':
                # содержимое блочного комментария — НЕ строка, не копим
                j = src.find(']]', i + 4)
                i = (j + 2) if j != -1 else n
            else:
                j = src.find('\n', i)
                i = j if j != -1 else n  # перевод строки сохраняем
            out.append('\n' if i < n and src[i] == '\n' else ' ')
            continue
        if c == "'" or c == '"':
            q, j, buf = c, i + 1, []
            while j < n:
                cj = src[j]
                if cj == '\\':
                    buf.append(src[j:j + 2])
                    j += 2
                    continue
                if cj == q:
                    break
                buf.append(cj)
                j += 1
            strings.append(''.join(buf))
            out.append(q + 'S' + q)
            i = j + 1
            continue
        if two == '[[':
            j = src.find(']]', i + 2)
            strings.append(src[i + 2:j if j != -1 else n])
            i = (j + 2) if j != -1 else n
            out.append('[[]]')
            continue
        out.append(c)
        i += 1
    return ''.join(out), '\x00'.join(strings)


def lua_block_balance(path: Path | str) -> tuple[bool, str]:
    """Грубая проверка баланса блоков Lua (function/if/for/while/do против end).

    Эвристика проверена на известно-хороших файлах мода (autopilotLive.lua,
    main.lua — идентичный счёт до/после правок; standalone `do ... end`
    учитываются отдельно — находка 2026-10-12 в GE main.lua: 3 шт.).
    НЕ заменяет интерпретатор, ловит грубые обрезки/опечатки после правок.
    """
    src = Path(path).read_text(encoding='utf-8')
    code, _ = strip_lua(src)
    funcs = len(re.findall(r'\bfunction\b', code))
    ifs = len(re.findall(r'\bif\b', code))
    fors = len(re.findall(r'\bfor\b', code))
    whiles = len(re.findall(r'\bwhile\b', code))
    dos = len(re.findall(r'\bdo\b', code))
    # do входит в for/while-блок; standalone do — самостоятельный opener
    standalone_do = max(0, dos - fors - whiles)
    ends = len(re.findall(r'\bend\b', code))
    expected = funcs + ifs + fors + whiles + standalone_do
    return expected == ends, (
        f'function={funcs} if={ifs} for={fors} while={whiles} '
        f'standalone_do={standalone_do} end={ends} (ожидание end={expected})')


def check_lua_hygiene(path: Path | str) -> list[tuple[bool, str]]:
    """Кириллица-гигиена Lua по конвенциям проекта.

    Правила: кириллицы в КОДЕ (вне строк) быть НЕ должно (идентификаторы и
    логика — латиница); кириллица в СТРОКАХ-сообщениях РАЗРЕШЕНА (конвенция
    «общение на русском» — логи/вывод для пользователя); комментарии —
    по-русски (конвенция). Возвращает (ok, сообщение) по каждому правилу.
    """
    raw = Path(path).read_text(encoding='utf-8')
    code, strings = strip_lua(raw)
    out: list[tuple[bool, str]] = []
    out.append((not has_cyrillic(code),
                'кириллицы в коде (вне строк) нет' if not has_cyrillic(code)
                else 'НАЙДЕНА кириллица в коде вне строк'))
    n_ru_str = sum(1 for s in strings.split('\x00') if s and has_cyrillic(s))
    out.append((True, f'строк-сообщений с кириллицей: {n_ru_str} (разрешено конвенцией)'))
    comment_lines = [ln for ln in raw.splitlines() if ln.strip().startswith('--')]
    ru = sum(1 for ln in comment_lines if has_cyrillic(ln))
    ratio = (ru / len(comment_lines)) if comment_lines else 1.0
    out.append((ratio >= 0.5 or not comment_lines,
                f'комментарии по-русски: {ru}/{len(comment_lines)} ({ratio:.0%})'))
    return out


@dataclass
class CheckResult:
    """Результат прохода чек-листа: список отметок + сводка."""
    name: str
    items: list[tuple[bool, str]] = field(default_factory=list)

    @property
    def passed(self) -> int:
        return sum(1 for ok, _ in self.items if ok)

    def report(self) -> str:
        lines = [f'--- {self.name}: {self.passed}/{len(self.items)} ---']
        for ok, msg in self.items:
            lines.append(f'  [{"PASS" if ok else "FAIL"}] {msg}')
        return '\n'.join(lines)


def run_checklist(name: str, items: Iterable[str],
                  validator: Callable[[str], tuple[bool, str] | None] | None = None) -> CheckResult:
    """Проходит чек-лист. validator(item) -> (ok, msg) | None (None = пропуск/ручная).

    Без validator все пункты помечаются как «ручная проверка — не подтверждена»,
    чтобы фреймворк не выдавал ложных PASS.
    """
    res = CheckResult(name=name)
    for it in items:
        verdict = validator(it) if validator else None
        if verdict is None:
            res.items.append((False, f'{it} — [ручная проверка: не подтверждена в этом прогоне]'))
        else:
            res.items.append((verdict[0], f'{it} — {verdict[1]}'))
    return res


def score_rubric(kind: str, marks: dict[str, bool]) -> tuple[float, float, list[str]]:
    """Скоринг рубрики артефакта: marks = {criterion_id: ok}.

    Возвращает (получено, максимум, список проваленных критериев).
    Критерии без отметки считаются НЕ пройденными (честность по умолчанию).
    """
    if kind not in RUBRICS:
        raise ValueError(f'неизвестная рубрика: {kind}')
    got, mx, failed = 0.0, 0.0, []
    for cid, text, weight, _hook in RUBRICS[kind]:
        mx += weight
        if marks.get(cid):
            got += weight
        else:
            failed.append(f'{cid} (вес {weight}): {text}')
    return got, mx, failed


# ============================================================
# 5. САМОПРОВЕРКА ФРЕЙМВОРКА (запуск: python quality_framework.py)
# ============================================================
if __name__ == '__main__':
    import sys

    # P3 (как и в check_csv.py): cp1252-консоль Windows не показывает кириллицу
    try:
        sys.stdout.reconfigure(encoding='utf-8', errors='replace')
        sys.stderr.reconfigure(encoding='utf-8', errors='replace')
    except Exception:
        pass

    here = Path(__file__).resolve().parent
    mod_dir = here.parent.parent / 'lua' / 'vehicle' / 'extensions' / 'auto'
    ge_main = here.parent.parent / 'lua' / 'ge' / 'extensions' / 'autopilotLive' / 'main.lua'
    targets = [mod_dir / n for n in ('autopilotLive.lua', 'autopilotLivePedals.lua')] + [ge_main]
    print('=== quality_framework: самопроверка ===')
    print(f'Рубрик: {len(RUBRICS)}, процесс ревью: {len(REVIEW_PROCESS)} шагов, '
          f'гейтов: {len(PRE_COMMIT) + len(PRE_TEST) + len(RESEARCH_CLAIMS)} пунктов')

    # утилиты на известно-хороших файлах мода
    for p in targets:
        if not p.exists():
            print(f'  [skip] {p.name} не найден')
            continue
        ok, detail = lua_block_balance(p)
        print(f'  [{"PASS" if ok else "FAIL"}] lua_block_balance({p.name}): {detail}')
        for ok2, msg2 in check_lua_hygiene(p):
            print(f'  [{"PASS" if ok2 else "FAIL"}] hygiene({p.name}): {msg2}')

    # быстрая демонстрация скоринга
    got, mx, failed = score_rubric('lua_module', {'L5': True, 'L6': True})
    print(f'  [demo] score_rubric lua_module: {got}/{mx}, провалы: {failed[:2]}...')

    # чек-лист без validator — все пункты честно «не подтверждены»
    r = run_checklist('демо-гейт', ['пункт А', 'пункт Б'])
    assert r.passed == 0
    print(f'  [demo] run_checklist без validator: {r.passed}/{len(r.items)} (ложных PASS нет) — ок')
    print('=== самопроверка завершена ===')
    sys.exit(0)
