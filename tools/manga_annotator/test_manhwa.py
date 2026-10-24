"""Import formats and continuous annotation round trips (headless Qt)."""
import os
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch
import zipfile

os.environ["QT_QPA_PLATFORM"] = "offscreen"
from PIL import Image
from PyQt6.QtWidgets import QApplication
from PyQt6.QtTest import QTest
from PyQt6.QtCore import Qt
from .app import AnnotatorMainWindow
from .dataset_manager import DatasetManager, Panel
from .document_reader import DocumentReader


class TestManhwa(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = self.temp.name
        self.source = os.path.join(self.root, "source")
        os.makedirs(self.source)
        for name, color in (("vol_10/00.png", "blue"), ("vol_2/10.png", "green"),
                            ("vol_2/02.png", "red")):
            path = os.path.join(self.source, name)
            os.makedirs(os.path.dirname(path), exist_ok=True)
            Image.new("RGB", (200, 600), color).save(path)

    def test_nested_directory_and_zip_natural_order(self):
        for suffix in (None, ".zip", ".cbz", ".cbr"):
            path = self.source
            if suffix:
                path = os.path.join(self.root, "comic" + suffix)
                with zipfile.ZipFile(path, "w") as archive:
                    for folder, _, files in os.walk(self.source):
                        for file in files:
                            full = os.path.join(folder, file)
                            archive.write(full, os.path.relpath(full, self.source))
            reader = DocumentReader(path)
            self.addCleanup(reader.close)
            self.assertEqual(reader.total_pages, 3)
            self.assertEqual([p.get_pil_image().getpixel((0, 0)) for p in reader.pages],
                             [(255, 0, 0), (0, 128, 0), (0, 0, 255)])

    @unittest.skipUnless(shutil.which("bsdtar"), "bsdtar needed for native 7z fixture")
    def test_real_7z(self):
        archive = os.path.join(self.root, "comic.7z")
        subprocess.run(["bsdtar", "--format=7zip", "-cf", archive, "-C", self.source, "."], check=True)
        reader = DocumentReader(archive)
        try:
            self.assertEqual(reader.total_pages, 3)
            self.assertEqual(reader.pages[0].get_pil_image().getpixel((0, 0)), (255, 0, 0))
            extracted = list(reader._temp_dirs)
        finally:
            reader.close()
        self.assertTrue(all(not os.path.exists(path) for path in extracted))

    def test_missing_archive_extractor_cleans_temporary_directory(self):
        path = os.path.join(self.root, "comic.7z")
        with open(path, "wb") as handle:
            handle.write(b"not zip")
        extracted = os.path.join(self.root, "extract")
        os.makedirs(extracted)
        with patch("tools.manga_annotator.document_reader.shutil.which", return_value=None), \
             patch("tools.manga_annotator.document_reader.tempfile.mkdtemp", return_value=extracted):
            with self.assertRaisesRegex(RuntimeError, "7zz"):
                DocumentReader(path)
        self.assertFalse(os.path.exists(extracted))

    def _window(self):
        win = AnnotatorMainWindow(dataset_dir=os.path.join(self.root, "dataset"),
                                  config_path=os.path.join(self.root, "config.json"))
        self.addCleanup(win.close)
        win.import_or_open_file(self.source, friendly_name="webtoon", dataset_type="manhwa")
        return win

    def test_import_draw_across_seam_save_reload_and_algorithms(self):
        win = self._window()
        self.assertEqual(win.dataset_mgr.load_book_metadata("webtoon")["type"], "manhwa")
        self.assertEqual((win.canvas.native_w, win.canvas.native_h), (200, 1800))
        self.assertIsNone(win.canvas._pixmap)
        # Draw one rectangle spanning source pages 1 and 2.
        win.canvas.set_zoom(1)
        win.canvas.offset_x = win.canvas.offset_y = 0
        win.canvas.precision_mouse_enabled = False
        from PyQt6.QtGui import QMouseEvent
        from PyQt6.QtCore import QEvent, QPointF
        for kind, point, button in (
            (QEvent.Type.MouseButtonPress, (20, 550), Qt.MouseButton.LeftButton),
            (QEvent.Type.MouseMove, (160, 650), Qt.MouseButton.NoButton),
            (QEvent.Type.MouseButtonRelease, (160, 650), Qt.MouseButton.LeftButton),
        ):
            event = QMouseEvent(kind, QPointF(*point), button, Qt.MouseButton.LeftButton,
                                Qt.KeyboardModifier.ControlModifier)
            {QEvent.Type.MouseButtonPress: win.canvas.mousePressEvent,
             QEvent.Type.MouseMove: win.canvas.mouseMoveEvent,
             QEvent.Type.MouseButtonRelease: win.canvas.mouseReleaseEvent}[kind](event)
        self.assertEqual(len(win.canvas.get_panels()), 1)
        self.assertEqual(win.canvas.get_panels()[0].h, 100)
        preview = win.canvas.panel_preview(win.canvas.get_panels()[0]).toImage()
        self.assertEqual(preview.pixelColor(10, 2).name(), "#ff0000")
        self.assertEqual(preview.pixelColor(10, preview.height() - 3).name(), "#008000")
        win.canvas.undo()
        self.assertEqual(win.canvas.get_panels(), [])
        win.canvas.redo()
        win.toggle_panel_algorithm()
        self.assertEqual(len(win.canvas.get_panels()), 1)
        win.save_dataset(show_dialog=False)
        manager = DatasetManager(win.dataset_dir)
        for algorithm in ("smart", "safe"):
            rect = manager.get_panel_annotation("webtoon", 1, algorithm).frames[0]
            self.assertEqual((rect.y, rect.h), (550, 100))
            self.assertEqual(manager.get_panel_annotation("webtoon", 2, algorithm).frames, [])
        win.open_book_by_title("webtoon")
        self.assertEqual(win.canvas.get_panels()[0].y, 550)

    def test_animated_half_screen_navigation_and_page_jump(self):
        win = self._window()
        QTest.qWait(80)  # allow the deferred initial fit before navigation
        win.canvas.resize(200, 300)
        win.canvas.set_zoom(1)
        win.canvas.offset_y = 0
        win.next_page()
        self.assertEqual(win.canvas.offset_y, 0)  # animation, no instantaneous jump
        QTest.qWait(100)
        self.assertLess(win.canvas.offset_y, 0)
        self.assertGreater(win.canvas.offset_y, -150)
        QTest.qWait(200)
        self.assertAlmostEqual(win.canvas.offset_y, -150)
        win.prev_page()
        QTest.qWait(300)
        self.assertAlmostEqual(win.canvas.offset_y, 0)
        win.go_to_page(3)
        QTest.qWait(300)
        self.assertAlmostEqual(win.canvas.offset_y, -1200)
        win.next_page()
        win.next_page()
        QTest.qWait(300)
        self.assertAlmostEqual(win.canvas.offset_y, -1500)  # end clamped

    def test_a_d_keys_survive_render_and_algorithm_switch(self):
        win = self._window()
        win.show()
        win.activateWindow()
        win.canvas.setFocus()
        QTest.qWait(100)
        win.canvas.set_zoom(1)
        win.canvas.offset_y = 0
        half = win.canvas.height() / 2
        self.assertEqual(win.btn_next.shortcut().toString(), "D")
        QTest.keyClick(win.canvas, Qt.Key.Key_D)
        QTest.qWait(400)
        self.assertAlmostEqual(win.canvas.offset_y, -half)
        QTest.keyClick(win.canvas, Qt.Key.Key_A)
        QTest.qWait(400)
        self.assertAlmostEqual(win.canvas.offset_y, 0)
        win.toggle_panel_algorithm()
        QTest.keyClick(win.canvas, Qt.Key.Key_D)
        QTest.qWait(400)
        self.assertAlmostEqual(win.canvas.offset_y, -half)
        # The same label updates occur when opening an ordinary manga.
        with patch("tools.manga_annotator.app.QInputDialog.getItem", return_value=("manga", True)):
            win.change_book_type()
        QTest.qWait(80)
        QTest.keyClick(win.canvas, Qt.Key.Key_D)
        QTest.qWait(150)  # QPushButton keyboard activation includes its press animation
        self.assertEqual(win.current_page_num, 2)
        QTest.keyClick(win.canvas, Qt.Key.Key_A)
        QTest.qWait(150)
        self.assertEqual(win.current_page_num, 1)

    def _start_live_panel_drag(self, paired=False):
        from PyQt6.QtCore import QPoint
        win = self._window()
        win.show()
        win.activateWindow()
        win.canvas.setFocus()
        QTest.qWait(100)
        canvas = win.canvas
        canvas.set_zoom(1)
        canvas.offset_x = canvas.offset_y = 0
        canvas.precision_mouse_enabled = False
        modifiers = Qt.KeyboardModifier.ControlModifier if paired else Qt.KeyboardModifier.NoModifier
        QTest.mousePress(canvas, Qt.MouseButton.LeftButton, modifiers, QPoint(20, 300))
        QTest.mouseMove(canvas, QPoint(160, 500))
        self.assertEqual(canvas._mode, "drawing")
        return win

    def test_during_drag_a_d_tracks_cursor_and_preserves_paired_undo(self):
        from PyQt6.QtCore import QPoint
        win = self._start_live_panel_drag(paired=True)
        canvas = win.canvas
        half = canvas.height() / 2
        QTest.keyClick(canvas, Qt.Key.Key_D)
        QTest.qWait(400)
        self.assertEqual(canvas._mode, "drawing")
        self.assertEqual(canvas._current_image_box[:2], (20, 300))
        self.assertEqual(canvas._current_image_box[2:], (160, round(500 + half)))
        # A stationary cursor tracks every frame; no mouse move is required.
        QTest.keyClick(canvas, Qt.Key.Key_D)
        QTest.qWait(400)
        self.assertEqual(canvas._current_image_box[3], round(500 + half * 2))
        QTest.keyClick(canvas, Qt.Key.Key_A)
        QTest.qWait(400)
        self.assertEqual(canvas._current_image_box[3], round(500 + half))
        self.assertEqual(canvas.get_panels(), [])  # commit only on release
        QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=QPoint(160, 500))
        rect = canvas.get_panels()[0]
        self.assertEqual((rect.x, rect.y, rect.w, rect.h), (20, 300, 140, round(500 + half) - 300))
        self.assertEqual(rect.to_dict(), canvas.other_panels[0].to_dict())
        self.assertEqual(len(canvas._undo_stack), 1)
        canvas.undo()
        self.assertEqual(canvas.get_panels(), [])
        self.assertEqual(canvas.other_panels, [])
        canvas.redo()
        self.assertEqual(canvas.get_panels()[0].to_dict(), rect.to_dict())

    def test_drag_release_and_escape_stop_inflight_pan(self):
        from PyQt6.QtCore import QPoint
        win = self._start_live_panel_drag()
        canvas = win.canvas
        QTest.keyClick(canvas, Qt.Key.Key_D)
        QTest.qWait(180)
        self.assertLess(canvas.offset_y, 0)
        QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=QPoint(160, 500))
        released_y = canvas.offset_y
        QTest.qWait(250)
        self.assertEqual(canvas.offset_y, released_y)
        canvas.clear_panels()
        canvas.offset_y = 0
        QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=QPoint(20, 300))
        QTest.mouseMove(canvas, QPoint(160, 500))
        QTest.keyClick(canvas, Qt.Key.Key_D)
        QTest.qWait(180)
        QTest.keyClick(canvas, Qt.Key.Key_Escape)
        cancelled_y = canvas.offset_y
        QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=QPoint(160, 500))
        QTest.qWait(250)
        self.assertEqual(canvas.offset_y, cancelled_y)
        self.assertEqual(canvas.get_panels(), [])

    def test_resize_during_pan_preserves_anchor_paired_edits_and_undo(self):
        from PyQt6.QtCore import QPoint
        win = self._start_live_panel_drag(paired=True)
        canvas = win.canvas
        QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=QPoint(160, 500))
        original = canvas.get_panels()[0].to_dict()
        canvas._undo_stack.clear()
        QTest.mousePress(canvas, Qt.MouseButton.LeftButton, Qt.KeyboardModifier.ControlModifier,
                         QPoint(160, 500))
        self.assertEqual(canvas._mode, "resizing")
        half = canvas.height() / 2
        QTest.keyClick(canvas, Qt.Key.Key_D)
        QTest.qWait(400)
        rect = canvas.get_panels()[0]
        self.assertEqual((rect.x, rect.y, rect.w, rect.h), (20, 300, 140, round(500 + half) - 300))
        QTest.keyClick(canvas, Qt.Key.Key_A)
        QTest.qWait(400)
        self.assertEqual(rect.to_dict(), original)
        QTest.keyClick(canvas, Qt.Key.Key_D)
        QTest.qWait(400)
        QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=QPoint(160, 500))
        resized = rect.to_dict()
        self.assertEqual(canvas.other_panels[0].to_dict(), resized)
        self.assertEqual(len(canvas._undo_stack), 1)
        canvas.undo()
        self.assertEqual(canvas.get_panels()[0].to_dict(), original)
        self.assertEqual(canvas.other_panels[0].to_dict(), original)
        canvas.redo()
        self.assertEqual(canvas.get_panels()[0].to_dict(), resized)
        self.assertEqual(canvas.other_panels[0].to_dict(), resized)

    def test_top_resize_a_and_escape_restore_original(self):
        from PyQt6.QtCore import QPoint
        win = self._start_live_panel_drag()
        canvas = win.canvas
        QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=QPoint(160, 500))
        original = canvas.get_panels()[0].to_dict()
        canvas.offset_y = -200
        QTest.mousePress(canvas, Qt.MouseButton.LeftButton, pos=QPoint(90, 100))
        self.assertEqual(canvas._mode, "resizing")
        QTest.keyClick(canvas, Qt.Key.Key_A)
        QTest.qWait(400)
        rect = canvas.get_panels()[0]
        self.assertEqual((rect.y, rect.h), (100, 400))
        QTest.keyClick(canvas, Qt.Key.Key_Escape)
        QTest.mouseRelease(canvas, Qt.MouseButton.LeftButton, pos=QPoint(90, 100))
        self.assertEqual(canvas.get_panels()[0].to_dict(), original)

    def test_page_boundary_indicators_leave_center_artwork_clear(self):
        from pathlib import Path
        from .canvas import MangaCanvas
        from .strip import StripLayout
        for path in Path(self.source).rglob("*.png"):
            Image.new("RGB", (200, 600), "white").save(path)
        reader = DocumentReader(self.source)
        self.addCleanup(reader.close)
        canvas = MangaCanvas()
        canvas.resize(200, 300)
        canvas.set_strip(reader, StripLayout(reader))
        canvas.set_zoom(1)
        canvas.offset_y = -400
        image = canvas.grab().toImage()
        def color(x, y):
            ratio = image.devicePixelRatio()
            return image.pixelColor(round(x * ratio), round(y * ratio)).name()
        self.assertNotEqual(color(5, 200), "#ffffff")
        self.assertNotEqual(color(195, 200), "#ffffff")
        self.assertNotEqual(color(170, 194), "#ffffff")
        for x in (30, 60, 100):
            self.assertEqual(color(x, 200), "#ffffff")
        canvas.offset_y = -450
        image = canvas.grab().toImage()
        self.assertNotEqual(color(5, 150), "#ffffff")
        self.assertEqual(color(5, 200), "#ffffff")

    def test_full_source_page_shortcut_targets_hover_and_saves_metadata(self):
        import json
        from PyQt6.QtCore import QPoint
        from .dataset_manager import PhraseRect, WordRect
        Image.new("RGB", (120, 600), "green").save(os.path.join(self.source, "vol_2", "10.png"))
        win = self._window()
        manager = win.dataset_mgr
        first = Panel(5, 10, 20, 30)
        previous = [Panel(5, 20, 30, 40), Panel(50, 100, 40, 50)]
        last = Panel(10, 10, 50, 60)
        manager.set_page_frames("webtoon", 1, [first])
        manager.set_page_frames("webtoon", 2, previous)
        manager.set_page_frames("webtoon", 3, [last])
        manager.set_page_frames("webtoon", 2, [Panel(5, 20, 30, 40)], algorithm="safe")
        manager.set_page_text_annotations("webtoon", 2, [PhraseRect(5, 20, 30, 40, 1, "Hello")],
                                          [WordRect(5, 20, 30, 40, 1, "Hello")])
        win._render_current_page()
        win.show()
        win.activateWindow()
        win.canvas.setFocus()
        QTest.qWait(100)
        canvas = win.canvas
        canvas.set_zoom(1)
        canvas.offset_x, canvas.offset_y = 0, -450
        QTest.mouseMove(canvas, QPoint(60, 200))  # page 2, while viewport begins on page 1
        self.app.processEvents()
        self.assertEqual(win.spin_page.value(), 1)
        self.assertTrue(win.act_strip_page.isEnabled())
        QTest.keyClick(canvas, Qt.Key.Key_F, Qt.KeyboardModifier.ShiftModifier)
        annotation = manager.get_panel_annotation("webtoon", 2)
        self.assertEqual([p.to_dict() for p in annotation.frames], [Panel(0, 0, 120, 600).to_dict()])
        self.assertEqual(annotation.illustration_type, "single_page")
        self.assertEqual(manager.get_panel_annotation("webtoon", 1).frames[0].to_dict(), first.to_dict())
        self.assertEqual(manager.get_panel_annotation("webtoon", 3).frames[0].to_dict(), last.to_dict())
        self.assertEqual(manager.get_panel_annotation("webtoon", 2, "safe").frames[0].x, 5)
        self.assertEqual(manager.get_page_annotation("webtoon", 2).phrases[0].text, "Hello")
        canvas.undo()
        self.assertEqual([p.to_dict() for p in annotation.frames], [p.to_dict() for p in previous])
        self.assertIsNone(annotation.illustration_type)
        canvas.redo()
        win.save_dataset(show_dialog=False)
        with open(manager.get_panel_path("webtoon", "smart")) as handle:
            panels = json.load(handle)
        record = next(p for p in panels["pages"] if p["page_index"] == 2)
        self.assertEqual(record["illustration_type"], "single_page")
        self.assertEqual(record["frame"], [Panel(0, 0, 120, 600).to_dict()])
        with open(os.path.join(manager.get_book_dir("webtoon"), "annotation.json")) as handle:
            records = json.load(handle)[0]["pages"]
        self.assertEqual(next(p for p in records if p["page_index"] == 2)["illustration_type"], "single_page")
        reloaded = DatasetManager(win.dataset_dir)
        self.assertEqual(reloaded.get_panel_annotation("webtoon", 2).illustration_type, "single_page")
        self.assertEqual(reloaded.load_book_metadata("webtoon")["type"], "manhwa")

    def test_full_source_page_button_uses_page_control_and_is_manhwa_only(self):
        win = self._window()
        win.show()
        win.activateWindow()
        QTest.qWait(100)
        win.go_to_page(2)
        QTest.qWait(280)
        QTest.mouseClick(win.btn_strip_page, Qt.MouseButton.LeftButton)
        annotation = win.dataset_mgr.get_panel_annotation("webtoon", 2)
        self.assertEqual(annotation.frames[0].to_dict(), Panel(0, 0, 200, 600).to_dict())
        self.assertEqual(annotation.illustration_type, "single_page")
        with patch("tools.manga_annotator.app.QInputDialog.getItem", return_value=("manga", True)):
            win.change_book_type()
        QTest.qWait(80)
        self.assertFalse(win.act_strip_page.isEnabled())
        self.assertTrue(win.btn_strip_page.isHidden())
        win.go_to_page(1)
        before = [p.to_dict() for p in win.canvas.get_panels()]
        QTest.keyClick(win.canvas, Qt.Key.Key_F, Qt.KeyboardModifier.ShiftModifier)
        self.assertEqual([p.to_dict() for p in win.canvas.get_panels()], before)

    def test_f_and_shift_f_mark_page_16_from_gutter(self):
        import json
        from PyQt6.QtCore import QPoint
        self.source = os.path.join(self.root, "chapter")
        os.makedirs(self.source)
        for index in range(16):
            Image.new("RGB", (120 if index == 15 else 200, 600), "white").save(
                os.path.join(self.source, f"{index:02d}.png"))
        win = self._window()
        win.show()
        win.activateWindow()
        win.canvas.setFocus()
        QTest.qWait(100)
        canvas = win.canvas
        canvas.set_zoom(1)
        canvas.offset_x, canvas.offset_y = 0, -8900
        QTest.mouseMove(canvas, QPoint(180, 200))  # gutter beside the narrower final page
        self.app.processEvents()
        for modifiers in (Qt.KeyboardModifier.NoModifier, Qt.KeyboardModifier.ShiftModifier):
            QTest.keyClick(canvas, Qt.Key.Key_F, modifiers)
            annotation = win.dataset_mgr.get_panel_annotation("webtoon", 16)
            self.assertEqual([p.to_dict() for p in annotation.frames], [Panel(0, 0, 120, 600).to_dict()])
            self.assertEqual(annotation.illustration_type, "single_page")
            canvas.undo()
            self.assertEqual(annotation.frames, [])
        QTest.keyClick(canvas, Qt.Key.Key_F)
        win.save_dataset(show_dialog=False)
        with open(win.dataset_mgr.get_panel_path("webtoon", "smart")) as handle:
            pages = json.load(handle)["pages"]
        record = next(page for page in pages if page["page_index"] == 16)
        self.assertEqual(record["illustration_type"], "single_page")
        self.assertEqual(record["frame"], [Panel(0, 0, 120, 600).to_dict()])
        self.assertEqual(win.dataset_mgr.get_panel_annotation("webtoon", 15).frames, [])

    def test_long_strip_paints_only_visible_source_pages(self):
        from types import SimpleNamespace
        from .canvas import MangaCanvas
        from .strip import StripLayout
        reader = DocumentReader(self.source)
        self.addCleanup(reader.close)
        long_reader = SimpleNamespace(pages=[reader.pages[0]] * 10000, total_pages=10000)
        canvas = MangaCanvas()
        canvas.resize(200, 300)
        canvas.set_strip(long_reader, StripLayout(long_reader))
        canvas.set_zoom(1)
        canvas.offset_y = -5000 * 600 - 100
        with patch.object(canvas, "_strip_pixmap", wraps=canvas._strip_pixmap) as images:
            canvas.grab()
        self.assertEqual([call.args[0] for call in images.call_args_list], [5000])
        self.assertEqual(list(canvas._strip_cache), [5000])

    def test_thumbnail_caches_are_bounded_and_preserve_viewport_images(self):
        from types import SimpleNamespace
        from .canvas import MangaCanvas
        from .strip import StripLayout
        reader = DocumentReader(self.source)
        self.addCleanup(reader.close)
        long_reader = SimpleNamespace(pages=[reader.pages[0]] * 100, total_pages=100)
        canvas = MangaCanvas()
        canvas.set_strip(long_reader, StripLayout(long_reader))
        canvas._strip_pixmap(80)
        rect = Panel(0, 550, 200, 100)
        with patch.object(reader.pages[0], "get_pil_image", wraps=reader.pages[0].get_pil_image) as decoded:
            canvas.panel_preview(rect)
            self.assertEqual(decoded.call_count, 2)
            decoded.reset_mock()
            canvas.panel_preview(rect)
            canvas.panel_preview(Panel(10, 550, 180, 100))
            self.assertEqual(decoded.call_count, 0)
        for index in range(40):
            canvas.panel_preview(Panel(0, index * 600, 200, 600))
        self.assertLessEqual(len(canvas._strip_thumbnail_cache), 32)
        self.assertEqual(list(canvas._strip_cache), [80])
        for index in range(600):
            canvas.panel_preview(Panel(0, index, 100, 100))
        self.assertLessEqual(len(canvas._preview_cache), 512)

    def test_sidebar_decodes_visible_rows_and_reuses_thumbnails(self):
        from .strip import StripLayout
        win = self._window()
        win.reader.pages *= 100
        win.strip_layout = StripLayout(win.reader)
        canvas = win.canvas
        canvas.set_strip(win.reader, win.strip_layout)
        canvas.panels = [Panel(0, index * 600, 200, 600) for index in range(300)]
        canvas._collections["panel"] = canvas.panels
        with patch.object(canvas, "panel_preview", wraps=canvas.panel_preview) as previews:
            win._refresh_panel_list()
            self.assertEqual(previews.call_count, 0)
            win.show()
            QTest.qWait(250)
            self.assertGreater(previews.call_count, 0)
            self.assertLessEqual(previews.call_count, win.panel_list.viewport().height() // 80 + 3)
            self.assertTrue(win.panel_list.item(299).icon().isNull())
            previews.reset_mock()
            win._refresh_panel_list()
            QTest.qWait(100)
            self.assertEqual(previews.call_count, 0)
            win.panel_list.scrollToBottom()
            QTest.qWait(250)
            self.assertFalse(win.panel_list.item(299).icon().isNull())
            self.assertTrue(win.panel_list.item(0).icon().isNull())
            self.assertLessEqual(previews.call_count, win.panel_list.viewport().height() // 80 + 3)

    def test_save_defers_hidden_library_refresh(self):
        win = self._window()
        with patch.object(win, "refresh_library", wraps=win.refresh_library) as refresh:
            win.save_dataset(show_dialog=False)
            refresh.assert_not_called()
            win.tabs.setCurrentIndex(0)
            refresh.assert_called_once()

    def test_copy_both_directions_survives_switch_save_and_reload(self):
        win = self._window()
        manager = win.dataset_mgr
        manager.set_page_frames("webtoon", 1, [Panel(10, 550, 100, 120)])
        manager.set_page_frames("webtoon", 2, [Panel(0, 0, 200, 600)])
        manager.set_page_frames("webtoon", 1, [Panel(90, 100, 80, 100)], algorithm="safe")
        manager.set_page_wordless("webtoon", 3)
        manager.save_book_dataset("webtoon")
        win._render_current_page()
        for source, destination in (("smart", "safe"), ("safe", "smart")):
            self.assertEqual(win.panel_algorithm, source)
            # Include unsaved edits and an undo snapshot containing the old other mapping.
            win.canvas.push_undo()
            win.canvas.get_panels()[0].x += 5
            expected = [p.to_dict() for p in win.canvas.get_panels()]
            win.canvas.set_zoom(0.8)
            win.canvas.offset_y = -320
            with patch("tools.manga_annotator.app.secrets.choice", side_effect=["mango", "river"]),                  patch("tools.manga_annotator.app.QInputDialog.getText", side_effect=[("mango", True), ("river", True)]),                  patch("tools.manga_annotator.app.QMessageBox.information"):
                win.copy_panels_to_other_algorithm()
            self.assertEqual([p.to_dict() for p in win.canvas.other_panels], expected)
            self.assertEqual(win.canvas._undo_stack, [])
            self.assertEqual((win.canvas.zoom_factor, win.canvas.offset_y), (0.8, -320))
            win.toggle_panel_algorithm()
            self.assertEqual(win.panel_algorithm, destination)
            self.assertEqual([p.to_dict() for p in win.canvas.get_panels()], expected)
            win.save_dataset(show_dialog=False)
            reloaded = DatasetManager(win.dataset_dir)
            for page in range(1, 4):
                self.assertEqual(
                    [p.to_dict() for p in reloaded.get_panel_annotation("webtoon", page, source).frames],
                    [p.to_dict() for p in reloaded.get_panel_annotation("webtoon", page, destination).frames],
                )
            self.assertTrue(reloaded.get_page_annotation("webtoon", 3).wordless)
            self.assertEqual(reloaded.get_panel_annotation("webtoon", 2, destination).illustration_type, "single_page")
        # Start a new GUI from disk rather than retaining the old dataset manager.
        reopened = AnnotatorMainWindow(dataset_dir=win.dataset_dir,
                                       config_path=os.path.join(self.root, "reopened_config.json"))
        self.addCleanup(reopened.close)
        reopened.open_book_by_title("webtoon")
        self.assertEqual([p.to_dict() for p in reopened.canvas.get_panels()], expected)
        reopened.toggle_panel_algorithm()
        self.assertEqual([p.to_dict() for p in reopened.canvas.get_panels()], expected)

    def test_no_rendered_seam_at_fractional_zoom_and_pan(self):
        from pathlib import Path
        for path in Path(self.source).rglob("*.png"):
            Image.new("RGB", (200, 600), "white").save(path)
        win = self._window()
        canvas = win.canvas
        canvas.resize(200, 300)
        for zoom, pan in ((0.3333, -20.27), (0.4137, -5.6), (0.25, -0.5)):
            canvas.set_zoom(zoom)
            canvas.offset_y = pan
            image = canvas.grab().toImage()
            ratio = image.devicePixelRatio()
            seam = round((600 * zoom + pan) * ratio)
            x = round(30 * ratio)
            for y in range(seam - 2, seam + 3):
                self.assertEqual(image.pixelColor(x, y).name(), "#ffffff", (zoom, pan, y))

    def test_change_existing_book_to_manhwa(self):
        win = self._window()
        with patch("tools.manga_annotator.app.QInputDialog.getItem", return_value=("manga", True)):
            win.change_book_type()
        self.assertIsNone(win.strip_layout)
        self.assertEqual(win.canvas.native_h, 600)
        with patch("tools.manga_annotator.app.QInputDialog.getItem", return_value=("manhwa", True)):
            win.change_book_type()
        self.assertEqual(win.canvas.native_h, 1800)

    def test_second_page_origin_and_page_only_shortcuts(self):
        win = self._window()
        rect = Panel(20, 750, 100, 900)
        win.canvas.panels.append(rect)
        win._commit_current_page_panels()
        saved = win.dataset_mgr.get_panel_annotation("webtoon", 2).frames[0]
        self.assertEqual((saved.y, saved.h), (150, 900))
        win._render_current_page()
        self.assertEqual((win.canvas.get_panels()[0].y, win.canvas.get_panels()[0].h), (750, 900))
        win.set_double_page_illustration()
        self.assertEqual(len(win.canvas.get_panels()), 1)
        self.assertFalse(win.dataset_mgr.get_panel_annotation("webtoon", 1).double_illustration)
        self.assertFalse(win.btn_double_page.isEnabled())
        win.canvas.set_wordless(True)
        self.assertFalse(win.canvas.wordless)

    def test_import_existing_destination_preserves_files(self):
        win = self._window()
        marker = os.path.join(win.dataset_dir, "webtoon", "keep.txt")
        with open(marker, "w") as handle:
            handle.write("preserve")
        with patch("tools.manga_annotator.app.QMessageBox.critical") as message:
            win.import_or_open_file(self.source, friendly_name="webtoon")
            message.assert_called_once()
        self.assertTrue(os.path.exists(marker))
