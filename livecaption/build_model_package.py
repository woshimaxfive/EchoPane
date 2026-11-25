"""Build an importable model ZIP from verified EchoPane model files."""

from argparse import ArgumentParser
from pathlib import Path
from tempfile import NamedTemporaryFile
from zipfile import ZIP_DEFLATED, ZipFile

from offline_model import MODEL_FILES, checked_model


LICENSES = Path(__file__).resolve().parent / "licenses"
NOTICE = (
    "SenseVoiceSmall by QwenAudio and FunASR, Alibaba Group.\n"
    "INT8 ONNX conversion by Fangjun Kuang and the sherpa-onnx project.\n"
    "https://k2-fsa.github.io/sherpa/onnx/sense-voice/pretrained.html\n\n"
    "Silero VAD by the Silero Team, 16 kHz ONNX export by sherpa-onnx.\n"
    "https://k2-fsa.github.io/sherpa/onnx/vad/silero-vad.html\n"
)


def main():
    parser = ArgumentParser(description=__doc__)
    parser.add_argument("model_directory", type=Path)
    parser.add_argument("output_zip", type=Path)
    args = parser.parse_args()
    models = checked_model(args.model_directory)
    output = args.output_zip
    output.parent.mkdir(parents=True, exist_ok=True)
    with NamedTemporaryFile(dir=output.parent, prefix=output.name + ".", suffix=".part", delete=False) as pending:
        staged = Path(pending.name)
        try:
            with ZipFile(pending, "w", compression=ZIP_DEFLATED, compresslevel=3) as package:
                for name, _, _, _ in MODEL_FILES:
                    package.write(models / name, name)
                for name in ("SenseVoiceSmall.txt", "Silero-VAD.txt"):
                    package.write(LICENSES / name, f"licenses/{name}")
                package.writestr("NOTICE.txt", NOTICE)
            pending.close()
            staged.replace(output)
        finally:
            pending.close()
            staged.unlink(missing_ok=True)
    print(output)


if __name__ == "__main__":
    main()
