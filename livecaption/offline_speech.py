"""Adapt the local recognizer to EchoPane's existing caption events."""

import ctypes
import sys
import time
from pathlib import Path

import numpy as np

from capture import pcm_level
from cloud import CaptionUpdate
from offline_model import checked_model


SAMPLE_RATE = 16_000
HISTORY_SAMPLES = 16 * SAMPLE_RATE
PREFIX_SAMPLES = round(0.6 * SAMPLE_RATE)


class LocalRecognizer:
    def __init__(self, directory):
        import onnxruntime

        # Load the same runtime used by OCR before importing the native binding.
        package = Path(onnxruntime.__file__).parent
        if getattr(sys, "frozen", False):
            package = Path(sys.executable).parent / "lib" / "onnxruntime"
        runtime = package / "capi" / "onnxruntime.dll"
        self.runtime = ctypes.CDLL(str(runtime))
        import sherpa_onnx

        config = sherpa_onnx.VadModelConfig()
        config.sample_rate = SAMPLE_RATE
        config.num_threads = 1
        config.silero_vad.model = str(directory / "silero_vad.onnx")
        config.silero_vad.min_speech_duration = 0.18
        config.silero_vad.min_silence_duration = 0.38
        config.silero_vad.max_speech_duration = 5
        config.silero_vad.threshold = 0.48
        self.vad = sherpa_onnx.VoiceActivityDetector(config, buffer_size_in_seconds=32)
        self.engine = sherpa_onnx.OfflineRecognizer.from_sense_voice(
            model=str(directory / "model.int8.onnx"), tokens=str(directory / "tokens.txt"),
            language="auto", use_itn=True, provider="cpu", num_threads=3,
        )
        self.history = sherpa_onnx.CircularBuffer(HISTORY_SAMPLES)
        self.previous_end = 0

    def accept(self, pcm, *, final=False):
        if pcm:
            samples = np.frombuffer(pcm, dtype="<i2").astype(np.float32) / 32768
            overflow = self.history.size + len(samples) - HISTORY_SAMPLES
            if overflow > 0:
                self.history.pop(overflow)
            self.history.push(samples)
            self.vad.accept_waveform(samples)
        if final:
            self.vad.flush()
        while not self.vad.empty():
            spoken = self.vad.front
            start = spoken.start
            samples = spoken.samples
            prefix = max(self.previous_end, self.history.head, start - PREFIX_SAMPLES)
            if prefix < start:
                samples = np.concatenate((self.history.get(prefix, start - prefix), samples))
            self.previous_end = start + len(spoken.samples)
            self.vad.pop()
            stream = self.engine.create_stream()
            stream.accept_waveform(SAMPLE_RATE, samples)
            self.engine.decode_stream(stream)
            if text := stream.result.text.strip():
                yield start, self.previous_end, text


def run_local(open_source, stop, emit):
    error = ""
    try:
        model = checked_model()
        if stop.is_set():
            return
        engine = LocalRecognizer(model)
        if stop.is_set():
            return
        with open_source() as source:
            emit("status", "本地模型已就绪。等待所选音源发声。")
            next_level = time.monotonic()
            meter = bytearray()
            while not stop.is_set():
                pcm = source.read()
                if pcm:
                    meter.extend(pcm)
                    for start, _, text in engine.accept(pcm):
                        emit("caption", CaptionUpdate(f"local-{start}", text, True))
                now = time.monotonic()
                if now >= next_level:
                    emit("level", pcm_level(meter))
                    meter.clear()
                    next_level = now + 0.12
                stop.wait(0.012)
            tail = source.read(last=True)
        for start, _, text in engine.accept(tail, final=True):
            emit("caption", CaptionUpdate(f"local-{start}", text, True))
    except (ImportError, OSError):
        error = "无法加载本地字幕组件，请修复模型或重新安装 EchoPane。"
    except RuntimeError as exc:
        error = str(exc)[:160] or "本地字幕中断，请重新开始。"
    except Exception:
        error = "本地字幕中断，请重新开始。"
    finally:
        emit("end", error)
