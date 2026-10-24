#!/usr/bin/env python3
"""AutopilotLive: публикация аудио-состояния для BeamNG.

Пишет JSON атомарно (temp + os.replace) и, опционально, отправляет тот же
JSON по UDP. Не зависит от ОС и от аудио-библиотек.

Формат (пример):
    {"seq":1234,"t":1761400000123,"bass":0.62,"bass_db":-18.4,
     "beat":1,"bpm":124.0,"rms":0.21,"rms_db":-13.5,"paused":false}

Lua-сторона читает файл каждые 50 мс; UDP (127.0.0.1:7771) — для отладки
и внешних потребителей.
"""
from __future__ import annotations

import json
import os
import socket
import threading
import time
from pathlib import Path
from typing import Any, Optional


class Publisher:
    """Атомарная запись JSON + UDP-отправка. Потокобезопасен."""

    def __init__(
        self,
        path: str | os.PathLike,
        udp_host: str = "127.0.0.1",
        udp_port: int = 7771,
        udp_enabled: bool = True,
        file_enabled: bool = True,
    ) -> None:
        self.path = Path(path)
        self.udp_host = str(udp_host)
        self.udp_port = int(udp_port)
        self.udp_enabled = bool(udp_enabled)
        self.file_enabled = bool(file_enabled)

        self.last_file_error: Optional[str] = None
        self.last_udp_error: Optional[str] = None
        self._seq = 0
        self._lock = threading.Lock()

        if self.file_enabled:
            self.path.parent.mkdir(parents=True, exist_ok=True)

        self._udp_sock: Optional[socket.socket] = None
        if self.udp_enabled:
            try:
                self._udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
                self._udp_sock.setblocking(False)
            except OSError as exc:
                self.last_udp_error = f"socket: {exc}"
                self._udp_sock = None

    # -- запись ------------------------------------------------------------

    def _write_atomic(self, data: bytes) -> None:
        """temp в том же каталоге -> os.replace (атомарно в пределах ФС)."""
        # Уникальный temp: несколько процессов не мешают друг другу.
        tmp = self.path.with_name(f"{self.path.name}.tmp.{os.getpid()}")
        try:
            with open(tmp, "wb") as handle:
                handle.write(data)
                handle.flush()
                # fsync не делаем: 20 Гц, а целостность обеспечивает
                # атомарный os.replace (Lua видит либо старый, либо новый файл).
        except OSError as exc:
            self.last_file_error = f"write: {exc}"
            self._safe_unlink(tmp)
            return

        # Windows: Lua может на мгновение держать файл открытым (fopen без
        # FILE_SHARE_DELETE), поэтому os.replace иногда получает PermissionError.
        # Пропуск обновления безопасен: Lua увидит прошлый валидный кадр.
        for attempt in range(8):
            try:
                os.replace(tmp, self.path)
                self.last_file_error = None
                return
            except PermissionError as exc:
                if attempt == 7:
                    self.last_file_error = f"replace: {exc}"
                    self._safe_unlink(tmp)
                    return
                time.sleep(0.002)
            except OSError as exc:
                self.last_file_error = f"replace: {exc}"
                self._safe_unlink(tmp)
                return

    @staticmethod
    def _safe_unlink(path: Path) -> None:
        try:
            path.unlink()
        except OSError:
            pass

    # -- публикация --------------------------------------------------------

    def publish(self, payload: dict[str, Any], timestamp_ms: Optional[int] = None) -> dict[str, Any]:
        """Добавляет seq/t, пишет файл и отправляет UDP. Возвращает документ."""
        with self._lock:
            self._seq += 1
            document = dict(payload)
            document["seq"] = self._seq
            document["t"] = int(timestamp_ms if timestamp_ms is not None else time.time() * 1000)

        data = json.dumps(
            document,
            ensure_ascii=False,
            separators=(",", ":"),
        ).encode("utf-8")

        if self.file_enabled:
            self._write_atomic(data)

        if self._udp_sock is not None:
            try:
                self._udp_sock.sendto(data, (self.udp_host, self.udp_port))
                self.last_udp_error = None
            except OSError as exc:
                # UDP не критичен: слушателя может не быть / буфер заполнен.
                self.last_udp_error = str(exc)

        return document

    def close(self) -> None:
        """Закрывает UDP-сокет."""
        with self._lock:
            if self._udp_sock is not None:
                try:
                    self._udp_sock.close()
                except OSError:
                    pass
                self._udp_sock = None

    def __enter__(self) -> "Publisher":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()


def read_state(path: str | os.PathLike) -> Optional[dict[str, Any]]:
    """Читает опубликованный JSON (для отладки/тестов). None при ошибке."""
    try:
        with open(path, "r", encoding="utf-8") as handle:
            data = json.load(handle)
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None
