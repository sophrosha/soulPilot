#!/usr/bin/env python3
"""soulPilot: минималистичный PySide6-интерфейс аудио-анализа.

Окно: выбор устройства захвата, Start/Stop, полоски Bass/Beat, BPM.
Захват и FFT идут в QThread, UI не блокируется. Настройки (устройство)
сохраняются в src_music/config.json.

Запуск (обычно через main.py, который поднимает это окно):
    ai\\venv\\Scripts\\python.exe ai\\music\\main.py
"""
from __future__ import annotations

import json
import os
import sys
import threading
import time
from pathlib import Path

from PySide6.QtCore import QThread, Signal
from PySide6.QtWidgets import (
    QApplication,
    QComboBox,
    QHBoxLayout,
    QLabel,
    QMainWindow,
    QMessageBox,
    QProgressBar,
    QPushButton,
    QVBoxLayout,
    QWidget,
)

try:  # запуск как скрипт: python src_music/main.py
    from capture import (
        BassAnalyzer,
        all_capture_devices,
        configure_stdout,
        default_capture_device,
        iter_blocks,
    )
    from publisher import Publisher
except ImportError:  # запуск как модуль: python -m ai.music.app
    from .capture import (  # type: ignore
        BassAnalyzer,
        all_capture_devices,
        configure_stdout,
        default_capture_device,
        iter_blocks,
    )
    from .publisher import Publisher  # type: ignore


CONFIG_PATH = Path(__file__).resolve().with_name("config.json")
SILENCE_DB = -70.0
PAUSE_AFTER_S = 2.0


# ---------------------------------------------------------------------------
# Настройки
# ---------------------------------------------------------------------------

def load_settings(path: Path = CONFIG_PATH) -> dict:
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def save_settings(settings: dict, path: Path = CONFIG_PATH) -> None:
    try:
        path.write_text(
            json.dumps(settings, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
    except OSError:
        pass


# ---------------------------------------------------------------------------
# Поток захвата
# ---------------------------------------------------------------------------

class CaptureWorker(QThread):
    """Захват + анализ + публикация в отдельном потоке."""

    reading = Signal(dict)
    failed = Signal(str)

    def __init__(self, device_name: str, device_index: int, args) -> None:
        super().__init__()
        self.device_name = device_name
        self.device_index = int(device_index)
        self.args = args
        self._stop_event = threading.Event()

    def stop(self) -> None:
        self._stop_event.set()

    def run(self) -> None:
        com_initialized = False
        publisher = None
        try:
            # soundcard инициализирует COM при импорте в главном потоке;
            # в QThread нужен свой CoInitializeEx (MTA), иначе WASAPI упадёт.
            if os.name == "nt":
                try:
                    import ctypes
                    ctypes.windll.ole32.CoInitializeEx(None, 0)
                    com_initialized = True
                except Exception:
                    pass

            devices = all_capture_devices()
            device = next((d for d in devices if d.name == self.device_name), None)
            if device is None and 0 <= self.device_index < len(devices):
                device = devices[self.device_index]
            if device is None:
                raise RuntimeError("Устройство захвата не найдено: " + self.device_name)

            args = self.args
            analyzer = BassAnalyzer(
                samplerate=args.rate,
                block_size=args.block,
                bass_low=args.bass_low,
                bass_high=args.bass_high,
                db_floor=args.db_floor,
                db_ceil=args.db_ceil,
            )
            out_path = Path(args.out).expanduser().resolve()
            publisher = Publisher(
                out_path,
                udp_host=args.udp_host,
                udp_port=args.udp_port,
                udp_enabled=not args.no_udp,
                file_enabled=not args.no_file,
            )

            publish_period = 1.0 / max(1.0, min(float(args.publish_hz), 60.0))
            next_publish = 0.0
            silent_since = None
            last_state = analyzer.state(time.monotonic())

            for block in iter_blocks(device, args.rate, args.block, 0.0):
                if self._stop_event.is_set():
                    break

                now = time.monotonic()
                state = analyzer.process(block, now)
                last_state = state

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
                    if next_publish <= now:
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

                self.reading.emit(
                    {
                        "level": state["level"],
                        "band_db": state["band_db"],
                        "beat": state["beat"],
                        "bpm": state["bpm"],
                        "rms_db": state["rms_db"],
                        "paused": paused,
                        "seq": publisher.seq,
                        "file_error": publisher.last_file_error,
                        "udp_error": publisher.last_udp_error,
                    }
                )

            # Финальный кадр: Lua не должен держать последний бас.
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
        except (Exception, SystemExit) as exc:
            self.failed.emit(str(exc))
        finally:
            if publisher is not None:
                publisher.close()
            if com_initialized:
                try:
                    import ctypes
                    ctypes.windll.ole32.CoUninitialize()
                except Exception:
                    pass


# ---------------------------------------------------------------------------
# Окно
# ---------------------------------------------------------------------------

class MusicWindow(QMainWindow):
    def __init__(self, args) -> None:
        super().__init__()
        self.args = args
        self.worker: CaptureWorker | None = None
        self._devices = []
        self._device_names: list[str] = []

        self.setWindowTitle("soulPilot — Music")
        self.setMinimumWidth(460)
        self._build_ui()
        self._reload_devices()
        self._restore_settings()

    # -- UI ---------------------------------------------------------------

    def _build_ui(self) -> None:
        central = QWidget(self)
        layout = QVBoxLayout(central)
        layout.setContentsMargins(14, 14, 14, 14)
        layout.setSpacing(10)

        layout.addWidget(QLabel("Устройство захвата (VB-Cable / monitor):"))
        row = QHBoxLayout()
        self.device_combo = QComboBox()
        self.device_combo.setMinimumWidth(300)
        row.addWidget(self.device_combo, 1)
        self.refresh_btn = QPushButton("Обновить")
        self.refresh_btn.clicked.connect(self._reload_devices)
        row.addWidget(self.refresh_btn)
        layout.addLayout(row)

        self.bass_bar = QProgressBar()
        self.bass_bar.setRange(0, 100)
        self.bass_bar.setValue(0)
        self.bass_bar.setFormat("Bass %p%")
        self.bass_bar.setMinimumHeight(22)
        layout.addWidget(self.bass_bar)

        self.beat_bar = QProgressBar()
        self.beat_bar.setRange(0, 100)
        self.beat_bar.setValue(0)
        self.beat_bar.setFormat("Beat %p%")
        self.beat_bar.setMinimumHeight(22)
        layout.addWidget(self.beat_bar)

        self.status = QLabel("Готов")
        self.status.setStyleSheet("font-size: 15px; font-weight: 600;")
        layout.addWidget(self.status)

        self.detail = QLabel("")
        self.detail.setStyleSheet("color: #666;")
        self.detail.setWordWrap(True)
        layout.addWidget(self.detail)

        buttons = QHBoxLayout()
        self.start_btn = QPushButton("Start")
        self.start_btn.setMinimumHeight(34)
        self.start_btn.clicked.connect(self.toggle_capture)
        buttons.addWidget(self.start_btn)
        layout.addLayout(buttons)

        self.setCentralWidget(central)

    # -- устройства/настройки --------------------------------------------

    def _reload_devices(self) -> None:
        current = self._current_device_name()
        try:
            self._devices = list(all_capture_devices())
        except (Exception, SystemExit) as exc:
            self._devices = []
            self.device_combo.clear()
            self.status.setText("Нет доступа к аудио: " + str(exc))
            return

        self.device_combo.blockSignals(True)
        self.device_combo.clear()
        self._device_names = [d.name for d in self._devices]
        counts: dict[str, int] = {}
        for i, dev in enumerate(self._devices):
            counts[dev.name] = counts.get(dev.name, 0) + 1
            label = dev.name if counts[dev.name] == 1 else f"{dev.name} [{i}]"
            self.device_combo.addItem(label, i)
        self.device_combo.blockSignals(False)

        if current:
            index = self._find_device_index(current)
            if index >= 0:
                self.device_combo.setCurrentIndex(index)
        if self.device_combo.currentIndex() < 0 and self._devices:
            default = default_capture_device(self._devices)
            if default is not None:
                idx = self._find_device_index(default.name)
                if idx >= 0:
                    self.device_combo.setCurrentIndex(idx)

    def _find_device_index(self, name: str) -> int:
        for i, dev_name in enumerate(self._device_names):
            if dev_name == name:
                return i
        return -1

    def _current_device_name(self) -> str | None:
        idx = self.device_combo.currentData()
        if idx is None:
            return None
        try:
            idx = int(idx)
        except (TypeError, ValueError):
            return None
        if 0 <= idx < len(self._device_names):
            return self._device_names[idx]
        return None

    def _restore_settings(self) -> None:
        settings = load_settings()
        name = settings.get("device")
        if isinstance(name, str) and name:
            idx = self._find_device_index(name)
            if idx >= 0:
                self.device_combo.setCurrentIndex(idx)

        # --device из командной строки важнее сохранённого
        cli = getattr(self.args, "device", None)
        if cli is not None and str(cli).strip():
            text = str(cli).strip()
            if text.isdigit():
                idx = int(text)
                if 0 <= idx < len(self._devices):
                    self.device_combo.setCurrentIndex(idx)
            else:
                idx = self._find_device_index(text)
                if idx < 0:
                    needle = text.casefold()
                    for i, dev_name in enumerate(self._device_names):
                        if needle in dev_name.casefold():
                            idx = i
                            break
                if idx >= 0:
                    self.device_combo.setCurrentIndex(idx)

    def _save_current_settings(self) -> None:
        name = self._current_device_name()
        if not name:
            return
        save_settings(
            {
                "device": name,
                "device_index": self.device_combo.currentData(),
            }
        )

    # -- Start/Stop -------------------------------------------------------

    def toggle_capture(self) -> None:
        if self.worker is not None and self.worker.isRunning():
            self._stop_capture()
        else:
            self._start_capture()

    def _start_capture(self) -> None:
        name = self._current_device_name()
        if not name:
            QMessageBox.warning(self, "soulPilot", "Не выбрано устройство захвата.")
            return

        self._save_current_settings()
        self.device_combo.setEnabled(False)
        self.refresh_btn.setEnabled(False)
        self.start_btn.setEnabled(False)
        self.start_btn.setText("Стоп")
        self.status.setText("Запуск…")
        self.detail.setText("")

        self.worker = CaptureWorker(name, self.device_combo.currentData(), self.args)
        self.worker.reading.connect(self._on_reading)
        self.worker.failed.connect(self._on_failed)
        self.worker.finished.connect(self._on_finished)
        self.worker.start()
        self.start_btn.setEnabled(True)

    def _stop_capture(self) -> None:
        if self.worker is None:
            return
        self.start_btn.setEnabled(False)
        self.status.setText("Остановка…")
        self.worker.stop()
        self.worker.wait(3000)

    def _on_reading(self, data: dict) -> None:
        self.bass_bar.setValue(int(round(float(data.get("level", 0.0)) * 100)))
        self.beat_bar.setValue(100 if data.get("beat") else 0)

        bpm = float(data.get("bpm", 0.0))
        self.status.setText(f"BPM {bpm:.0f}" if bpm > 0 else "BPM —")

        parts = [
            f"bass {float(data.get('level', 0.0)):.2f}",
            f"band {float(data.get('band_db', -120.0)):.1f} dB",
            f"seq {int(data.get('seq', 0))}",
        ]
        if data.get("paused"):
            parts.append("пауза")
        if data.get("file_error"):
            parts.append("FILE-ERR")
        if data.get("udp_error"):
            parts.append("UDP-ERR")
        self.detail.setText(" | ".join(parts))

    def _on_failed(self, message: str) -> None:
        self.status.setText("Ошибка")
        self.detail.setText(message)
        QMessageBox.critical(self, "soulPilot", message)

    def _on_finished(self) -> None:
        if self.worker is not None:
            self.worker.deleteLater()
            self.worker = None
        self.device_combo.setEnabled(True)
        self.refresh_btn.setEnabled(True)
        self.start_btn.setEnabled(True)
        self.start_btn.setText("Start")
        if self.status.text() not in ("Ошибка",):
            self.status.setText("Остановлено")

    # -- закрытие ---------------------------------------------------------

    def closeEvent(self, event) -> None:
        if self.worker is not None and self.worker.isRunning():
            self.worker.stop()
            self.worker.wait(3000)
        self._save_current_settings()
        super().closeEvent(event)


def run_ui(args) -> int:
    configure_stdout()
    app = QApplication.instance()
    owns_app = app is None
    if app is None:
        app = QApplication(sys.argv)
    app.setApplicationName("soulPilot Music")
    window = MusicWindow(args)
    window.show()
    if not owns_app:
        return 0
    return app.exec()


if __name__ == "__main__":
    # Автономный запуск: берём аргументы у main.py (без --console).
    from app import build_parser

    raise SystemExit(run_ui(build_parser().parse_args()))
