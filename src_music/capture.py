#!/usr/bin/env python3
"""soulPilot: захват аудио и анализ баса (кроссплатформенно).

Windows: soundcard -> WASAPI loopback. Для Spotify используйте VB-Audio
         Virtual Cable: вывод Spotify = "CABLE Input", захват = "CABLE Output".
Linux:   soundcard -> PulseAudio/PipeWire. Захватывается monitor-источник
         ("Monitor of ..."); при необходимости включается в pavucontrol.

Режимы:
    python capture.py --list
    python capture.py --device "CABLE Output"
    python capture.py --device 3 --bass-low 40 --bass-high 150

Скрипт ничего не пишет на диск и не отправляет UDP — только консоль.
Для записи current.json и UDP используйте main.py.
"""
from __future__ import annotations

import argparse
import math
import platform
import sys
import time
from collections import deque

import numpy as np

try:
    import soundcard as sc
    try:  # «data discontinuity» при loopback — безвредный шум
        from soundcard import SoundcardRuntimeWarning
        import warnings
        warnings.filterwarnings("ignore", category=SoundcardRuntimeWarning)
    except ImportError:
        pass
except ImportError:  # пакет ещё не установлен — сообщим об этом понятно
    sc = None


def configure_stdout() -> None:
    """Не падать на кириллице при перенаправлении вывода (cp1252/cp866)."""
    stream = sys.stdout
    if stream is None or not hasattr(stream, "reconfigure"):
        return
    try:
        if not stream.isatty():
            stream.reconfigure(encoding="utf-8", errors="replace")
        else:
            stream.reconfigure(errors="replace")
    except (ValueError, OSError):
        pass


# Настройка вывода нужна и библиотечным функциям (списки устройств, ошибки).
configure_stdout()


# ---------------------------------------------------------------------------
# Устройства захвата
# ---------------------------------------------------------------------------

def require_backend() -> None:
    """Проверяет, что soundcard установлен."""
    if sc is None:
        raise SystemExit(
            "Не найден пакет 'soundcard'.\n"
            "Установите зависимости:\n"
            "  ai/venv/Scripts/python.exe -m pip install -r src_music/requirements.txt\n"
            "  (Linux: ai/venv/bin/python -m pip install -r src_music/requirements.txt)"
        )


def all_capture_devices() -> list:
    """Все устройства, которые можно захватывать (включая loopback/monitor)."""
    require_backend()
    try:
        # include_loopback есть в Windows-реализации; в Linux аргумент
        # может отсутствовать — тогда monitor-источники уже в общем списке.
        try:
            devices = list(sc.all_microphones(include_loopback=True))
        except TypeError:
            devices = list(sc.all_microphones())
    except Exception as exc:  # звуковая подсистема недоступна
        raise SystemExit(f"Не удалось получить список аудиоустройств: {exc}") from exc
    return devices


def _device_channels(device) -> str:
    try:
        return f"{int(device.channels)} ch"
    except Exception:
        return "? ch"


def device_label(index: int, device) -> str:
    """Строка для списка устройств."""
    loop = getattr(device, "isloopback", None)
    loop_mark = " [loopback]" if loop else ""
    return f"{index:2d}. {device.name} ({_device_channels(device)}){loop_mark}"


def print_devices(devices: list) -> None:
    """Печатает список устройств и подсказку по выбору."""
    system = platform.system()
    print(f"ОС: {system} {platform.release()} | Python {platform.python_version()}")
    print(f"Доступно устройств захвата: {len(devices)}")
    for i, dev in enumerate(devices):
        print("  " + device_label(i, dev))

    if not devices:
        print("\nУстройств нет.")
        if system == "Linux":
            print("Проверьте PulseAudio/PipeWire:")
            print("  pactl list short sources    # monitor-источники")
            print("  wpctl status                # PipeWire")
        return

    default = default_capture_device(devices)
    if default is not None:
        print(f"\nПо умолчанию: {default.name}")

    if system == "Windows":
        print("\nПодсказка (Spotify через VB-Audio Virtual Cable):")
        print("  1) Spotify/Windows: вывод звука -> CABLE Input")
        print("  2) Захват -> устройство 'CABLE Output (VB-Audio Virtual Cable)'")
        print('  3) python capture.py --device "CABLE Output"')
    else:
        print("\nПодсказка (PulseAudio/PipeWire):")
        print("  Выберите 'Monitor of <устройство>' — это loopback вывода.")
        print('  python capture.py --device "Monitor of"')


def default_capture_device(devices: list):
    """Устройство по умолчанию: loopback текущих колонок, иначе default mic."""
    if not devices:
        return None
    require_backend()

    # Windows: у default_speaker есть парный loopback с тем же именем.
    if platform.system() == "Windows":
        try:
            speaker = sc.default_speaker()
            if speaker is not None:
                for dev in devices:
                    if dev.name == speaker.name and getattr(dev, "isloopback", False):
                        return dev
        except Exception:
            pass

    # Linux/Windows: штатный микрофон по умолчанию (в Linux это может быть
    # monitor-источник, если он выбран в системе).
    try:
        default_mic = sc.default_microphone()
    except Exception:
        default_mic = None
    if default_mic is not None:
        for dev in devices:
            if dev.name == default_mic.name:
                return dev

    return devices[0]


def find_device(spec, devices: list):
    """Выбор устройства: None/'' -> default, число -> индекс, иначе подстрока."""
    if not devices:
        raise SystemExit("Нет доступных устройств захвата. Запустите с --list.")

    if spec is None or not str(spec).strip():
        return default_capture_device(devices)

    text = str(spec).strip()
    if text.isdigit():
        index = int(text)
        if 0 <= index < len(devices):
            return devices[index]
        raise SystemExit(f"Индекс {index} вне диапазона (0..{len(devices) - 1}).")

    needle = text.casefold()
    matches = [dev for dev in devices if needle in dev.name.casefold()]
    if not matches:
        raise SystemExit(
            f"Устройство '{text}' не найдено. Список: python capture.py --list"
        )
    if len(matches) > 1:
        print(f"Найдено {len(matches)} совпадений, беру первое:")
        for dev in matches[:5]:
            print(f"  {dev.name}")
    return matches[0]


# ---------------------------------------------------------------------------
# Анализ: бас + BPM
# ---------------------------------------------------------------------------

def _db(value: float) -> float:
    return 20.0 * math.log10(max(float(value), 1e-9))


class BassAnalyzer:
    """FFT-анализ блока: уровень баса 0..1, beat-импульс, BPM.

    Уровень баса — амплитуда полосы [bass_low, bass_high] в дБ, отображённая
    на 0..1 через [db_floor, db_ceil], со сглаживанием attack/release.
    """

    def __init__(
        self,
        samplerate: int = 48000,
        block_size: int = 2048,
        bass_low: float = 40.0,
        bass_high: float = 150.0,
        db_floor: float = -50.0,
        db_ceil: float = -3.0,
        attack_s: float = 0.005,
        release_s: float = 0.15,
        min_bpm: float = 60.0,
        max_bpm: float = 200.0,
    ) -> None:
        self.samplerate = int(samplerate)
        self.block_size = int(block_size)
        self.db_floor = float(db_floor)
        self.db_ceil = max(float(db_ceil), self.db_floor + 1.0)
        self.attack_s = float(attack_s)
        self.release_s = float(release_s)
        self.min_bpm = float(min_bpm)
        self.max_bpm = float(max_bpm)

        self.window = np.hanning(self.block_size).astype(np.float32)
        freqs = np.fft.rfftfreq(self.block_size, 1.0 / self.samplerate)
        mask = (freqs >= float(bass_low)) & (freqs <= float(bass_high))
        if not np.any(mask):  # защита от неверного диапазона
            mask = (freqs >= 20.0) & (freqs <= 200.0)
        self.mask = mask

        # Уровень и beat
        self.level = 0.0
        self.band_db = -120.0
        self.rms_db = -120.0
        self.bpm = 0.0
        self._beat_hold_until = 0.0
        self._last_onset = -1e9
        self._prev_band = None
        self._armed = True  # ждём спад flux, чтобы не считать один удар дважды
        self._flux_history: deque[float] = deque(maxlen=64)
        self._onsets: deque[float] = deque(maxlen=9)

    def _fold_bpm(self, bpm: float) -> float:
        """Приводит темп к удобному диапазону (без полу/двойного)."""
        while bpm > 0 and bpm < self.min_bpm:
            bpm *= 2.0
        while bpm > self.max_bpm:
            bpm *= 0.5
        return bpm

    def process(self, block: np.ndarray, now: float) -> dict:
        """Обрабатывает блок сэмплов (frames, channels) или (frames,)."""
        samples = np.asarray(block, dtype=np.float32)
        if samples.ndim > 1:
            samples = samples.mean(axis=1)
        samples = np.asarray(samples).reshape(-1)
        if samples.size == 0:
            return self.state(now)

        frames = int(samples.size)
        dt = frames / float(self.samplerate)

        # Общий уровень (для индикации тишины/паузы)
        rms = float(np.sqrt(np.mean(samples * samples)))
        self.rms_db = _db(rms)

        # FFT всегда по полному окну (хвост нулями, если блок короче).
        if frames < self.block_size:
            samples = np.pad(samples, (0, self.block_size - frames))
        elif frames > self.block_size:
            samples = samples[: self.block_size]

        # Спектр и энергия полосы баса
        windowed = samples * self.window
        spectrum = np.abs(np.fft.rfft(windowed))
        band = spectrum[self.mask]
        band_amp = (4.0 / float(self.block_size)) * float(np.sqrt(np.sum(band * band)))
        self.band_db = _db(band_amp)

        normalized = (self.band_db - self.db_floor) / (self.db_ceil - self.db_floor)
        normalized = min(1.0, max(0.0, float(normalized)))

        # Attack/release — плавный 0..1 без дёрганья
        tau = self.attack_s if normalized > self.level else self.release_s
        coeff = 1.0 - math.exp(-dt / max(tau, 1e-4))
        self.level += (normalized - self.level) * coeff

        # Spectral flux по полосе баса -> onset -> BPM
        flux = 0.0
        if self._prev_band is not None and self._prev_band.shape == band.shape:
            diff = band - self._prev_band
            positive = float(np.sum(diff[diff > 0.0]))
            flux = positive / (float(np.sum(self._prev_band)) + 1e-9)
        self._prev_band = band

        threshold = 0.12
        if len(self._flux_history) >= 8:
            history = np.asarray(self._flux_history, dtype=np.float32)
            threshold = max(threshold, float(np.mean(history) + np.std(history)))

        onset = False
        # Гистерезис: после удара ждём спада flux ниже порога, иначе
        # затухание одного kick даёт несколько ложных onset.
        if flux <= threshold * 0.8:
            self._armed = True
        if (
            self._armed
            and flux > threshold
            and flux > 0.08
            and (now - self._last_onset) >= 0.20
        ):
            onset = True
            self._armed = False
            self._last_onset = now
            self._beat_hold_until = now + 0.12
            self._onsets.append(now)
            self._update_bpm()

        self._flux_history.append(flux)

        # Если удары пропали — BPM не висит вечно
        if now - self._last_onset > 4.0:
            self.bpm = 0.0

        return self.state(now)

    def _update_bpm(self) -> None:
        if len(self._onsets) < 3:
            return
        times = np.asarray(self._onsets, dtype=np.float64)
        intervals = np.diff(times)
        intervals = intervals[(intervals >= 0.25) & (intervals <= 1.2)]
        if intervals.size < 2:
            return
        bpm = 60.0 / float(np.median(intervals))
        self.bpm = self._fold_bpm(bpm)

    def state(self, now: float) -> dict:
        beat = 1 if now < self._beat_hold_until else 0
        return {
            "level": round(float(self.level), 3),
            "beat": beat,
            "bpm": round(float(self.bpm), 1),
            "band_db": round(float(self.band_db), 1),
            "rms_db": round(float(self.rms_db), 1),
        }


# ---------------------------------------------------------------------------
# Захват
# ---------------------------------------------------------------------------

def iter_blocks(device, samplerate: int, blocksize: int, seconds: float = 0.0):
    """Генератор аудиоблоков с устройства (float32)."""
    deadline = time.monotonic() + seconds if seconds > 0 else None
    with device.recorder(samplerate=int(samplerate), blocksize=int(blocksize)) as recorder:
        while deadline is None or time.monotonic() < deadline:
            data = recorder.record(numframes=int(blocksize))
            if data is None or len(data) == 0:
                continue
            yield np.asarray(data, dtype=np.float32)


def format_state(state: dict) -> str:
    """Короткая строка статуса для консоли."""
    bpm = f"{state['bpm']:.0f}" if state["bpm"] > 0 else "--"
    return (
        f"bass={state['level']:.2f} beat={state['beat']} bpm={bpm:>3} "
        f"band={state['band_db']:6.1f}dB rms={state['rms_db']:6.1f}dB"
    )


def build_arg_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="soulPilot: захват аудио и анализ баса (консоль)."
    )
    parser.add_argument("--list", action="store_true", help="показать устройства и выйти")
    parser.add_argument(
        "--device", default=None,
        help="устройство: индекс из --list или подстрока имени (например 'CABLE Output')",
    )
    parser.add_argument("--rate", type=int, default=48000, help="частота дискретизации, Гц")
    parser.add_argument("--block", type=int, default=2048, help="размер блока, сэмплов")
    parser.add_argument("--seconds", type=float, default=0.0, help="длительность, с (0 = бесконечно)")
    parser.add_argument("--bass-low", type=float, default=40.0, help="нижняя граница баса, Гц")
    parser.add_argument("--bass-high", type=float, default=150.0, help="верхняя граница баса, Гц")
    parser.add_argument("--db-floor", type=float, default=-50.0, help="уровень bass=0.0, дБ")
    parser.add_argument("--db-ceil", type=float, default=-3.0, help="уровень bass=1.0, дБ")
    parser.add_argument("--print-hz", type=float, default=4.0, help="частота строк статуса, Гц")
    return parser


def run_console(args: argparse.Namespace) -> int:
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

    print(f"Захват: {device.name} ({_device_channels(device)})")
    print(
        f"rate={args.rate} block={args.block} "
        f"bass={args.bass_low:.0f}-{args.bass_high:.0f}Hz "
        f"db=[{args.db_floor:.0f}..{args.db_ceil:.0f}]"
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

    print_period = 1.0 / max(args.print_hz, 0.1)
    last_print = 0.0

    try:
        for block in iter_blocks(device, args.rate, args.block, args.seconds):
            now = time.monotonic()
            state = analyzer.process(block, now)
            if now - last_print >= print_period:
                last_print = now
                line = format_state(state)
                sys.stdout.write("\r" + line.ljust(78))
                sys.stdout.flush()
    except KeyboardInterrupt:
        pass
    except Exception as exc:
        print("\nОшибка захвата: " + str(exc))
        print("Проверьте, что устройство не занято и выбрано верно (--list).")
        return 1
    finally:
        sys.stdout.write("\n")

    print("Остановлено.")
    return 0


def main(argv=None) -> int:
    configure_stdout()
    return run_console(build_arg_parser().parse_args(argv))


if __name__ == "__main__":
    raise SystemExit(main())
