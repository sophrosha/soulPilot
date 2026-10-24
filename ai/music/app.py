#!/usr/bin/env python3
"""AutopilotLive: захват -> FFT -> бас/BPM -> current.json + UDP.

По умолчанию открывается PySide6-окно (Фаза 11.2). Консольный режим:
    ai\\venv\\Scripts\\python.exe ai\\music\\app.py --console
    ai\\venv\\Scripts\\python.exe ai\\music\\app.py --console --device "CABLE Output"
    ai\\venv\\Scripts\\python.exe ai\\music\\app.py --list

Файл по умолчанию: ai/music/current.json (рядом с этим скриптом), то есть
для BeamNG — mods/unpacked/AutopilotLive/ai/music/current.json.
"""
from __future__ import annotations

import argparse
import sys
import time
from pathlib import Path

try:  # запуск как скрипт: python ai/music/app.py
    from capture import (
        BassAnalyzer,
        all_capture_devices,
        build_arg_parser,
        configure_stdout,
        find_device,
        format_state,
        iter_blocks,
        print_devices,
    )
    from publisher import Publisher
except ImportError:  # запуск как модуль: python -m ai.music.app
    from .capture import (  # type: ignore
        BassAnalyzer,
        all_capture_devices,
        build_arg_parser,
        configure_stdout,
        find_device,
        format_state,
        iter_blocks,
        print_devices,
    )
    from .publisher import Publisher  # type: ignore


SILENCE_DB = -70.0        # ниже этого — тишина
PAUSE_AFTER_S = 2.0       # столько тишины -> paused=true


def build_parser() -> argparse.ArgumentParser:
    parser = build_arg_parser()
    parser.description = "AutopilotLive: аудио -> анализ баса -> current.json + UDP."
    parser.add_argument(
        "--out",
        default=str(Path(__file__).resolve().with_name("current.json")),
        help="путь к current.json (по умолчанию ai/music/current.json)",
    )
    parser.add_argument("--publish-hz", type=float, default=20.0, help="частота записи/UDP, Гц")
    parser.add_argument("--no-file", action="store_true", help="не писать current.json")
    parser.add_argument("--no-udp", action="store_true", help="не отправлять UDP")
    parser.add_argument("--udp-host", default="127.0.0.1", help="UDP host")
    parser.add_argument("--udp-port", type=int, default=7771, help="UDP port")
    parser.add_argument("--console", action="store_true", help="консольный режим без PySide6")
    return parser


def run(args: argparse.Namespace) -> int:
    devices = all_capture_devices()

    if args.list:
        print_devices(devices)
        return 0
    if not devices:
        print_devices(devices)
        return 2

    device = find_device(args.device, devices)
    if device is None:
        raise SystemExit("Не удалось выбрать устройство. Запустите с --list.")

    out_path = Path(args.out).expanduser().resolve()
    publish_period = 1.0 / max(1.0, min(float(args.publish_hz), 60.0))
    print_period = 1.0 / max(float(args.print_hz), 0.1)

    print(f"Захват: {device.name}")
    print(
        f"rate={args.rate} block={args.block} "
        f"bass={args.bass_low:.0f}-{args.bass_high:.0f}Hz"
    )
    print(f"JSON: {out_path}" + (" (выкл)" if args.no_file else ""))
    print(
        "UDP: "
        + ("выкл" if args.no_udp else f"{args.udp_host}:{args.udp_port}")
    )
    print("Ctrl+C — остановка.\n")

    analyzer = BassAnalyzer(
        samplerate=args.rate,
        block_size=args.block,
        bass_low=args.bass_low,
        bass_high=args.bass_high,
        db_floor=args.db_floor,
        db_ceil=args.db_ceil,
    )

    publisher = Publisher(
        out_path,
        udp_host=args.udp_host,
        udp_port=args.udp_port,
        udp_enabled=not args.no_udp,
        file_enabled=not args.no_file,
    )

    next_publish = 0.0
    next_print = 0.0
    silent_since = None
    last_state = analyzer.state(time.monotonic())

    try:
        with publisher:
            for block in iter_blocks(device, args.rate, args.block, args.seconds):
                now = time.monotonic()
                state = analyzer.process(block, now)
                last_state = state

                # Пауза: длительная тишина (Spotify закрыт/трек остановлен)
                if state["rms_db"] < SILENCE_DB:
                    if silent_since is None:
                        silent_since = now
                else:
                    silent_since = None
                paused = silent_since is not None and (now - silent_since) >= PAUSE_AFTER_S

                if next_publish <= 0.0:
                    next_publish = now
                if now >= next_publish:
                    next_publish += publish_period
                    if next_publish <= now:  # отстали — не копим долг
                        next_publish = now + publish_period
                    publisher.publish(
                        {
                            "bass": state["level"],
                            "bass_db": state["band_db"],
                            "beat": state["beat"],
                            "bpm": state["bpm"],
                            "rms": round(10.0 ** (state["rms_db"] / 20.0), 4),
                            "rms_db": state["rms_db"],
                            "paused": bool(paused),
                            "rate": int(args.rate),
                            "block": int(args.block),
                            "source": device.name,
                        }
                    )

                if next_print <= 0.0:
                    next_print = now
                if now >= next_print:
                    next_print += print_period
                    if next_print <= now:
                        next_print = now + print_period
                    flags = ""
                    if args.no_file:
                        flags += " file=off"
                    elif publisher.last_file_error:
                        flags += " FILE-ERR"
                    if publisher.last_udp_error:
                        flags += " UDP-ERR"
                    if paused:
                        flags += " PAUSED"
                    line = format_state(state) + flags
                    sys.stdout.write("\r" + line.ljust(96))
                    sys.stdout.flush()

            # Финальный кадр: честная пауза, чтобы Lua не держал последний бас.
            publisher.publish(
                {
                    "bass": 0.0,
                    "bass_db": -120.0,
                    "beat": 0,
                    "bpm": 0.0,
                    "rms": 0.0,
                    "rms_db": -120.0,
                    "paused": True,
                    "rate": int(args.rate),
                    "block": int(args.block),
                    "source": device.name,
                }
            )
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        print("\nОшибка захвата: " + str(exc))
        print("Проверьте устройство (--list) и что оно не занято эксклюзивно.")
        return 1
    finally:
        sys.stdout.write("\n")

    print("Остановлено.")
    return 0


def main(argv=None) -> int:
    configure_stdout()
    args = build_parser().parse_args(argv)

    # Консоль: явный флаг, список устройств или тестовый прогон по --seconds.
    if args.console or args.list or args.seconds > 0:
        return run(args)

    try:
        from ui import run_ui  # PySide6 импортируется только для GUI
    except ImportError as exc:
        print("PySide6 недоступен (" + str(exc) + ") — запуск в консольном режиме.")
        return run(args)

    return run_ui(args)


if __name__ == "__main__":
    raise SystemExit(main())
