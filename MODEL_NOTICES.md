# Local OCR models

EchoPane uses the PaddleOCR PP-OCRv5 **mobile** text detector and recognizer, converted to ONNX by RapidAI. The default model reads Chinese, English and Japanese without selecting a separate recognition model; this is not a language-identification service. Horizontal text is the initial target. Vertical and rotated text require further validation.

Original project: [PaddlePaddle/PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR), Apache-2.0. Conversion and manifest: [RapidAI/RapidOCR](https://github.com/RapidAI/RapidOCR/blob/0700743fc8bfb3943cd8e40e84547f14c7d15dfc/python/rapidocr/default_models.yaml), Apache-2.0. License texts are in `third_party/licenses/`.

The app downloads models only when the user chooses **下载模型**. Files are stored in `%LOCALAPPDATA%/EchoPane/models/ppocrv5-mobile/`, outside the application and Git repository. The transfer contacts ModelScope; screen images and recognized text are not included in download requests. Each file is checked for exact size and SHA-256 before use. A matching local cache can be used offline.

Pinned download base: `https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/`.

| Local file | Upstream path | Bytes | SHA-256 |
| --- | --- | ---: | --- |
| det.onnx | onnx/PP-OCRv5/det/ch_PP-OCRv5_det_mobile.onnx | 4,819,576 | 4d97c44a20d30a81aad087d6a396b08f786c4635742afc391f6621f5c6ae78ae |
| rec.onnx | onnx/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile.onnx | 16,631,306 | 5825fc7ebf84ae7a412be049820b4d86d77620f204a041697b0494669b1742c5 |
| keys.txt | paddle/PP-OCRv5/rec/ch_PP-OCRv5_rec_mobile/ppocrv5_dict.txt | 74,012 | d1979e9f794c464c0d2e0b70a7fe14dd978e9dc644c0e71f14158cdf8342af1b |

Total: 21,524,894 bytes. The dictionary must match the recognizer; mixing model versions can produce incorrect text. Model accuracy varies with font, scale, contrast, motion and layout. A confidence score is an engine estimate, not a correctness guarantee.
