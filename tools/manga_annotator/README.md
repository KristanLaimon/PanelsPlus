# Manga annotator panel editing

In **Panels** mode:

- **Ctrl+Tab** switches between Smart and Safe annotations for the current page.
- Hold **Ctrl when starting a canvas drag** to draw, move, or resize a panel in
  both mappings. You can release Ctrl after the drag starts. Shift snapping and
  Alt free positioning remain available.
- Hold **Ctrl while clicking Delete or Clear**, or pressing Delete, to remove
  panels from both mappings.
- Drag a panel's preview row up or down in the sidebar to change its reading
  order. Coordinates remain unchanged. New panels start at the end of the list;
  drag their rows to insert them anywhere in the sequence. The existing up/down
  buttons also work. Reordering affects the active mapping.
- **Undo/Redo** restores both mappings together for paired edits.

Paired movement, resizing, and deletion first find the original rectangle by its
coordinates in the other mapping. If no identical rectangle exists, they use
the same reading-order position. If that position is missing, movement or
resizing inserts the edited rectangle there. Other panels are preserved.

These controls apply only to panels. Phrases and words stay shared and retain
their existing editing behavior. Panel order and coordinates are saved in the
existing Smart/Safe JSON format; no database migration is needed.

Run the headless annotator tests from the repository root:

```sh
uv run python -m unittest tools.manga_annotator.test_annotator
```
