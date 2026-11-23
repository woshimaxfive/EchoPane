"""Local OCR for pixels selected in the screen workspace."""

from pathlib import Path


MODEL_HASHES = {
    "PP-OCRv6_det_small.onnx": "090f04abcd9d9a7498bc4ebf677e4cb9bdce1fe4197ddb7e529f1ef44e1ff94f",
    "PP-OCRv6_rec_small.onnx": "6f327246b50388f3c176ae304bd95767ea6dc0c9ae92153ef8cbe210b3c14884",
}
engine = None


def recognize(pixels):
    global engine
    if engine is None:
        from rapidocr import RapidOCR
        import rapidocr

        models = Path(rapidocr.__file__).parent / "models"
        detector, recognizer = (models / name for name in MODEL_HASHES)
        if not detector.is_file() or not recognizer.is_file():
            raise FileNotFoundError("RapidOCR model files are missing.")
        engine = RapidOCR(params={
            "Det.model_path": str(detector),
            "Rec.model_path": str(recognizer),
            "Global.use_cls": False,
            "Global.log_level": "error",
            "Det.limit_type": "max",
            "EngineConfig.onnxruntime.intra_op_num_threads": 3,
            "EngineConfig.onnxruntime.inter_op_num_threads": 1,
        })
    result = engine(pixels)
    return "\n".join(result.txts or ())
