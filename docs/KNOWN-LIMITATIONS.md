# Known Limitations

## 1. Touching or borderless panels can merge

Two panels connected by a shared stroke are one 8-connected ink component.
At the same time, a straight line inside one illustration may look like a
border, so splitting every long stroke would cut real panels in half. Deep mode
does not expose a second detector or a UI override for this ambiguity. See
[DETECTION.md → Touching or borderless panels](DETECTION.md#touching-or-borderless-panels).

## 2. OCR-based word lookup is approximate on comic lettering.

Touch-and-hold word lookup on CBZ/CBR relies on on-the-fly OCR over stylized
comic fonts, sound effects, and hand-lettering that Tesseract was never
tuned for — it will occasionally select the wrong word or fail to find one
at all, which is why the menu still marks it `[EXPERIMENTAL]`. See
[WORD-LOOKUP.md](WORD-LOOKUP.md) for how it works and
[WORD-LOOKUP.md → OCR debug review mode](WORD-LOOKUP.md#ocr-debug-review-mode)
for turning a bad lookup into a labeled example for future tuning.

## 3. A speech bubble crossing frames can join multiple panels

Deep mode groups ink with 8-connectivity. If a balloon or lettering physically
touches multiple panel frames in the reduced ink map, those regions can become
one connected component and yield one large bounding box. Page-level validation
may then keep the result as a full-page panel rather than risk omitting artwork.

<table align="center" width="80%">
  <tr>
    <td align="center" width="50%">
      <img src="../.github/limitation-dark-1.png" alt="Normal View" width="100%">
      <br>
      <sub>Normal View</sub>
    </td>
    <td align="center" width="50%">
      <img src="../.github/limitation-dark-2.png" alt="One big panel..." width="100%">
      <br>
      <sub>One big panel...</sub>
    </td>
  </tr>
</table>

**Why?** The component graph contains connectivity, not semantic labels. Once a
balloon bridges two frames, the flood fill cannot know that the bridge is
dialogue rather than part of a common panel boundary. A future improvement
would need evidence strong enough to cut those bridges without breaking real
artwork.

### When panels and dialogue are well separated
It works fine if the panels and speech bubbles have clear spacing between each other or they are encapsulated in their respective panels:

<p align="center">
  <img src="../.github/limitation-dark-ok-1.png" alt="Normal page (no plugin activated yet)" width="60%">
  <br>
  <sub>Normal page (no plugin activated yet)</sub>
</p>

<table align="center" width="95%">
  <tr>
    <td align="center" width="25%">
      <img src="../.github/limitation-dark-ok-2.png" alt="Panel 1" width="100%">
      <br>
      <sub>Panel 1</sub>
    </td>
    <td align="center" width="25%">
      <img src="../.github/limitation-dark-ok-3.png" alt="Panel 2" width="100%">
      <br>
      <sub>Panel 2</sub>
    </td>
    <td align="center" width="25%">
      <img src="../.github/limitation-dark-badorder-upsi.png" alt="Panel 3" width="100%">
      <br>
      <sub>Panel 3</sub>
    </td>
    <td align="center" width="25%">
      <img src="../.github/limitation-dark-ok-4.png" alt="Panel 4" width="100%">
      <br>
      <sub>Panel 4</sub>
    </td>
  </tr>
</table>

<p align="center">
  <sub>With plugin zooming</sub>
</p>

---
