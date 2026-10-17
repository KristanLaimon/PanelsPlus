# Text-based format regression dataset

This private/public hybrid dataset covers images embedded in EPUB, KEPUB, and
MOBI editions of *Bloom Into You*, volume 8. Pages 7, 8, and 11 were selected
because margin trimming in the converted editions used to make Panels+ group
their 2, 3, and 6 panels into one full-page panel.

Each format directory may contain its complete source book and additional
extracted images on a developer machine. `.gitignore` keeps those copyrighted
files local. Git allows only the first eight preview images (`00.png` through `07.png`), plus
metadata, annotations, and benchmark records, following the manga dataset rule.
These regression datasets currently contain three selected fixtures each;
`08.png` onward and complete source books remain ignored.

The stored rectangles are regression annotations for the converted assets.
They record the accepted component-detector output after it was checked against
the corresponding hand-annotated CBZ pages. They are intended to prevent the
embedded-image path from returning to the whole-page grouping failure.

Run the focused checks with:

```sh
lua tests/run_tests.lua tests/spec/textbasedformats_dataset_spec.lua
python3 -m unittest tests/test_textbasedformats_dataset.py
```

When the ignored source books are present, the Python check also verifies that
all three preview fixtures decode from those source containers.
