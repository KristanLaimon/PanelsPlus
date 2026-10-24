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

The **Copy Smart → Safe** / **Copy Safe → Smart** action replaces the destination
mapping for the whole book, preserving shared OCR and backing up the destination.
After copying, both canvas mappings reload so switching modes or saving retains
the copied panels. Copying clears the canvas undo history; the pre-copy destination
is preserved in the backup named by the confirmation message.

Run the headless annotator tests from the repository root:

```sh
uv run python -m unittest tools.manga_annotator.test_annotator
```

## Import and manhwa

Use **Search System for Comic File** for CBZ, CBR, ZIP, 7z, PDF and supported
ebooks, or **Import Folder** for images. Folders can contain numbered volume
subfolders: paths sort naturally (`vol_2/02.jpg` before `vol_10/00.jpg`). They
import as one book, with images copied into the dataset as numbered PNGs.
RAR/CBR and 7z extraction requires a compatible installed extractor (`bsdtar`,
`7zz`, `7z`, or `unrar` for RAR). Import into a new book name; existing book
folders are protected from overwrite and cancellation cleanup.

Choose **Manhwa (vertical cascade)** during import. For an existing book, open
it and choose **File → Change Book Type → manhwa**. Overgeared is configured as
manhwa already. Images appear directly below each other at native size, aligned
on the left; different widths are preserved. Only visible images are decoded
for painting, with a four-page LRU pixmap cache. Page lookup uses the visible
vertical interval, and offscreen annotation rectangles are skipped when painting.

Sidebar thumbnails load only for visible rows, one row per event-loop turn.
A separate cache holds up to 32 reduced page images and 512 panel thumbnails;
preview generation does not evict viewport images. Existing previews are reused
when editing or reordering panels. Saving writes annotations immediately and
refreshes Library cards when returning to that tab, avoiding cover decoding in
the save path.

- **A / D** smoothly pan up / down by half the viewport. Repeated presses extend
  the pan; movement stops at the beginning and end of the strip.
- The page slider and number field jump to source-page boundaries.
- Page boundaries have subtle edge ticks and a small `p1 / p2` label; the
  artwork between the edge markers stays unobstructed.
- Keep holding the left mouse button while drawing or resizing an existing
  panel and press **D / A** to pan.
  The starting corner or opposite resize edge stays anchored while the endpoint follows
  the cursor through the pan. Release to finish the panel; Esc cancels it.
- Draw, move and resize panels across any page seam. Smart/Safe mappings,
  paired Ctrl edits, undo/redo, and thumbnails work across seams.

Source files remain separate. Each rectangle is saved once in the annotation
for the page containing its top edge, in that page's native coordinates. Its
height may extend past that page into subsequent images. Switching back to
Manhwa reconstructs the complete rectangle. Reading order is retained within
each source page. Consumers of these mappings must account for overflow to
interpret seam-spanning rectangles; the KOReader runtime is unchanged.

In continuous mode, **F** or **Shift+F** makes the source page at the cursor’s
vertical position (including the side gutters) one
full-page panel. This replaces panels whose top edge belongs to that page in
the active Smart/Safe mapping; panels on other pages, the other mapping, and
shared OCR are preserved. The **Full Source Page** button (or its Edit menu
item) uses the page number in the navigation controls when the pointer is
outside the artwork. It records `illustration_type: "single_page"` in the
page's dataset annotations, with `(0, 0, source_width, source_height)` coordinates.
Undo/redo restores the replaced panels. The shortcut is available only for
manhwa books. In manhwa mode, F targets a source page rather than the whole strip. The S
whole-image shortcut and wordless shortcut remain unavailable; existing per-page markers are preserved. Precision snapping to other rectangles remains available;
pixel-based ink snapping requires the individual-page view.

Run both annotator suites:

```sh
uv run python -m unittest tools.manga_annotator.test_annotator tools.manga_annotator.test_manhwa
```
