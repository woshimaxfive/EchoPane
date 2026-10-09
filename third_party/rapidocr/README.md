# RapidOCR native adapter

Source: [RapidAI/RapidOcrOnnx](https://github.com/RapidAI/RapidOcrOnnx), commit `675e73fe4c8b9e1d0be558bb5959a1b37696ed90`.
Only the inference sources are included. RapidOCR is Apache-2.0; embedded Clipper 6.4.2 is BSL-1.0 (see its source headers and `LICENSE-BOOST`).

Local changes: flat ONNX Runtime header paths, UTF-8 filesystem paths, CRLF dictionary handling, model/dictionary compatibility checks, disabled runtime telemetry, bounded logging, safe CTC output ranges and minimum crop width, and optional orientation-model loading. EchoPane disables orientation classification for horizontal screen text and keeps all inference in memory.

This adapter uses official ONNX Runtime 1.30.0 and OpenCV 4.13.0 distributions, verified by SHA-256. Models are downloaded separately and checked against the application's model manifest.
