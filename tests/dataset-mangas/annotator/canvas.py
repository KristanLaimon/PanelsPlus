"""
Interactive annotation canvas for manga pages using PyQt6.
Supports drawing sequential panels, dragging, resizing via 8 handles,
zoom/pan, number badges, and full-page panel shortcuts.
"""

from typing import List, Optional, Tuple
import math
from PyQt6.QtCore import Qt, QRect, QRectF, QPoint, QPointF, pyqtSignal
from PyQt6.QtGui import (
    QPainter, QPen, QBrush, QColor, QFont, QPixmap, QImage, QCursor,
    QPaintEvent, QMouseEvent, QWheelEvent, QKeyEvent, QFontMetrics
)
from PyQt6.QtWidgets import QWidget

from .dataset_manager import Panel, PhraseRect, WordRect

HANDLE_SIZE = 8
MIN_BOX_SIZE = 8

# Handle positions
HANDLE_NONE = 0
HANDLE_TL = 1
HANDLE_T = 2
HANDLE_TR = 3
HANDLE_R = 4
HANDLE_BR = 5
HANDLE_B = 6
HANDLE_BL = 7
HANDLE_L = 8
HANDLE_MOVE = 9


class MangaCanvas(QWidget):
    """Interactive canvas widget displaying the page image and bounding box annotations."""

    # Signals
    panels_changed = pyqtSignal()
    panel_selected = pyqtSignal(int)  # index of selected panel, or -1
    status_message = pyqtSignal(str)
    cursor_position = pyqtSignal(int, int)  # (native_x, native_y)
    precision_mode_changed = pyqtSignal(bool)
    zoom_changed = pyqtSignal(float)
    single_page_illustration_requested = pyqtSignal()
    double_page_illustration_requested = pyqtSignal()
    annotation_mode_changed = pyqtSignal(str)
    phrase_id_changed = pyqtSignal(int)
    phrase_text_requested = pyqtSignal(int)
    word_text_requested = pyqtSignal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self.setMouseTracking(True)
        self.setFocusPolicy(Qt.FocusPolicy.StrongFocus)

        self._pixmap: Optional[QPixmap] = None
        self.native_w = 0
        self.native_h = 0
        self.annotation_mode = "panel"
        self.current_phrase_id = 1
        self.phrase_auto_advance_distance = 120
        self._collections = {"panel": [], "phrase": [], "word": []}
        # Kept as an active-list alias for compatibility with the existing editor code.
        self.panels: List[Panel] = self._collections["panel"]
        self.selected_panel_index = -1

        # View transform
        self.zoom_factor = 1.0
        self.offset_x = 0.0
        self.offset_y = 0.0
        self._pending_fit_width = False

        # Precision fine-tuning & Loupe HUD
        self.precision_mouse_enabled = True
        self._current_image_box: Optional[Tuple[int, int, int, int]] = None
        self._active_ix = 0
        self._active_iy = 0
        self._snap_guide_x: Optional[int] = None
        self._snap_guide_y: Optional[int] = None
        self._gray_image: Optional[QImage] = None
        self._gray_bytes: Optional[bytes] = None
        self._bpl: int = 0

        # Undo / Redo history stacks
        self._undo_stack: List[List[Panel]] = []
        self._redo_stack: List[List[Panel]] = []
        self._panels_at_drag_start: List[Panel] = []

        # Interaction state
        self._mode = "idle"  # "idle", "drawing", "resizing", "moving", "panning"
        self._drag_start_pos: Optional[QPoint] = None
        self._drag_start_image_x = 0
        self._drag_start_image_y = 0
        self._current_mouse_pos: Optional[QPoint] = None
        self._active_handle = HANDLE_NONE
        self._panel_before_drag: Optional[Panel] = None
        self._space_pressed = False
        self._pan_start_pos: Optional[QPoint] = None

    def get_panels(self) -> List[Panel]:
        return self._collections["panel"]

    def get_phrases(self) -> List[PhraseRect]:
        return self._collections["phrase"]

    def get_words(self) -> List[WordRect]:
        return self._collections["word"]

    def set_annotation_mode(self, mode: str):
        if mode not in self._collections or mode == self.annotation_mode:
            return
        self.annotation_mode = mode
        self.panels = self._collections[mode]
        self.selected_panel_index = -1
        self._mode = "idle"
        self._undo_stack.clear()
        self._redo_stack.clear()
        self.panel_selected.emit(-1)
        self.annotation_mode_changed.emit(mode)
        self.status_message.emit(f"Rectangle mode: {mode.title()}")
        self.update()

    def step_phrase_id(self, delta: int):
        if self.annotation_mode != "phrase":
            return
        self.current_phrase_id = max(1, self.current_phrase_id + (1 if delta > 0 else -1))
        self.phrase_id_changed.emit(self.current_phrase_id)
        self.status_message.emit(f"Current phrase ID: {self.current_phrase_id}")
        self.update()

    def set_phrase_auto_advance_distance(self, distance: int):
        self.phrase_auto_advance_distance = max(0, int(distance))

    @staticmethod
    def _rectangle_edge_distance(a: Panel, b: Panel) -> float:
        """Shortest Euclidean distance between rectangle edges (zero on overlap/touch)."""
        dx = max(a.x - (b.x + b.w), b.x - (a.x + a.w), 0)
        dy = max(a.y - (b.y + b.h), b.y - (a.y + a.h), 0)
        return math.hypot(dx, dy)

    def _auto_advance_phrase_id_for(self, rectangle: Panel) -> None:
        current_fragments = [
            phrase
            for phrase in self.get_phrases()
            if phrase.phrase_id == self.current_phrase_id
        ]
        if not current_fragments:
            return
        nearest_distance = min(
            self._rectangle_edge_distance(rectangle, phrase)
            for phrase in current_fragments
        )
        if nearest_distance > self.phrase_auto_advance_distance:
            self.current_phrase_id += 1
            self.phrase_id_changed.emit(self.current_phrase_id)
            self.status_message.emit(
                f"Started phrase ID {self.current_phrase_id} "
                f"({nearest_distance:.0f}px from previous phrase)"
            )

    def set_word_text(self, index: int, text: str) -> bool:
        words = self.get_words()
        if not (0 <= index < len(words)) or not text.strip():
            return False
        words[index].text = text.strip()
        self.panels_changed.emit()
        self.update()
        return True

    def set_phrase_text(self, index: int, text: str) -> bool:
        phrases = self.get_phrases()
        if not (0 <= index < len(phrases)) or not text.strip():
            return False
        phrase_id = phrases[index].phrase_id
        for phrase in phrases:
            if phrase.phrase_id == phrase_id:
                phrase.text = text.strip()
        self.panels_changed.emit()
        self.update()
        return True

    def discard_phrase(self, index: int) -> None:
        phrases = self.get_phrases()
        if 0 <= index < len(phrases):
            phrases.pop(index)
        self.refresh_word_assignments()
        if self.annotation_mode == "phrase":
            self.selected_panel_index = min(self.selected_panel_index, len(phrases) - 1)
            self.panel_selected.emit(self.selected_panel_index)
        self.update()

    def discard_word(self, index: int) -> None:
        words = self.get_words()
        if 0 <= index < len(words):
            words.pop(index)
        if self.annotation_mode == "word":
            self.selected_panel_index = min(self.selected_panel_index, len(words) - 1)
            self.panel_selected.emit(self.selected_panel_index)
        self.update()

    @staticmethod
    def _intersection_area(a: Panel, b: Panel) -> int:
        return max(0, min(a.x + a.w, b.x + b.w) - max(a.x, b.x)) * max(
            0, min(a.y + a.h, b.y + b.h) - max(a.y, b.y)
        )

    def refresh_word_assignments(self):
        """Assign each word to the phrase ID with which it overlaps most."""
        phrases = self.get_phrases()
        for word in self.get_words():
            candidates = [(self._intersection_area(word, phrase), phrase.phrase_id) for phrase in phrases]
            candidates = [candidate for candidate in candidates if candidate[0] > 0]
            word.phrase_id = max(candidates, default=(0, None))[1]

    def _update_hover_cursor(self, pos: Optional[QPoint] = None):
        """Set the appropriate visible mouse cursor based on hit test or mode."""
        if self._space_pressed or self._mode == "panning":
            self.setCursor(QCursor(Qt.CursorShape.ClosedHandCursor if self._mode == "panning" else Qt.CursorShape.OpenHandCursor))
            return

        if pos is None:
            pos = self.mapFromGlobal(QCursor.pos())

        handle, _ = self._hit_test(pos)
        if handle in (HANDLE_TL, HANDLE_BR):
            self.setCursor(QCursor(Qt.CursorShape.SizeFDiagCursor))
        elif handle in (HANDLE_TR, HANDLE_BL):
            self.setCursor(QCursor(Qt.CursorShape.SizeBDiagCursor))
        elif handle in (HANDLE_T, HANDLE_B):
            self.setCursor(QCursor(Qt.CursorShape.SizeVerCursor))
        elif handle in (HANDLE_L, HANDLE_R):
            self.setCursor(QCursor(Qt.CursorShape.SizeHorCursor))
        elif handle == HANDLE_MOVE:
            self.setCursor(QCursor(Qt.CursorShape.SizeAllCursor))
        else:
            self.setCursor(QCursor(Qt.CursorShape.ArrowCursor))

    def set_precision_mode(self, enabled: bool):
        """Enable or disable magnetic snap mode."""
        self.precision_mouse_enabled = bool(enabled)
        self._update_hover_cursor()
        self.precision_mode_changed.emit(self.precision_mouse_enabled)
        state_str = "ON" if self.precision_mouse_enabled else "OFF"
        self.status_message.emit(f"Precision mode: {state_str}")
        self.update()

    def enterEvent(self, event):
        super().enterEvent(event)
        self._update_hover_cursor()

    def leaveEvent(self, event):
        super().leaveEvent(event)
        self.setCursor(QCursor(Qt.CursorShape.ArrowCursor))
        self.update()

    def push_undo(self):
        """Save current panels state to undo stack and clear redo stack."""
        self._undo_stack.append([p.copy() for p in self.panels])
        if len(self._undo_stack) > 50:
            self._undo_stack.pop(0)
        self._redo_stack.clear()

    def undo(self):
        """Revert to previous panels state."""
        if not self._undo_stack:
            return
        self._redo_stack.append([p.copy() for p in self.panels])
        self.panels = self._undo_stack.pop()
        self._collections[self.annotation_mode] = self.panels
        if self.annotation_mode in ("phrase", "word"):
            self.refresh_word_assignments()
        self.selected_panel_index = min(self.selected_panel_index, len(self.panels) - 1)
        self.panels_changed.emit()
        self.panel_selected.emit(self.selected_panel_index)
        self.update()
        self.status_message.emit("Undo performed.")

    def redo(self):
        """Reapply previously undone panels state."""
        if not self._redo_stack:
            return
        self._undo_stack.append([p.copy() for p in self.panels])
        self.panels = self._redo_stack.pop()
        self._collections[self.annotation_mode] = self.panels
        if self.annotation_mode in ("phrase", "word"):
            self.refresh_word_assignments()
        self.selected_panel_index = min(self.selected_panel_index, len(self.panels) - 1)
        self.panels_changed.emit()
        self.panel_selected.emit(self.selected_panel_index)
        self.update()
        self.status_message.emit("Redo performed.")

    def set_page(
        self,
        pixmap: Optional[QPixmap],
        panels: List[Panel],
        phrases: Optional[List[PhraseRect]] = None,
        words: Optional[List[WordRect]] = None,
        fit_width: bool = False,
    ):
        """Update current page pixmap and panels."""
        self._pixmap = pixmap
        if pixmap and not pixmap.isNull():
            self.native_w = pixmap.width()
            self.native_h = pixmap.height()
            try:
                self._gray_image = pixmap.toImage().convertToFormat(QImage.Format.Format_Grayscale8)
                self._gray_bytes = self._gray_image.constBits().asstring(self._gray_image.sizeInBytes())
                self._bpl = self._gray_image.bytesPerLine()
            except Exception:
                self._gray_image = None
                self._gray_bytes = None
                self._bpl = 0
        else:
            self.native_w = 0
            self.native_h = 0
            self._gray_image = None
            self._gray_bytes = None
            self._bpl = 0

        self._collections = {
            "panel": [p.copy() for p in panels],
            "phrase": [p.copy() for p in (phrases or [])],
            "word": [w.copy() for w in (words or [])],
        }
        self.panels = self._collections[self.annotation_mode]
        phrase_ids = [p.phrase_id for p in self.get_phrases()]
        self.current_phrase_id = min(phrase_ids) if phrase_ids else 1
        self.refresh_word_assignments()
        self.phrase_id_changed.emit(self.current_phrase_id)
        self.selected_panel_index = -1
        self._mode = "idle"
        self._undo_stack.clear()
        self._redo_stack.clear()
        if fit_width or self._pending_fit_width:
            self.fit_to_width(self.rect())
        self.update()

    def resizeEvent(self, event):
        super().resizeEvent(event)
        if getattr(self, "_pending_fit_width", False) and self.native_w > 0:
            self.fit_to_width(self.rect())

    def set_zoom(self, zoom: float):
        """Set zoom factor clamped between 0.05 and 10.0."""
        self.zoom_factor = max(0.05, min(10.0, float(zoom)))
        self.zoom_changed.emit(self.zoom_factor)
        self.update()

    def fit_to_window(self, view_rect: QRect):
        """Scale image to fit entirely inside view_rect while preserving aspect ratio."""
        if self.native_w == 0 or self.native_h == 0:
            return
        scale_w = view_rect.width() / self.native_w
        scale_h = view_rect.height() / self.native_h
        new_zoom = min(scale_w, scale_h) * 0.95
        self.zoom_factor = max(0.05, min(10.0, new_zoom))
        self.offset_x = max(0.0, (view_rect.width() - self.native_w * self.zoom_factor) / 2.0)
        self.offset_y = max(0.0, (view_rect.height() - self.native_h * self.zoom_factor) / 2.0)
        self.zoom_changed.emit(self.zoom_factor)
        self.update()

    def fit_to_width(self, view_rect: Optional[QRect] = None):
        """Scale image so its width fills 100% of the renderer container."""
        rect = view_rect if (view_rect and view_rect.width() > 10) else self.rect()
        if self.native_w == 0 or rect.width() <= 10:
            self._pending_fit_width = True
            return
        new_zoom = float(rect.width()) / float(self.native_w)
        self.zoom_factor = max(0.05, min(10.0, new_zoom))
        self.offset_x = 0.0
        self.offset_y = 0.0
        self._pending_fit_width = False
        self.zoom_changed.emit(self.zoom_factor)
        self.update()

    def _find_horizontal_ink_border(self, ix: int, iy: int, search_r: int, side: str = "auto") -> Optional[int]:
        """Find horizontal black panel border within search_r and return coordinate OUTSIDE the border."""
        if not self._gray_bytes or self.native_w == 0 or self.native_h == 0:
            return None

        h, w = self.native_h, self.native_w
        bpl = self._bpl
        buf = self._gray_bytes

        y_min = max(0, iy - search_r)
        y_max = min(h - 1, iy + search_r)
        x_min = max(0, ix - 15)
        x_max = min(w - 1, ix + 15)
        span_len = x_max - x_min + 1
        if span_len < 10:
            return None

        dark_rows = []
        for y in range(y_min, y_max + 1):
            row_offset = y * bpl + x_min
            dark_count = 0
            for x in range(span_len):
                if buf[row_offset + x] < 110:
                    dark_count += 1
            if dark_count >= span_len * 0.5:
                dark_rows.append(y)

        if not dark_rows:
            return None

        # Group contiguous dark rows into stroke blocks
        blocks = []
        curr = [dark_rows[0]]
        for r in dark_rows[1:]:
            if r == curr[-1] + 1:
                curr.append(r)
            else:
                blocks.append(curr)
                curr = [r]
        blocks.append(curr)

        best_block = min(blocks, key=lambda b: abs((b[0] + b[-1]) / 2.0 - iy))
        y_top = best_block[0]
        y_bottom = best_block[-1]

        if side == "bottom":
            # Outside bottom border: just below the black stroke (in the gutter)
            return min(h, y_bottom + 1)
        elif side == "top":
            # Outside top border: just above the black stroke (in the gutter)
            return max(0, y_top)
        else:
            # Auto: detect which side has higher luminance (white gutter)
            above_sum = sum(buf[y * bpl + x] for y in range(max(0, y_top - 4), y_top) for x in range(x_min, x_max + 1))
            below_sum = sum(buf[y * bpl + x] for y in range(y_bottom + 1, min(h, y_bottom + 5)) for x in range(x_min, x_max + 1))
            return min(h, y_bottom + 1) if below_sum >= above_sum else max(0, y_top)

    def _find_vertical_ink_border(self, ix: int, iy: int, search_r: int, side: str = "auto") -> Optional[int]:
        """Find vertical black panel border within search_r and return coordinate OUTSIDE the border."""
        if not self._gray_bytes or self.native_w == 0 or self.native_h == 0:
            return None

        h, w = self.native_h, self.native_w
        bpl = self._bpl
        buf = self._gray_bytes

        x_min = max(0, ix - search_r)
        x_max = min(w - 1, ix + search_r)
        y_min = max(0, iy - 15)
        y_max = min(h - 1, iy + 15)
        span_len = y_max - y_min + 1
        if span_len < 10:
            return None

        dark_cols = []
        for x in range(x_min, x_max + 1):
            dark_count = 0
            for y in range(y_min, y_max + 1):
                if buf[y * bpl + x] < 110:
                    dark_count += 1
            if dark_count >= span_len * 0.5:
                dark_cols.append(x)

        if not dark_cols:
            return None

        # Group contiguous dark columns into stroke blocks
        blocks = []
        curr = [dark_cols[0]]
        for c in dark_cols[1:]:
            if c == curr[-1] + 1:
                curr.append(c)
            else:
                blocks.append(curr)
                curr = [c]
        blocks.append(curr)

        best_block = min(blocks, key=lambda b: abs((b[0] + b[-1]) / 2.0 - ix))
        x_left = best_block[0]
        x_right = best_block[-1]

        if side == "right":
            # Outside right border: just to the right of the black stroke (in the gutter)
            return min(w, x_right + 1)
        elif side == "left":
            # Outside left border: just to the left of the black stroke (in the gutter)
            return max(0, x_left)
        else:
            # Auto: detect which side has higher luminance (white gutter)
            left_sum = sum(buf[y * bpl + x] for y in range(y_min, y_max + 1) for x in range(max(0, x_left - 4), x_left))
            right_sum = sum(buf[y * bpl + x] for y in range(y_min, y_max + 1) for x in range(x_right + 1, min(w, x_right + 5)))
            return min(w, x_right + 1) if right_sum >= left_sum else max(0, x_left)

    def _apply_precision_snap(
        self,
        ix: int,
        iy: int,
        is_alt_held: bool = False,
        side_x: str = "auto",
        side_y: str = "auto"
    ) -> Tuple[int, int]:
        """Magnetically snap coordinate outside the black borders of panels, page edges, or existing panels.
        Holding Alt disables magnetic snap for freeform adjustments."""
        if not self.precision_mouse_enabled or is_alt_held:
            self._snap_guide_x = None
            self._snap_guide_y = None
            return ix, iy

        # Snap radius in image pixels (~10 screen pixels for pleasant light magnet feel)
        snap_r = max(4, int(round(10.0 / max(0.1, self.zoom_factor))))

        candidates_x = [0, self.native_w]
        candidates_y = [0, self.native_h]

        # 1. Existing panel boundaries (snap to outer edges)
        for idx, panel in enumerate(self.panels):
            if idx == self.selected_panel_index:
                continue
            candidates_x.append(panel.x)
            candidates_x.append(panel.x + panel.w)
            candidates_y.append(panel.y)
            candidates_y.append(panel.y + panel.h)

        # 2. Image black border lines (snaps OUTSIDE the black border stroke)
        ink_x = self._find_vertical_ink_border(ix, iy, snap_r, side=side_x)
        if ink_x is not None:
            candidates_x.append(ink_x)

        ink_y = self._find_horizontal_ink_border(ix, iy, snap_r, side=side_y)
        if ink_y is not None:
            candidates_y.append(ink_y)

        # Select closest valid X candidate within snap_r
        valid_x = [cx for cx in candidates_x if abs(ix - cx) <= snap_r]
        if valid_x:
            snapped_x = min(valid_x, key=lambda cx: abs(ix - cx))
            guide_x = snapped_x
        else:
            snapped_x = ix
            guide_x = None

        # Select closest valid Y candidate within snap_r
        valid_y = [cy for cy in candidates_y if abs(iy - cy) <= snap_r]
        if valid_y:
            snapped_y = min(valid_y, key=lambda cy: abs(iy - cy))
            guide_y = snapped_y
        else:
            snapped_y = iy
            guide_y = None

        self._snap_guide_x = guide_x
        self._snap_guide_y = guide_y
        return snapped_x, snapped_y

    def image_to_widget(self, ix: float, iy: float) -> Tuple[float, float]:
        """Convert native image coordinates to widget coordinates."""
        wx = ix * self.zoom_factor + self.offset_x
        wy = iy * self.zoom_factor + self.offset_y
        return wx, wy

    def widget_to_image(self, wx: float, wy: float) -> Tuple[int, int]:
        """Convert widget coordinates to clamped native image coordinates."""
        if self.zoom_factor <= 0:
            return 0, 0
        ix = (wx - self.offset_x) / self.zoom_factor
        iy = (wy - self.offset_y) / self.zoom_factor
        ix = max(0, min(self.native_w, int(round(ix))))
        iy = max(0, min(self.native_h, int(round(iy))))
        return ix, iy

    def _get_handle_rects(self, panel: Panel) -> List[Tuple[int, QRectF]]:
        """Return list of (handle_type, QRectF) in widget coordinates for 8 resize handles."""
        wx, wy = self.image_to_widget(panel.x, panel.y)
        ww = panel.w * self.zoom_factor
        wh = panel.h * self.zoom_factor
        hs = HANDLE_SIZE
        half = hs / 2.0

        handles = [
            (HANDLE_TL, QRectF(wx - half, wy - half, hs, hs)),
            (HANDLE_T,  QRectF(wx + ww / 2 - half, wy - half, hs, hs)),
            (HANDLE_TR, QRectF(wx + ww - half, wy - half, hs, hs)),
            (HANDLE_R,  QRectF(wx + ww - half, wy + wh / 2 - half, hs, hs)),
            (HANDLE_BR, QRectF(wx + ww - half, wy + wh - half, hs, hs)),
            (HANDLE_B,  QRectF(wx + ww / 2 - half, wy + wh - half, hs, hs)),
            (HANDLE_BL, QRectF(wx - half, wy + wh - half, hs, hs)),
            (HANDLE_L,  QRectF(wx - half, wy + wh / 2 - half, hs, hs)),
        ]
        return handles

    def _hit_test(self, pos: QPoint) -> Tuple[int, int]:
        """Determine hit handle and panel index under mouse position."""
        # 1. Check handles of selected panel first
        if 0 <= self.selected_panel_index < len(self.panels):
            p = self.panels[self.selected_panel_index]
            for h_type, r in self._get_handle_rects(p):
                if r.contains(QPointF(pos)):
                    return h_type, self.selected_panel_index

        # 2. Check panel bodies (search top-most first)
        ix, iy = self.widget_to_image(pos.x(), pos.y())
        for idx in range(len(self.panels) - 1, -1, -1):
            p = self.panels[idx]
            if p.contains_point(ix, iy):
                return HANDLE_MOVE, idx

        return HANDLE_NONE, -1

    def add_full_page_panel(self):
        """Add a bounding box covering the entire page."""
        if self.native_w == 0 or self.native_h == 0:
            return
        self.set_annotation_mode("panel")
        self.push_undo()
        panel = Panel(0, 0, self.native_w, self.native_h)
        self.panels.append(panel)
        self.selected_panel_index = len(self.panels) - 1
        self.panels_changed.emit()
        self.panel_selected.emit(self.selected_panel_index)
        self.update()

    def set_full_page_panel(self):
        """Replace this page's annotations with one full-page panel."""
        if self.native_w == 0 or self.native_h == 0:
            return
        self.set_annotation_mode("panel")
        self.push_undo()
        self.panels = [Panel(0, 0, self.native_w, self.native_h)]
        self._collections["panel"] = self.panels
        self.selected_panel_index = 0
        self.panels_changed.emit()
        self.panel_selected.emit(self.selected_panel_index)
        self.update()

    def select_panel(self, idx: int):
        """Set selected panel by index."""
        if -1 <= idx < len(self.panels):
            self.selected_panel_index = idx
            if idx >= 0 and self.annotation_mode == "phrase":
                self.current_phrase_id = self.panels[idx].phrase_id
                self.phrase_id_changed.emit(self.current_phrase_id)
            self.panel_selected.emit(idx)
            self.update()

    def delete_selected_panel(self):
        """Remove currently selected panel."""
        if 0 <= self.selected_panel_index < len(self.panels):
            self.push_undo()
            self.panels.pop(self.selected_panel_index)
            if self.annotation_mode in ("phrase", "word"):
                self.refresh_word_assignments()
            self.selected_panel_index = min(self.selected_panel_index, len(self.panels) - 1)
            self.panels_changed.emit()
            self.panel_selected.emit(self.selected_panel_index)
            self.update()

    def clear_panels(self):
        """Clear all panels on this page."""
        if not self.panels:
            return
        self.push_undo()
        self.panels.clear()
        if self.annotation_mode in ("phrase", "word"):
            self.refresh_word_assignments()
        self.selected_panel_index = -1
        self.panels_changed.emit()
        self.panel_selected.emit(-1)
        self.update()

    def move_panel_up(self, idx: int):
        """Move panel earlier in reading order sequence."""
        if idx > 0 and idx < len(self.panels):
            self.push_undo()
            self.panels[idx], self.panels[idx - 1] = self.panels[idx - 1], self.panels[idx]
            self.selected_panel_index = idx - 1
            self.panels_changed.emit()
            self.panel_selected.emit(self.selected_panel_index)
            self.update()

    def move_panel_down(self, idx: int):
        """Move panel later in reading order sequence."""
        if 0 <= idx < len(self.panels) - 1:
            self.push_undo()
            self.panels[idx], self.panels[idx + 1] = self.panels[idx + 1], self.panels[idx]
            self.selected_panel_index = idx + 1
            self.panels_changed.emit()
            self.panel_selected.emit(self.selected_panel_index)
            self.update()

    # --- Mouse & Keyboard Event Handlers ---

    def keyPressEvent(self, event: QKeyEvent):
        if event.modifiers() & Qt.KeyboardModifier.ControlModifier:
            if event.key() == Qt.Key.Key_Z:
                if event.modifiers() & Qt.KeyboardModifier.ShiftModifier:
                    self.redo()
                else:
                    self.undo()
                return
            elif event.key() == Qt.Key.Key_Y:
                self.redo()
                return

        # Keyboard Arrow Nudge for Selected Panel
        if 0 <= self.selected_panel_index < len(self.panels):
            p = self.panels[self.selected_panel_index]
            step = 5 if (event.modifiers() & Qt.KeyboardModifier.ShiftModifier) else 1
            is_alt = bool(event.modifiers() & Qt.KeyboardModifier.AltModifier)

            if event.key() in (Qt.Key.Key_Left, Qt.Key.Key_Right, Qt.Key.Key_Up, Qt.Key.Key_Down):
                self.push_undo()
                if is_alt:
                    # Resize right / bottom
                    if event.key() == Qt.Key.Key_Left:
                        p.w = max(MIN_BOX_SIZE, p.w - step)
                    elif event.key() == Qt.Key.Key_Right:
                        p.w = min(self.native_w - p.x, p.w + step)
                    elif event.key() == Qt.Key.Key_Up:
                        p.h = max(MIN_BOX_SIZE, p.h - step)
                    elif event.key() == Qt.Key.Key_Down:
                        p.h = min(self.native_h - p.y, p.h + step)
                else:
                    # Move
                    if event.key() == Qt.Key.Key_Left:
                        p.x = max(0, p.x - step)
                    elif event.key() == Qt.Key.Key_Right:
                        p.x = min(self.native_w - p.w, p.x + step)
                    elif event.key() == Qt.Key.Key_Up:
                        p.y = max(0, p.y - step)
                    elif event.key() == Qt.Key.Key_Down:
                        p.y = min(self.native_h - p.h, p.y + step)
                if self.annotation_mode in ("phrase", "word"):
                    self.refresh_word_assignments()
                self.panels_changed.emit()
                self.update()
                self.status_message.emit(
                    f"Nudged {self.annotation_mode} [{self.selected_panel_index + 1}] "
                    f"to ({p.x}, {p.y}, {p.w}, {p.h})"
                )
                return

        if event.key() == Qt.Key.Key_Space:
            self._space_pressed = True
            self.setCursor(QCursor(Qt.CursorShape.OpenHandCursor))
        elif event.key() == Qt.Key.Key_F and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            self.single_page_illustration_requested.emit()
        elif event.key() == Qt.Key.Key_S and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            self.double_page_illustration_requested.emit()
        elif event.key() == Qt.Key.Key_P:
            self.set_precision_mode(not self.precision_mouse_enabled)
        elif event.key() == Qt.Key.Key_1 and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            self.set_annotation_mode("panel")
        elif event.key() == Qt.Key.Key_2 and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            self.set_annotation_mode("phrase")
        elif event.key() == Qt.Key.Key_3 and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            self.set_annotation_mode("word")
        elif event.key() == Qt.Key.Key_Q and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            self.step_phrase_id(-1)
        elif event.key() == Qt.Key.Key_R and event.modifiers() == Qt.KeyboardModifier.NoModifier:
            self.step_phrase_id(1)
        elif event.key() in (Qt.Key.Key_Delete, Qt.Key.Key_Backspace):
            self.delete_selected_panel()
        elif event.key() == Qt.Key.Key_Escape:
            if self._mode != "idle":
                self._mode = "idle"
                self._current_image_box = None
                self.update()
            else:
                self.select_panel(-1)
        super().keyPressEvent(event)

    def keyReleaseEvent(self, event: QKeyEvent):
        if event.key() == Qt.Key.Key_Space:
            self._space_pressed = False
            self.setCursor(QCursor(Qt.CursorShape.ArrowCursor))
        super().keyReleaseEvent(event)

    def wheelEvent(self, event: QWheelEvent):
        delta = event.angleDelta().y()
        if delta == 0:
            delta = event.angleDelta().x()
            if delta == 0:
                return

        modifiers = event.modifiers()
        is_ctrl = bool(modifiers & Qt.KeyboardModifier.ControlModifier)
        is_alt = bool(modifiers & Qt.KeyboardModifier.AltModifier)

        pos = event.position().toPoint()

        if is_ctrl:
            # Zoom centered on mouse pointer (Ctrl + mouse wheel)
            factor = 1.15 if delta > 0 else 0.85
            old_zoom = self.zoom_factor
            new_zoom = max(0.05, min(10.0, old_zoom * factor))
            if old_zoom != new_zoom:
                self.offset_x = pos.x() - (pos.x() - self.offset_x) * (new_zoom / old_zoom)
                self.offset_y = pos.y() - (pos.y() - self.offset_y) * (new_zoom / old_zoom)
                self.zoom_factor = new_zoom
                self.zoom_changed.emit(self.zoom_factor)
        else:
            # Regular wheel: Scroll vertically in Y-axis (Pan Y)
            # Wheel up (delta > 0) scrolls page up (offset_y increases).
            # Wheel down (delta < 0) scrolls page down (offset_y decreases).
            scroll_step = delta * 0.75
            self.offset_y += scroll_step
            # Clamp offset_y to prevent losing the image entirely
            img_h = self.native_h * self.zoom_factor
            view_h = float(self.rect().height())
            if img_h > view_h:
                min_y = view_h - img_h - 100.0
                max_y = 100.0
            else:
                min_y = -50.0
                max_y = max(50.0, view_h - 50.0)
            self.offset_y = max(min_y, min(max_y, self.offset_y))

        # Synchronous tracking update if currently drawing, moving, or resizing
        self._current_mouse_pos = pos
        curr_ix, curr_iy = self.widget_to_image(pos.x(), pos.y())
        use_precision = (self.precision_mouse_enabled or bool(modifiers & Qt.KeyboardModifier.ShiftModifier)) and not is_alt
        side_x = "auto"
        side_y = "auto"
        if self._mode == "drawing":
            side_x = "right" if curr_ix >= self._drag_start_image_x else "left"
            side_y = "bottom" if curr_iy >= self._drag_start_image_y else "top"
        elif self._mode == "resizing":
            if self._active_handle in (HANDLE_TR, HANDLE_R, HANDLE_BR):
                side_x = "right"
            elif self._active_handle in (HANDLE_TL, HANDLE_L, HANDLE_BL):
                side_x = "left"
            if self._active_handle in (HANDLE_BL, HANDLE_B, HANDLE_BR):
                side_y = "bottom"
            elif self._active_handle in (HANDLE_TL, HANDLE_T, HANDLE_TR):
                side_y = "top"

        if use_precision:
            curr_ix, curr_iy = self._apply_precision_snap(curr_ix, curr_iy, is_alt_held=is_alt, side_x=side_x, side_y=side_y)
        else:
            self._snap_guide_x = None
            self._snap_guide_y = None

        self._active_ix = curr_ix
        self._active_iy = curr_iy

        if self._mode == "drawing":
            start_ix = self._drag_start_image_x
            start_iy = self._drag_start_image_y
            self._current_image_box = (start_ix, start_iy, curr_ix, curr_iy)

        elif self._mode == "moving" and self._panel_before_drag and 0 <= self.selected_panel_index < len(self.panels):
            orig = self._panel_before_drag
            start_ix = self._drag_start_image_x
            start_iy = self._drag_start_image_y
            dx = curr_ix - start_ix
            dy = curr_iy - start_iy
            nx = max(0, min(self.native_w - orig.w, orig.x + dx))
            ny = max(0, min(self.native_h - orig.h, orig.y + dy))
            if use_precision:
                nx, ny = self._apply_precision_snap(nx, ny, is_alt_held=is_alt, side_x="auto", side_y="auto")
            p = self.panels[self.selected_panel_index]
            p.x = nx
            p.y = ny

        elif self._mode == "resizing" and self._panel_before_drag and 0 <= self.selected_panel_index < len(self.panels):
            orig = self._panel_before_drag
            x, y, w, h = orig.x, orig.y, orig.w, orig.h
            if self._active_handle in (HANDLE_TL, HANDLE_L, HANDLE_BL):
                new_x = min(orig.x + orig.w - MIN_BOX_SIZE, max(0, curr_ix))
                w = orig.x + orig.w - new_x
                x = new_x
            if self._active_handle in (HANDLE_TR, HANDLE_R, HANDLE_BR):
                w = max(MIN_BOX_SIZE, min(self.native_w - orig.x, curr_ix - orig.x))
            if self._active_handle in (HANDLE_TL, HANDLE_T, HANDLE_TR):
                new_y = min(orig.y + orig.h - MIN_BOX_SIZE, max(0, curr_iy))
                h = orig.y + orig.h - new_y
                y = new_y
            if self._active_handle in (HANDLE_BL, HANDLE_B, HANDLE_BR):
                h = max(MIN_BOX_SIZE, min(self.native_h - orig.y, curr_iy - orig.y))
            p = self.panels[self.selected_panel_index]
            p.x, p.y, p.w, p.h = x, y, w, h

        self.update()

    def mousePressEvent(self, event: QMouseEvent):
        pos = event.position().toPoint()

        # Middle click or Space+Left click -> Pan
        if event.button() == Qt.MouseButton.MiddleButton or (event.button() == Qt.MouseButton.LeftButton and self._space_pressed):
            self._mode = "panning"
            self._pan_start_pos = pos
            self.setCursor(QCursor(Qt.CursorShape.ClosedHandCursor))
            return

        if event.button() == Qt.MouseButton.LeftButton:
            self._panels_at_drag_start = [p.copy() for p in self.panels]
            self._current_image_box = None
            self._drag_start_pos = pos
            self._current_mouse_pos = pos

            start_ix, start_iy = self.widget_to_image(pos.x(), pos.y())
            self._drag_start_image_x = start_ix
            self._drag_start_image_y = start_iy

            handle, panel_idx = self._hit_test(pos)
            if handle in (HANDLE_TL, HANDLE_T, HANDLE_TR, HANDLE_R, HANDLE_BR, HANDLE_B, HANDLE_BL, HANDLE_L):
                self._mode = "resizing"
                self._active_handle = handle
                self._panel_before_drag = self.panels[self.selected_panel_index].copy()
                self._active_ix = start_ix
                self._active_iy = start_iy
            elif handle == HANDLE_MOVE:
                self.select_panel(panel_idx)
                self._mode = "moving"
                self._active_handle = HANDLE_MOVE
                self._panel_before_drag = self.panels[panel_idx].copy()
                self._active_ix = self.panels[panel_idx].x
                self._active_iy = self.panels[panel_idx].y
            else:
                # Start drawing new panel box
                self.select_panel(-1)
                self._mode = "drawing"
                self._active_handle = HANDLE_NONE
                self._current_image_box = (start_ix, start_iy, start_ix, start_iy)
                self._active_ix = start_ix
                self._active_iy = start_iy

        elif event.button() == Qt.MouseButton.RightButton:
            # Right click deselects
            self.select_panel(-1)

        self.update()

    def mouseMoveEvent(self, event: QMouseEvent):
        pos = event.position().toPoint()
        is_alt = bool(event.modifiers() & Qt.KeyboardModifier.AltModifier)

        ix, iy = self.widget_to_image(pos.x(), pos.y())
        self.cursor_position.emit(ix, iy)
        self._current_mouse_pos = pos

        if self._mode == "panning":
            if self._pan_start_pos:
                dx = pos.x() - self._pan_start_pos.x()
                dy = pos.y() - self._pan_start_pos.y()
                self.offset_x += dx
                self.offset_y += dy
                self._pan_start_pos = pos
                self.update()
            return

        use_precision = self.precision_mouse_enabled and not is_alt

        if self._mode == "drawing" and self._drag_start_pos:
            start_ix = self._drag_start_image_x
            start_iy = self._drag_start_image_y
            curr_ix = ix
            curr_iy = iy
            if use_precision:
                side_x = "right" if curr_ix >= start_ix else "left"
                side_y = "bottom" if curr_iy >= start_iy else "top"
                curr_ix, curr_iy = self._apply_precision_snap(curr_ix, curr_iy, is_alt_held=is_alt, side_x=side_x, side_y=side_y)
            else:
                self._snap_guide_x = None
                self._snap_guide_y = None
            self._current_image_box = (start_ix, start_iy, curr_ix, curr_iy)
            self._active_ix = curr_ix
            self._active_iy = curr_iy
            self.update()
            return

        if self._mode == "moving" and self._panel_before_drag and 0 <= self.selected_panel_index < len(self.panels):
            orig = self._panel_before_drag
            start_ix = self._drag_start_image_x
            start_iy = self._drag_start_image_y
            dx = ix - start_ix
            dy = iy - start_iy

            nx = max(0, min(self.native_w - orig.w, orig.x + dx))
            ny = max(0, min(self.native_h - orig.h, orig.y + dy))

            p = self.panels[self.selected_panel_index]
            p.x = nx
            p.y = ny
            self._active_ix = nx
            self._active_iy = ny
            self.update()
            return

        if self._mode == "resizing" and self._panel_before_drag and 0 <= self.selected_panel_index < len(self.panels):
            orig = self._panel_before_drag
            start_ix = self._drag_start_image_x
            start_iy = self._drag_start_image_y
            dx = ix - start_ix
            dy = iy - start_iy

            x, y, w, h = orig.x, orig.y, orig.w, orig.h

            if self._active_handle in (HANDLE_TL, HANDLE_L, HANDLE_BL):
                new_x = min(orig.x + orig.w - MIN_BOX_SIZE, max(0, orig.x + dx))
                w = orig.x + orig.w - new_x
                x = new_x
            if self._active_handle in (HANDLE_TR, HANDLE_R, HANDLE_BR):
                w = max(MIN_BOX_SIZE, min(self.native_w - orig.x, orig.w + dx))
            if self._active_handle in (HANDLE_TL, HANDLE_T, HANDLE_TR):
                new_y = min(orig.y + orig.h - MIN_BOX_SIZE, max(0, orig.y + dy))
                h = orig.y + orig.h - new_y
                y = new_y
            if self._active_handle in (HANDLE_BL, HANDLE_B, HANDLE_BR):
                h = max(MIN_BOX_SIZE, min(self.native_h - orig.y, orig.h + dy))

            if use_precision:
                if self._active_handle in (HANDLE_TR, HANDLE_R, HANDLE_BR):
                    snapped_right, _ = self._apply_precision_snap(x + w, y, is_alt_held=is_alt, side_x="right", side_y="none")
                    w = max(MIN_BOX_SIZE, min(self.native_w - x, snapped_right - x))
                elif self._active_handle in (HANDLE_TL, HANDLE_L, HANDLE_BL):
                    snapped_left, _ = self._apply_precision_snap(x, y, is_alt_held=is_alt, side_x="left", side_y="none")
                    new_x = min(orig.x + orig.w - MIN_BOX_SIZE, max(0, snapped_left))
                    w = orig.x + orig.w - new_x
                    x = new_x

                if self._active_handle in (HANDLE_BL, HANDLE_B, HANDLE_BR):
                    _, snapped_bottom = self._apply_precision_snap(x, y + h, is_alt_held=is_alt, side_x="none", side_y="bottom")
                    h = max(MIN_BOX_SIZE, min(self.native_h - y, snapped_bottom - y))
                elif self._active_handle in (HANDLE_TL, HANDLE_T, HANDLE_TR):
                    _, snapped_top = self._apply_precision_snap(x, y, is_alt_held=is_alt, side_x="none", side_y="top")
                    new_y = min(orig.y + orig.h - MIN_BOX_SIZE, max(0, snapped_top))
                    h = orig.y + orig.h - new_y
                    y = new_y
            else:
                self._snap_guide_x = None
                self._snap_guide_y = None

            p = self.panels[self.selected_panel_index]
            p.x, p.y, p.w, p.h = x, y, w, h
            self._active_ix = curr_ix if 'curr_ix' in locals() else ix
            self._active_iy = curr_iy if 'curr_iy' in locals() else iy
            self.update()
            return

        # Update visible cursor based on hover and trigger update
        self._update_hover_cursor(pos)
        self.update()

    def mouseReleaseEvent(self, event: QMouseEvent):
        pos = event.position().toPoint()
        self._snap_guide_x = None
        self._snap_guide_y = None

        if self._mode == "panning":
            self._mode = "idle"
            self._pan_start_pos = None
            self._update_hover_cursor(pos)
            self.update()
            return

        if self._mode == "drawing" and self._drag_start_pos:
            if self._current_image_box:
                ix1, iy1, ix2, iy2 = self._current_image_box
            else:
                ix1 = self._drag_start_image_x
                iy1 = self._drag_start_image_y
                ix2, iy2 = self.widget_to_image(pos.x(), pos.y())

            x = min(ix1, ix2)
            y = min(iy1, iy2)
            w = abs(ix2 - ix1)
            h = abs(iy2 - iy1)

            if w >= MIN_BOX_SIZE and h >= MIN_BOX_SIZE:
                self._undo_stack.append([p.copy() for p in self._panels_at_drag_start])
                self._redo_stack.clear()
                if self.annotation_mode == "phrase":
                    candidate = Panel(x, y, w, h)
                    if not (event.modifiers() & Qt.KeyboardModifier.AltModifier):
                        self._auto_advance_phrase_id_for(candidate)
                    existing_text = next(
                        (
                            phrase.text
                            for phrase in self.get_phrases()
                            if phrase.phrase_id == self.current_phrase_id and phrase.text
                        ),
                        "",
                    )
                    new_panel = PhraseRect(x, y, w, h, self.current_phrase_id, existing_text)
                elif self.annotation_mode == "word":
                    new_panel = WordRect(x, y, w, h)
                else:
                    new_panel = Panel(x, y, w, h)
                self.panels.append(new_panel)
                if self.annotation_mode in ("phrase", "word"):
                    self.refresh_word_assignments()
                self.selected_panel_index = len(self.panels) - 1
                if self.annotation_mode == "phrase" and not new_panel.text:
                    self.phrase_text_requested.emit(self.selected_panel_index)
                    if new_panel not in self.panels:
                        self.selected_panel_index = -1
                elif self.annotation_mode == "word":
                    self.word_text_requested.emit(self.selected_panel_index)
                    if new_panel not in self.panels:
                        self.selected_panel_index = -1
                self.panels_changed.emit()
                self.panel_selected.emit(self.selected_panel_index)

            self._mode = "idle"
            self._drag_start_pos = None
            self._current_mouse_pos = None
            self._current_image_box = None
            self._update_hover_cursor(pos)
            self.update()
            return

        if self._mode in ("resizing", "moving"):
            changed = False
            if len(self.panels) == len(self._panels_at_drag_start):
                for p_now, p_orig in zip(self.panels, self._panels_at_drag_start):
                    if (p_now.x, p_now.y, p_now.w, p_now.h) != (p_orig.x, p_orig.y, p_orig.w, p_orig.h):
                        changed = True
                        break
            else:
                changed = True

            if changed:
                self._undo_stack.append([p.copy() for p in self._panels_at_drag_start])
                self._redo_stack.clear()

            if self.annotation_mode in ("phrase", "word"):
                self.refresh_word_assignments()

            self._mode = "idle"
            self._drag_start_pos = None
            self._panel_before_drag = None
            self._current_image_box = None
            self.panels_changed.emit()
            self._update_hover_cursor(pos)
            self.update()

    # --- Rendering ---

    def paintEvent(self, event: QPaintEvent):
        painter = QPainter(self)
        painter.setRenderHint(QPainter.RenderHint.Antialiasing, True)
        painter.setRenderHint(QPainter.RenderHint.SmoothPixmapTransform, True)

        # Background canvas fill
        painter.fillRect(self.rect(), QColor("#1e1e1e"))

        # Dimensions
        img_w = self.native_w * self.zoom_factor
        img_h = self.native_h * self.zoom_factor

        # Draw Image
        if self._pixmap and not self._pixmap.isNull():
            target_rect = QRectF(self.offset_x, self.offset_y, img_w, img_h)
            painter.drawPixmap(target_rect, self._pixmap, QRectF(self._pixmap.rect()))
            # Border around page
            painter.setPen(QPen(QColor("#444444"), 1))
            painter.drawRect(target_rect)

        # Draw Magnetic Snap Guidelines
        if self._mode in ("drawing", "resizing", "moving"):
            if self._snap_guide_x is not None:
                gx, _ = self.image_to_widget(self._snap_guide_x, 0)
                painter.setPen(QPen(QColor(0, 229, 255, 175), 1.2, Qt.PenStyle.DashLine))
                top_y = max(0.0, float(self.offset_y))
                bot_y = min(float(self.rect().height()), float(self.offset_y + img_h))
                painter.drawLine(QPointF(gx, top_y), QPointF(gx, bot_y))

            if self._snap_guide_y is not None:
                _, gy = self.image_to_widget(0, self._snap_guide_y)
                painter.setPen(QPen(QColor(0, 229, 255, 175), 1.2, Qt.PenStyle.DashLine))
                left_x = max(0.0, float(self.offset_x))
                right_x = min(float(self.rect().width()), float(self.offset_x + img_w))
                painter.drawLine(QPointF(left_x, gy), QPointF(right_x, gy))

        # Draw inactive annotation layers first, so phrase boundaries remain visible
        # while placing words and panel context remains visible in text modes.
        layer_colors = {
            "panel": QColor("#ff9100"),
            "phrase": QColor("#ab47bc"),
            "word": QColor("#66bb6a"),
        }
        for layer_name, rectangles in self._collections.items():
            if layer_name == self.annotation_mode:
                continue
            color = layer_colors[layer_name]
            painter.setPen(QPen(color, 1.2, Qt.PenStyle.DashLine))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            for rectangle in rectangles:
                wx, wy = self.image_to_widget(rectangle.x, rectangle.y)
                painter.drawRect(QRectF(
                    wx, wy, rectangle.w * self.zoom_factor, rectangle.h * self.zoom_factor
                ))

        # Draw rectangles from the active layer.
        font = QFont("SansSerif", 10, QFont.Weight.Bold)
        painter.setFont(font)
        fm = QFontMetrics(font)

        for idx, panel in enumerate(self.panels):
            is_selected = (idx == self.selected_panel_index)
            wx, wy = self.image_to_widget(panel.x, panel.y)
            ww = panel.w * self.zoom_factor
            wh = panel.h * self.zoom_factor
            box_rect = QRectF(wx, wy, ww, wh)

            # Box fill & outline
            if is_selected:
                painter.setPen(QPen(QColor("#00e5ff"), 2.5))
                painter.setBrush(QBrush(QColor(0, 229, 255, 35)))
            else:
                active_color = layer_colors[self.annotation_mode]
                painter.setPen(QPen(active_color, 2.0))
                painter.setBrush(QBrush(QColor(active_color.red(), active_color.green(), active_color.blue(), 25)))
            painter.drawRect(box_rect)

            # Badge [1], [2], [3]...
            if self.annotation_mode == "phrase":
                badge_text = f" P{panel.phrase_id}.{idx + 1} "
            elif self.annotation_mode == "word":
                owner = panel.phrase_id if panel.phrase_id is not None else "?"
                badge_text = f" P{owner}:W{idx + 1} "
            else:
                badge_text = f" {idx + 1} "
            tw = fm.horizontalAdvance(badge_text) + 6
            th = fm.height() + 4
            badge_rect = QRectF(wx + 2, wy + 2, tw, th)

            if is_selected:
                painter.fillRect(badge_rect, QColor("#00e5ff"))
                painter.setPen(QColor("#000000"))
            else:
                painter.fillRect(badge_rect, layer_colors[self.annotation_mode])
                painter.setPen(QColor("#000000"))
            painter.drawText(badge_rect, Qt.AlignmentFlag.AlignCenter, badge_text)

            # Handles for selected panel
            if is_selected:
                painter.setPen(QPen(QColor("#00e5ff"), 1.5))
                painter.setBrush(QBrush(QColor("#ffffff")))
                for _, hr in self._get_handle_rects(panel):
                    painter.drawRect(hr)

        # Draw rubber-band while currently drawing
        if self._mode == "drawing" and self._current_image_box:
            ix1, iy1, ix2, iy2 = self._current_image_box
            rx = min(ix1, ix2)
            ry = min(iy1, iy2)
            rw = abs(ix2 - ix1)
            rh = abs(iy2 - iy1)

            wx, wy = self.image_to_widget(rx, ry)
            ww = rw * self.zoom_factor
            wh = rh * self.zoom_factor

            painter.setPen(QPen(QColor("#76ff03"), 1.8, Qt.PenStyle.DashLine))
            painter.setBrush(QBrush(QColor(118, 255, 3, 30)))
            painter.drawRect(QRectF(wx, wy, ww, wh))

            # Next sequential badge preview
            next_idx = len(self.panels) + 1
            if self.annotation_mode == "phrase":
                badge_text = f" P{self.current_phrase_id}.{next_idx} "
            elif self.annotation_mode == "word":
                badge_text = f" W{next_idx} "
            else:
                badge_text = f" {next_idx} "
            tw = fm.horizontalAdvance(badge_text) + 6
            th = fm.height() + 4
            badge_rect = QRectF(wx + 2, wy + 2, tw, th)
            painter.fillRect(badge_rect, QColor("#76ff03"))
            painter.setPen(QColor("#000000"))
            painter.drawText(badge_rect, Qt.AlignmentFlag.AlignCenter, badge_text)

        # Precision Loupe HUD (Large square with crisp pixel inspection)
        if self.precision_mouse_enabled and self._mode in ("drawing", "resizing") and self._pixmap and not self._pixmap.isNull():
            loupe_size = min(260, max(180, int(min(self.rect().width(), self.rect().height()) * 0.42)))
            margin = 14
            # Keep loupe away from cursor
            if self._current_mouse_pos and self._current_mouse_pos.x() > self.rect().width() - (loupe_size + 40) and self._current_mouse_pos.y() < (loupe_size + 40):
                lx = margin
            else:
                lx = self.rect().width() - loupe_size - margin
            ly = margin

            crop_size = 48
            half = crop_size // 2
            cx = max(0, min(self.native_w - crop_size, self._active_ix - half))
            cy = max(0, min(self.native_h - crop_size, self._active_iy - half))

            painter.save()
            loupe_rect = QRectF(lx, ly, loupe_size, loupe_size)
            painter.setPen(QPen(QColor("#00e5ff"), 2))
            painter.setBrush(QBrush(QColor("#151515")))
            painter.drawRoundedRect(loupe_rect, 8, 8)

            inner_rect = loupe_rect.adjusted(2, 2, -2, -2)
            painter.setClipRect(inner_rect)
            src_rect = QRectF(cx, cy, crop_size, crop_size)
            painter.drawPixmap(inner_rect, self._pixmap, src_rect)

            # Center crosshair inside loupe
            mid_x = lx + loupe_size / 2.0
            mid_y = ly + loupe_size / 2.0
            painter.setPen(QPen(QColor(0, 229, 255, 220), 1.2))
            painter.drawLine(QPointF(mid_x - 18, mid_y), QPointF(mid_x + 18, mid_y))
            painter.drawLine(QPointF(mid_x, mid_y - 18), QPointF(mid_x, mid_y + 18))
            painter.setBrush(Qt.BrushStyle.NoBrush)
            painter.drawEllipse(QPointF(mid_x, mid_y), 4, 4)

            painter.restore()
            badge_h = 24
            painter.fillRect(QRectF(lx, ly + loupe_size - badge_h, loupe_size, badge_h), QColor(0, 0, 0, 220))
            painter.setPen(QColor("#00e5ff"))
            font_small = QFont("SansSerif", 8, QFont.Weight.Bold)
            painter.setFont(font_small)
            mag_ratio = round(loupe_size / crop_size, 1)
            painter.drawText(
                QRectF(lx, ly + loupe_size - badge_h, loupe_size, badge_h),
                Qt.AlignmentFlag.AlignCenter,
                f"🎯 {mag_ratio}× ({self._active_ix}, {self._active_iy}) [Alt=free]"
            )

        painter.end()
