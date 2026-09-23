# Optional English OCR model

`eng_fast.traineddata` is the unmodified English model from
[tesseract-ocr/tessdata_fast](https://github.com/tesseract-ocr/tessdata_fast),
downloaded on 2026-09-22 from
<https://raw.githubusercontent.com/tesseract-ocr/tessdata_fast/main/eng.traineddata>.
It is distributed under the accompanying Apache-2.0 [LICENSE](LICENSE).

- Size: 4,113,088 bytes (3.92 MiB).
- SHA-256: `7d4322bd2a7749724879683fc3912cb542f19906c83bcc1a52132556427170b2`.
- Renamed to `eng_fast` because KOReader's k2pdfopt OCR engine caches models
  by language name, without checking the data directory. The contents are unchanged.

Enable **Panels+ → Lightweight English OCR** and open a panel. This model is
used only for panel word lookup when the document OCR language is `eng`.
Other languages and combinations such as `eng+spa` retain the configured model.
The option is off by default. KOReader's installed language files are not changed.
Missing bundled data uses the installed English model; a failed native OCR
call falls back to KOReader's document OCR.

This is a general English model, not a manga-trained model. It uses the existing
KOReader Tesseract runtime, with no extra executable, network service, or GPU.
See [OCR_REPORT.md](../../OCR_REPORT.md) for measured accuracy and device limits.
