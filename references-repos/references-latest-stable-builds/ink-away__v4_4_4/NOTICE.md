# Notices

Ink Away is original code, released under the MIT License (see `LICENSE`).

## Runtime

Ink Away runs inside [KOReader](https://github.com/koreader/koreader) and uses
KOReader's own APIs at runtime, including its FFI wrappers around
[lodepng](https://github.com/lvandeve/lodepng) (PNG encoding) and
[libjpeg-turbo](https://github.com/libjpeg-turbo/libjpeg-turbo) (JPEG encoding).
Those libraries are provided by KOReader and are not bundled with this plugin.

## Acknowledgements

The pen slot handling in `ink/penbridge.lua` follows the approach of
[Notebook](https://github.com/pierspad/notebook.koplugin) by pierspad (MIT
License), which showed that giving the Wacom pen and the touch panel their own
slot cursors is what keeps palm rejection reliable on the Kindle Scribe, and that
the digitizer's current pressure can be read directly (an EVIOCGABS ioctl) on
firmwares that send no pressure events. The code here is written independently.

## Handwriting recognition

`ink/data/hwr_en.bin` is a small neural network trained by the author to read
handwritten characters (the training code is a separate project). It was
trained on:

- EMNIST (Cohen, Afshar, Tapson and van Schaik, 2017), derived from NIST
  Special Database 19, a work of the U.S. government.
- UJI Pen Characters, version 2 (Prat, Castro, Llorens, Marzal and Vilar,
  Universitat Jaume I, 2008), from the UCI Machine Learning Repository,
  licensed under Creative Commons Attribution 4.0
  (https://creativecommons.org/licenses/by/4.0/). `tests/hwr_vectors.lua`
  holds a few of its strokes.

`ink/data/hwr_words_en.txt` is taken from SCOWL (Spell Checker Oriented Word
Lists, http://wordlist.aspell.net), levels 10 to 40, American and British
spellings, plain lower-case words only. Its notice:

> Copyright 2000-2018 by Kevin Atkinson
>
> Permission to use, copy, modify, distribute and sell these word lists, the
> associated scripts, the output created from the scripts, and its
> documentation for any purpose is hereby granted without fee, provided that
> the above copyright notice appears in all copies and that both that
> copyright notice and this permission notice appear in supporting
> documentation. Kevin Atkinson makes no representations about the
> suitability of this array for any purpose. It is provided "as is" without
> express or implied warranty.

SCOWL also includes material from the Moby Words II lists (public domain), the
12Dicts package by Alan Beale and other sources credited in SCOWL's own
Copyright file.

