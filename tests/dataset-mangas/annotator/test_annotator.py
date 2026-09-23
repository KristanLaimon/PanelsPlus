"""
Automated unit and integration tests for the Manga Panel Annotator.
Verifies document loading, panel manipulation, full-page shortcuts,
and Lua PanelsPlus schema compatibility.
"""

import io
import json
import os
import shutil
import subprocess
import tempfile
import unittest
import warnings
import zipfile
from PIL import Image

# Ensure PyQt6 runs headless
os.environ["QT_QPA_PLATFORM"] = "offscreen"

import sys
pkg_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if pkg_dir not in sys.path:
    sys.path.insert(0, pkg_dir)

import fitz  # PyMuPDF
from PyQt6.QtWidgets import QApplication
from PyQt6.QtCore import Qt
from PyQt6.QtTest import QTest

from annotator.document_reader import DocumentReader, natural_sort_key
from annotator.dataset_manager import (
    DatasetManager, Panel, PhraseRect, WordRect, PageAnnotation,
)
from annotator.canvas import MangaCanvas
from annotator.app import AnnotatorMainWindow


class TestAnnotator(unittest.TestCase):

    @classmethod
    def setUpClass(cls):
        cls.app = QApplication.instance() or QApplication([])

    def setUp(self):
        self.test_dir = tempfile.mkdtemp(prefix="annotator_test_")

    def tearDown(self):
        shutil.rmtree(self.test_dir, ignore_errors=True)

    def _create_dummy_image(self, width=400, height=600, color=(255, 255, 255)) -> Image.Image:
        img = Image.new("RGB", (width, height), color=color)
        return img

    def test_natural_sort_key(self):
        items = ["page_10.jpg", "page_1.jpg", "page_2.jpg", "page_20.jpg"]
        sorted_items = sorted(items, key=natural_sort_key)
        self.assertEqual(sorted_items, ["page_1.jpg", "page_2.jpg", "page_10.jpg", "page_20.jpg"])

    def test_document_reader_cbz(self):
        cbz_path = os.path.join(self.test_dir, "test_manga.cbz")
        with zipfile.ZipFile(cbz_path, "w") as zf:
            for i in range(1, 4):
                img = self._create_dummy_image(200, 300)
                buf = io.BytesIO()
                img.save(buf, format="PNG")
                zf.writestr(f"page_{i:02d}.png", buf.getvalue())

        reader = DocumentReader(cbz_path)
        self.assertEqual(reader.total_pages, 3)
        self.assertEqual(reader.book_title, "test_manga")

        page1 = reader.get_page(1)
        self.assertIsNotNone(page1)
        self.assertEqual(page1.native_w, 200)
        self.assertEqual(page1.native_h, 300)

        pil_im = page1.get_pil_image()
        self.assertEqual(pil_im.size, (200, 300))
        reader.close()

    def test_document_reader_pdf(self):
        pdf_path = os.path.join(self.test_dir, "sample.pdf")
        doc = fitz.open()
        for i in range(2):
            page = doc.new_page(width=300, height=450)
            page.draw_rect(fitz.Rect(10, 10, 100, 100), color=(0, 0, 0), fill=(0.5, 0.5, 0.5))
        doc.save(pdf_path)
        doc.close()

        reader = DocumentReader(pdf_path, render_dpi=150)
        self.assertEqual(reader.total_pages, 2)
        page1 = reader.get_page(1)
        self.assertIsNotNone(page1)
        pil_im = page1.get_pil_image()
        self.assertGreater(pil_im.width, 0)
        self.assertGreater(pil_im.height, 0)
        reader.close()

    def test_dataset_manager_export_and_compatibility(self):
        ds_dir = os.path.join(self.test_dir, "dataset")
        mgr = DatasetManager(ds_dir)

        book_title = "custom_series"
        p1 = Panel(10, 20, 200, 300)
        p2 = Panel(10, 340, 200, 250)
        mgr.set_page_frames(book_title, page_index=1, frames=[p1, p2])

        dummy_img = self._create_dummy_image(300, 600)
        mgr.export_page_image(book_title, 1, dummy_img, ext="png")

        json_file = mgr.save_dataset()
        self.assertTrue(os.path.exists(json_file))

        with open(json_file, "r") as f:
            data = json.load(f)

        self.assertEqual(len(data), 1)
        self.assertEqual(data[0]["book_title"], book_title)
        self.assertEqual(len(data[0]["pages"]), 1)
        self.assertEqual(len(data[0]["pages"][0]["frame"]), 2)
        self.assertEqual(data[0]["pages"][0]["frame"][0]["x"], 10)
        self.assertEqual(data[0]["pages"][0]["frame"][0]["y"], 20)

    def test_text_annotation_schema_is_additive_and_round_trips(self):
        pa = PageAnnotation.from_dict({
            "page_index": 4,
            "frame": [{"x": 0, "y": 0, "w": 400, "h": 600}],
        })
        self.assertEqual(len(pa.frames), 1)
        self.assertEqual(pa.phrases, [])
        self.assertEqual(pa.words, [])
        legacy_output = pa.to_dict()
        self.assertNotIn("phrase", legacy_output)
        self.assertNotIn("word", legacy_output)

        pa.phrases = [
            PhraseRect(20, 20, 120, 30, 1, "Hello there"),
            PhraseRect(20, 55, 100, 30, 1, "Hello there"),
        ]
        pa.words = [
            WordRect(22, 22, 35, 20, 1, "Hello"),
            WordRect(62, 22, 50, 20, 1, "there"),
        ]
        encoded = pa.to_dict()
        self.assertEqual(encoded["text_direction"], "ltr")
        self.assertEqual([p["phrase_id"] for p in encoded["phrase"]], [1, 1])
        self.assertEqual([p["text"] for p in encoded["phrase"]], ["Hello there", "Hello there"])
        self.assertEqual([w["phrase_id"] for w in encoded["word"]], [1, 1])
        self.assertEqual([w["text"] for w in encoded["word"]], ["Hello", "there"])

        decoded = PageAnnotation.from_dict(encoded)
        self.assertEqual(len(decoded.phrases), 2)
        self.assertEqual(len(decoded.words), 2)

    def test_text_annotation_validation_and_ltr_order(self):
        mgr = DatasetManager(os.path.join(self.test_dir, "dataset"))
        mgr.set_page_text_annotations(
            "book",
            1,
            [
                PhraseRect(10, 10, 200, 80, 1, "hello world"),
                PhraseRect(10, 100, 200, 50, 2, "again"),
            ],
            [WordRect(90, 20, 40, 20, 1, "world"), WordRect(20, 20, 40, 20, 1, "hello")],
        )
        pa = mgr.get_page_annotation("book", 1)
        self.assertEqual([word.x for word in pa.words], [20, 90])
        self.assertEqual(
            mgr.validate_page_text_annotations("book", 1),
            ["phrases without words: 2"],
        )
        with self.assertRaises(ValueError):
            mgr.save_book_dataset("book")
        pa.words.append(WordRect(20, 110, 40, 20, 2, "again"))
        self.assertEqual(mgr.validate_page_text_annotations("book", 1), [])
        pa.phrases[1].text = ""
        self.assertEqual(
            mgr.validate_page_text_annotations("book", 1),
            ["phrases without text: 2"],
        )

    def test_canvas_modes_and_word_overlap_assignment(self):
        canvas = MangaCanvas()
        phrases = [
            PhraseRect(10, 10, 100, 40, 1),
            PhraseRect(10, 60, 100, 40, 1),
            PhraseRect(150, 10, 100, 90, 2),
        ]
        words = [WordRect(20, 20, 30, 20), WordRect(170, 20, 30, 20), WordRect(300, 20, 30, 20)]
        canvas.set_page(None, [Panel(0, 0, 400, 600)], phrases, words)
        self.assertEqual([word.phrase_id for word in canvas.get_words()], [1, 2, None])

        canvas.set_annotation_mode("phrase")
        self.assertEqual(canvas.panels, canvas.get_phrases())
        QTest.keyClick(canvas, Qt.Key.Key_R)
        self.assertEqual(canvas.current_phrase_id, 2)
        QTest.keyClick(canvas, Qt.Key.Key_R)
        self.assertEqual(canvas.current_phrase_id, 3)
        QTest.keyClick(canvas, Qt.Key.Key_Q)
        self.assertEqual(canvas.current_phrase_id, 2)
        canvas.set_annotation_mode("word")
        self.assertEqual(canvas.panels, canvas.get_words())

    def test_canvas_draws_phrase_fragments_and_assigned_words(self):
        from PyQt6.QtCore import QPointF
        from PyQt6.QtGui import QMouseEvent

        canvas = MangaCanvas()
        canvas.resize(400, 300)
        canvas.native_w = 400
        canvas.native_h = 300
        canvas.set_precision_mode(False)
        canvas.set_phrase_auto_advance_distance(20)
        phrase_prompts = []

        def provide_phrase_text(index):
            phrase_prompts.append(index)
            canvas.set_phrase_text(index, "Good morning")

        canvas.phrase_text_requested.connect(provide_phrase_text)

        def drag(x1, y1, x2, y2):
            canvas.mousePressEvent(QMouseEvent(
                QMouseEvent.Type.MouseButtonPress,
                QPointF(x1, y1),
                Qt.MouseButton.LeftButton,
                Qt.MouseButton.LeftButton,
                Qt.KeyboardModifier.NoModifier,
            ))
            canvas.mouseMoveEvent(QMouseEvent(
                QMouseEvent.Type.MouseMove,
                QPointF(x2, y2),
                Qt.MouseButton.LeftButton,
                Qt.MouseButton.LeftButton,
                Qt.KeyboardModifier.NoModifier,
            ))
            canvas.mouseReleaseEvent(QMouseEvent(
                QMouseEvent.Type.MouseButtonRelease,
                QPointF(x2, y2),
                Qt.MouseButton.LeftButton,
                Qt.MouseButton.NoButton,
                Qt.KeyboardModifier.NoModifier,
            ))

        canvas.set_annotation_mode("phrase")
        canvas.current_phrase_id = 4
        drag(20, 20, 180, 60)
        drag(20, 70, 150, 110)
        drag(300, 200, 380, 240)
        self.assertEqual([p.phrase_id for p in canvas.get_phrases()], [4, 4, 5])
        self.assertEqual(
            [p.text for p in canvas.get_phrases()],
            ["Good morning", "Good morning", "Good morning"],
        )
        self.assertEqual(phrase_prompts, [0, 2])

        canvas.set_annotation_mode("word")
        drag(25, 25, 70, 50)
        self.assertEqual(len(canvas.get_words()), 1)
        self.assertEqual(canvas.get_words()[0].phrase_id, 4)

    def test_selected_phrase_box_can_be_reused_for_one_word(self):
        win = AnnotatorMainWindow(dataset_dir=os.path.join(self.test_dir, "copy_word_dataset"))
        phrase = PhraseRect(20, 30, 70, 24, 2, "ONE WORD")
        win.canvas.set_page(None, [], [phrase], [])
        win.canvas.set_annotation_mode("phrase")
        win.canvas.select_panel(0)
        self.assertTrue(win.btn_phrase_to_word.isEnabled())

        prompts = []

        win._ask_annotation_text = lambda *args: (False, "")
        win._add_word_from_selected_phrase()
        self.assertEqual(win.canvas.get_words(), [])

        def answer(title, label, current_text):
            prompts.append(current_text)
            return True, "WORD"
        win._ask_annotation_text = answer
        win._add_word_from_selected_phrase()

        self.assertEqual(prompts, [""])
        self.assertEqual(len(win.canvas.get_phrases()), 1)
        self.assertEqual(len(win.canvas.get_words()), 1)
        word = win.canvas.get_words()[0]
        self.assertEqual((word.x, word.y, word.w, word.h), (20, 30, 70, 24))
        self.assertEqual((word.phrase_id, word.text), (2, "WORD"))
        win._add_word_from_selected_phrase()
        self.assertEqual(len(win.canvas.get_words()), 1)
        self.assertEqual(prompts, [""])
        win.close()

    def test_word_text_prompt_autofocuses_and_enter_saves(self):
        from PyQt6.QtCore import QTimer
        from PyQt6.QtWidgets import QLineEdit

        win = AnnotatorMainWindow(dataset_dir=os.path.join(self.test_dir, "prompt_dataset"))
        word = WordRect(10, 10, 40, 20, 1)
        win.canvas._collections["word"] = [word]
        win.canvas.set_annotation_mode("word")
        observed = {}

        def type_and_confirm():
            dialog = QApplication.activeModalWidget()
            line_edit = dialog.findChild(QLineEdit)
            observed["focused"] = line_edit.hasFocus()
            line_edit.setText("¡Hola!")
            QTest.keyClick(line_edit, Qt.Key.Key_Return)

        QTimer.singleShot(20, type_and_confirm)
        win._prompt_word_text(0, discard_on_cancel=False)
        self.assertTrue(observed["focused"])
        self.assertEqual(word.text, "¡Hola!")
        win.close()

    def test_cancel_new_word_prompt_discards_rectangle(self):
        from PyQt6.QtCore import QTimer

        win = AnnotatorMainWindow(dataset_dir=os.path.join(self.test_dir, "cancel_prompt_dataset"))
        win.canvas._collections["word"] = [WordRect(10, 10, 40, 20, 1)]
        win.canvas.set_annotation_mode("word")

        QTimer.singleShot(20, lambda: QApplication.activeModalWidget().reject())
        win._prompt_word_text(0, discard_on_cancel=True)
        self.assertEqual(win.canvas.get_words(), [])
        win.close()

    def test_edit_text_has_left_hand_t_shortcut(self):
        from PyQt6.QtGui import QAction

        win = AnnotatorMainWindow(dataset_dir=os.path.join(self.test_dir, "shortcut_dataset"))
        shortcuts = {
            action.text(): action.shortcut().toString()
            for action in win.findChildren(QAction)
        }
        self.assertEqual(shortcuts.get("Edit Selected Text"), "T")
        self.assertEqual(shortcuts.get("Previous Phrase ID"), "Q")
        self.assertEqual(shortcuts.get("Next Phrase ID"), "R")
        self.assertEqual(shortcuts.get("Use Selected Phrase Box as Word"), "W")
        win.close()

    def test_phrase_distance_slider_persists_local_config(self):
        config_path = os.path.join(self.test_dir, "manga-annotator.config.json")
        dataset_path = os.path.join(self.test_dir, "config_dataset")
        win = AnnotatorMainWindow(dataset_dir=dataset_path, config_path=config_path)
        self.assertEqual(win.slider_phrase_distance.value(), 120)
        win.slider_phrase_distance.setValue(275)
        self.assertEqual(win.canvas.phrase_auto_advance_distance, 275)
        win.close()

        with open(config_path, "r", encoding="utf-8") as config_file:
            saved = json.load(config_file)
        self.assertEqual(saved["phrase_auto_advance_distance"], 275)

        reopened = AnnotatorMainWindow(dataset_dir=dataset_path, config_path=config_path)
        self.assertEqual(reopened.slider_phrase_distance.value(), 275)
        self.assertEqual(reopened.canvas.phrase_auto_advance_distance, 275)
        reopened.close()

    def test_canvas_panel_operations(self):
        canvas = MangaCanvas()
        canvas.native_w = 800
        canvas.native_h = 1200

        # Full page panel
        canvas.add_full_page_panel()
        self.assertEqual(len(canvas.panels), 1)
        self.assertEqual(canvas.panels[0].x, 0)
        self.assertEqual(canvas.panels[0].y, 0)
        self.assertEqual(canvas.panels[0].w, 800)
        self.assertEqual(canvas.panels[0].h, 1200)

        # Add second panel
        p2 = Panel(50, 50, 300, 400)
        canvas.panels.append(p2)
        self.assertEqual(len(canvas.panels), 2)

        # Move panel up (swap order)
        canvas.move_panel_up(1)
        self.assertEqual(canvas.panels[0].x, 50)
        self.assertEqual(canvas.panels[1].x, 0)

        # Move panel down
        canvas.move_panel_down(0)
        self.assertEqual(canvas.panels[0].x, 0)
        self.assertEqual(canvas.panels[1].x, 50)

        # Delete selected
        canvas.select_panel(0)
        canvas.delete_selected_panel()
        self.assertEqual(len(canvas.panels), 1)
        self.assertEqual(canvas.panels[0].x, 50)

        # Clear
        canvas.clear_panels()
        self.assertEqual(len(canvas.panels), 0)

    def test_extract_all_pages_ordered(self):
        cbz_path = os.path.join(self.test_dir, "manga_extract.cbz")
        with zipfile.ZipFile(cbz_path, "w") as zf:
            for i in range(5):
                img = self._create_dummy_image(200, 300)
                buf = io.BytesIO()
                img.save(buf, format="PNG")
                zf.writestr(f"p_{i}.png", buf.getvalue())

        reader = DocumentReader(cbz_path)
        out_dir = os.path.join(self.test_dir, "dataset", "manga_extract")
        extracted = reader.extract_all_pages(out_dir)
        self.assertEqual(len(extracted), 5)
        self.assertTrue(os.path.exists(os.path.join(out_dir, "00.png")))
        self.assertTrue(os.path.exists(os.path.join(out_dir, "01.png")))
        self.assertTrue(os.path.exists(os.path.join(out_dir, "04.png")))
        reader.close()

    def test_extract_all_pages_cancellation(self):
        cbz_path = os.path.join(self.test_dir, "manga_cancel.cbz")
        with zipfile.ZipFile(cbz_path, "w") as zf:
            for i in range(10):
                img = self._create_dummy_image(200, 300)
                buf = io.BytesIO()
                img.save(buf, format="PNG")
                zf.writestr(f"p_{i}.png", buf.getvalue())

        reader = DocumentReader(cbz_path)
        out_dir = os.path.join(self.test_dir, "dataset", "manga_cancel")

        # Cancel after 2 pages
        def cancel_callback(curr, tot):
            if curr >= 2:
                return False
            return True

        extracted = reader.extract_all_pages(out_dir, progress_callback=cancel_callback)
        # Should have stopped early (less than total 10 pages)
        self.assertLess(len(extracted), 10)
        self.assertFalse(os.path.exists(os.path.join(out_dir, "09.png")))
        reader.close()

    def test_recent_books_and_progress(self):
        ds_dir = os.path.join(self.test_dir, "dataset")
        mgr = DatasetManager(ds_dir)

        book_title = "naruto_ch01"
        book_dir = mgr.get_book_dir(book_title)
        os.makedirs(book_dir, exist_ok=True)

        # Create 4 pages: 00.png to 03.png
        for i in range(4):
            img = self._create_dummy_image(100, 150)
            img.save(os.path.join(book_dir, f"{i:02d}.png"))

        # Annotate 2 of the 4 pages (50% progress)
        mgr.set_page_frames(book_title, 1, [Panel(10, 10, 50, 50)])
        mgr.set_page_frames(book_title, 2, [Panel(10, 10, 50, 50)])
        mgr.save_book_dataset(book_title)

        recent = mgr.get_recent_books()
        self.assertEqual(len(recent), 1)
        self.assertEqual(recent[0]["book_title"], book_title)
        self.assertEqual(recent[0]["type"], "manga")
        self.assertEqual(recent[0]["total_pages"], 4)
        self.assertEqual(recent[0]["annotated_pages"], 2)
        self.assertEqual(recent[0]["progress_percent"], 50)
        self.assertFalse(recent[0]["finished"])

        # Mark finished
        mgr.mark_book_finished(book_title, True)
        recent_after = mgr.get_recent_books()
        self.assertTrue(recent_after[0]["finished"])
        self.assertEqual(recent_after[0]["progress_percent"], 100)

    def test_metadata_type_is_limited_to_manga_or_comic(self):
        ds_dir = os.path.join(self.test_dir, "dataset")
        mgr = DatasetManager(ds_dir)

        mgr.save_book_metadata("manga_book", {"book_title": "manga_book", "type": "manga"})
        mgr.save_book_metadata("comic_book", {"book_title": "comic_book", "type": "comic"})
        self.assertEqual(mgr.load_book_metadata("manga_book")["type"], "manga")
        self.assertEqual(mgr.load_book_metadata("comic_book")["type"], "comic")

        with self.assertRaises(ValueError):
            mgr.save_book_metadata("invalid_book", {"book_title": "invalid_book", "type": "novel"})

    def test_comic_color_metadata_is_validated_and_preserved(self):
        mgr = DatasetManager(os.path.join(self.test_dir, "dataset"))
        for mode in ("true_b/w", "colorless_b/w", "color"):
            mgr.save_book_metadata("comic", {"type": "comic", "color_mode": mode})
            mgr.mark_book_finished("comic")
            mgr.update_last_opened("comic", 2)
            self.assertEqual(mgr.load_book_metadata("comic")["color_mode"], mode)
        for metadata in (
            {"type": "manga", "color_mode": "true_b/w"},
            {"type": "comic", "color_mode": "grayscale"},
        ):
            with self.assertRaises(ValueError):
                mgr.save_book_metadata("invalid", metadata)

    def test_gitignore_dmca_rule(self):
        import subprocess
        # Check that 00.png, 01.png, 02.png are kept, and 03.png+ are ignored by git
        ds_dir = "tests/dataset-mangas/dataset"
        test_book = os.path.join(ds_dir, "test_dmca_book")
        os.makedirs(test_book, exist_ok=True)
        try:
            for i in range(6):
                with open(os.path.join(test_book, f"{i:02d}.png"), "w") as f:
                    f.write("x")

            res0 = subprocess.run(["git", "check-ignore", os.path.join(test_book, "00.png")], capture_output=True)
            self.assertNotEqual(res0.returncode, 0, "00.png should NOT be ignored")

            res2 = subprocess.run(["git", "check-ignore", os.path.join(test_book, "02.png")], capture_output=True)
            self.assertNotEqual(res2.returncode, 0, "02.png should NOT be ignored")

            res3 = subprocess.run(["git", "check-ignore", os.path.join(test_book, "03.png")], capture_output=True)
            self.assertEqual(res3.returncode, 0, "03.png SHOULD be ignored by git")

            res4 = subprocess.run(["git", "check-ignore", os.path.join(test_book, "04.png")], capture_output=True)
            self.assertEqual(res4.returncode, 0, "04.png SHOULD be ignored by git")
        finally:
            shutil.rmtree(test_book, ignore_errors=True)

    def test_annotator_window_load_and_save(self):
        cbz_path = os.path.join(self.test_dir, "book.cbz")
        with zipfile.ZipFile(cbz_path, "w") as zf:
            img = self._create_dummy_image(400, 600)
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            zf.writestr("p1.png", buf.getvalue())

        ds_dir = os.path.join(self.test_dir, "my_dataset")
        win = AnnotatorMainWindow(dataset_dir=ds_dir)
        win.import_or_open_file(cbz_path, friendly_name="test_book")
        self.assertEqual(win.book_title, "test_book")

        # Add full page panel via shortcut
        win.canvas.add_full_page_panel()
        self.assertEqual(len(win.canvas.panels), 1)

        # Save dataset
        win.save_dataset(show_dialog=False)

        # Check book annotation.json generated
        annotation_file = os.path.join(ds_dir, "test_book", "annotation.json")
        self.assertTrue(os.path.exists(annotation_file))
        with open(annotation_file, "r") as f:
            content = json.load(f)
        self.assertEqual(content[0]["book_title"], "test_book")
        self.assertEqual(content[0]["annotation_schema_version"], 2)
        self.assertEqual(len(content[0]["pages"][0]["frame"]), 1)
        with open(os.path.join(ds_dir, "test_book", "metadata.json"), "r") as f:
            metadata = json.load(f)
        self.assertEqual(metadata["annotation_layers"], ["panel", "phrase", "word"])
        self.assertEqual(metadata["text_direction"], "ltr")
        win.close()

    def test_double_page_illustration_is_saved_and_invalidated_when_edited(self):
        cbz_path = os.path.join(self.test_dir, "wide_spread.cbz")
        with zipfile.ZipFile(cbz_path, "w") as zf:
            img = self._create_dummy_image(800, 400)
            buf = io.BytesIO()
            img.save(buf, format="PNG")
            zf.writestr("p1.png", buf.getvalue())

        ds_dir = os.path.join(self.test_dir, "double_page_dataset")
        win = AnnotatorMainWindow(dataset_dir=ds_dir)
        win.import_or_open_file(cbz_path, friendly_name="wide_spread")
        win.canvas.setFocus()
        QTest.keyClick(win.canvas, Qt.Key.Key_S)
        self.app.processEvents()

        pa = win.dataset_mgr.get_page_annotation("wide_spread", 1)
        self.assertEqual(pa.illustration_type, PageAnnotation.DOUBLE_PAGE_ILLUSTRATION)
        self.assertEqual(len(win.canvas.panels), 1)
        self.assertEqual(
            win.canvas.panels[0].to_dict(),
            {"x": 0, "y": 0, "w": 800, "h": 400},
        )

        win.save_dataset(show_dialog=False)
        with open(os.path.join(ds_dir, "wide_spread", "annotation.json"), "r") as f:
            content = json.load(f)
        self.assertEqual(content[0]["pages"][0]["illustration_type"], "double_page")

        lua_code = f'''
        local Manifest = require("tests.dataset-mangas.dataset_manifest")
        local books = Manifest.loadManga("{ds_dir}")
        assert(books[1].pages[1].illustration_type == "double_page")
        '''
        res = subprocess.run(["lua", "-e", lua_code], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"Lua failed: {res.stderr}")

        # A resized frame is no longer a valid whole-page double-page spread.
        win.canvas.panels[0].w -= 1
        win._on_panels_changed()
        self.assertIsNone(pa.illustration_type)
        win.close()

    def test_lua_manifest_interop(self):
        ds_dir = os.path.join(self.test_dir, "lua_interop")
        mgr = DatasetManager(ds_dir)
        book_dir = mgr.get_book_dir("interop_book")
        os.makedirs(book_dir, exist_ok=True)
        img = self._create_dummy_image(400, 600)
        img.save(os.path.join(book_dir, "00.png"))

        p1 = Panel(50, 100, 300, 400)
        mgr.set_page_frames("interop_book", 1, [p1])
        mgr.set_page_text_annotations(
            "interop_book",
            1,
            [PhraseRect(70, 120, 180, 70, 1, "hello")],
            [WordRect(75, 125, 60, 25, 1, "hello")],
        )
        mgr.save_book_dataset("interop_book")

        lua_code = f'''
        local Manifest = require("tests.dataset-mangas.dataset_manifest")
        local books = Manifest.loadManga("{ds_dir}")
        assert(#books == 1)
        assert(books[1].book_title == "interop_book")
        assert(#books[1].pages == 1)
        assert(books[1].pages[1].frames[1].x == 50)
        assert(#books[1].pages[1].phrases == 1)
        assert(books[1].pages[1].phrases[1].phrase_id == 1)
        assert(books[1].pages[1].phrases[1].text == "hello")
        assert(#books[1].pages[1].words == 1)
        assert(books[1].pages[1].words[1].phrase_id == 1)
        assert(books[1].pages[1].words[1].text == "hello")
        assert(books[1].pages[1].text_direction == "ltr")
        assert(books[1].pages[1].illustration_type == "single_page")
        '''
        res = subprocess.run(["lua", "-e", lua_code], capture_output=True, text=True)
        self.assertEqual(res.returncode, 0, f"Lua failed: {res.stderr}")

    def test_canvas_undo_redo(self):
        canvas = MangaCanvas()
        canvas.native_w = 800
        canvas.native_h = 1200

        self.assertEqual(len(canvas.panels), 0)

        # 1. Add full page panel
        canvas.add_full_page_panel()
        self.assertEqual(len(canvas.panels), 1)

        # 2. Add second panel
        canvas.push_undo()
        canvas.panels.append(Panel(10, 10, 100, 100))
        self.assertEqual(len(canvas.panels), 2)

        # 3. Undo second panel
        canvas.undo()
        self.assertEqual(len(canvas.panels), 1)

        # 4. Undo first panel
        canvas.undo()
        self.assertEqual(len(canvas.panels), 0)

        # 5. Redo first panel
        canvas.redo()
        self.assertEqual(len(canvas.panels), 1)

        # 6. Redo second panel
        canvas.redo()
        self.assertEqual(len(canvas.panels), 2)

    def test_canvas_precision_mode(self):
        canvas = MangaCanvas()
        self.assertTrue(canvas.precision_mouse_enabled)

        canvas.set_precision_mode(False)
        self.assertFalse(canvas.precision_mouse_enabled)

        canvas.set_precision_mode(True)
        self.assertTrue(canvas.precision_mouse_enabled)

    def test_rectangle_creation_aligned(self):
        from PyQt6.QtCore import QPointF, Qt, QRect
        from PyQt6.QtGui import QMouseEvent, QPixmap
        canvas = MangaCanvas()
        canvas.resize(800, 1000)
        canvas.native_w = 400
        canvas.native_h = 600
        canvas.zoom_factor = 1.0
        canvas.offset_x = 0.0
        canvas.offset_y = 0.0

        # Simulate mouse press at (50, 50)
        press_ev = QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            QPointF(50, 50),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mousePressEvent(press_ev)
        self.assertEqual(canvas._mode, "drawing")

        # Simulate mouse move to (250, 300)
        move_ev = QMouseEvent(
            QMouseEvent.Type.MouseMove,
            QPointF(250, 300),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mouseMoveEvent(move_ev)
        self.assertIsNotNone(canvas._current_image_box)
        # Verify rectangle is exactly aligned with cursor (50, 50) -> (250, 300)
        self.assertEqual(canvas._current_image_box, (50, 50, 250, 300))

        # Simulate release at (250, 300)
        rel_ev = QMouseEvent(
            QMouseEvent.Type.MouseButtonRelease,
            QPointF(250, 300),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.NoButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mouseReleaseEvent(rel_ev)
        self.assertEqual(len(canvas.panels), 1)
        p = canvas.panels[0]
        # Must be 100% aligned with where the mouse was moved and released
        self.assertEqual((p.x, p.y, p.w, p.h), (50, 50, 200, 250))

    def test_fit_to_width_on_open(self):
        from PyQt6.QtCore import QRect
        canvas = MangaCanvas()
        canvas.resize(900, 1200)
        canvas.native_w = 450
        canvas.native_h = 700

        # Call fit_to_width on container rect
        canvas.fit_to_width(canvas.rect())

        # Rendered image width (native_w * zoom) should fill 100% of container width (900)
        self.assertAlmostEqual(canvas.native_w * canvas.zoom_factor, 900.0)
        self.assertEqual(canvas.offset_x, 0.0)
        self.assertEqual(canvas.offset_y, 0.0)

    def test_keyboard_arrow_nudge(self):
        from PyQt6.QtGui import QKeyEvent
        from PyQt6.QtCore import Qt
        canvas = MangaCanvas()
        canvas.native_w = 500
        canvas.native_h = 500
        canvas.panels = [Panel(100, 100, 50, 50)]
        canvas.selected_panel_index = 0

        # Nudge right by 1px
        ev_right = QKeyEvent(QKeyEvent.Type.KeyPress, Qt.Key.Key_Right, Qt.KeyboardModifier.NoModifier)
        canvas.keyPressEvent(ev_right)
        self.assertEqual(canvas.panels[0].x, 101)

        # Nudge right with Shift by 5px
        ev_shift_right = QKeyEvent(QKeyEvent.Type.KeyPress, Qt.Key.Key_Right, Qt.KeyboardModifier.ShiftModifier)
        canvas.keyPressEvent(ev_shift_right)
        self.assertEqual(canvas.panels[0].x, 106)

        # Resize with Alt+Right by 1px
        ev_alt_right = QKeyEvent(QKeyEvent.Type.KeyPress, Qt.Key.Key_Right, Qt.KeyboardModifier.AltModifier)
        canvas.keyPressEvent(ev_alt_right)
        self.assertEqual(canvas.panels[0].w, 51)

    def test_wheel_scroll_vs_ctrl_zoom(self):
        from PyQt6.QtGui import QWheelEvent
        from PyQt6.QtCore import QPointF, QPoint, Qt
        canvas = MangaCanvas()
        canvas.resize(800, 1000)
        canvas.native_w = 400
        canvas.native_h = 600
        canvas.zoom_factor = 1.0
        canvas.offset_x = 0.0
        canvas.offset_y = 0.0

        # Normal mouse wheel (scroll down): should scroll offset_y, NOT zoom
        wheel_ev = QWheelEvent(
            QPointF(200, 200),
            QPointF(200, 200),
            QPoint(0, 0),
            QPoint(0, -120),
            Qt.MouseButton.NoButton,
            Qt.KeyboardModifier.NoModifier,
            Qt.ScrollPhase.NoScrollPhase,
            False
        )
        canvas.wheelEvent(wheel_ev)
        self.assertEqual(canvas.zoom_factor, 1.0)
        self.assertLess(canvas.offset_y, 0.0)

        # Ctrl + mouse wheel (zoom in): should modify zoom_factor
        old_zoom = canvas.zoom_factor
        ctrl_wheel_ev = QWheelEvent(
            QPointF(200, 200),
            QPointF(200, 200),
            QPoint(0, 0),
            QPoint(0, 120),
            Qt.MouseButton.NoButton,
            Qt.KeyboardModifier.ControlModifier,
            Qt.ScrollPhase.NoScrollPhase,
            False
        )
        canvas.wheelEvent(ctrl_wheel_ev)
        self.assertGreater(canvas.zoom_factor, old_zoom)

    def test_wheel_drag_synchronous_update(self):
        from PyQt6.QtGui import QMouseEvent, QWheelEvent
        from PyQt6.QtCore import QPointF, QPoint, Qt
        canvas = MangaCanvas()
        canvas.resize(800, 1000)
        canvas.native_w = 400
        canvas.native_h = 600
        canvas.zoom_factor = 1.0
        canvas.offset_x = 0.0
        canvas.offset_y = 0.0

        # Start drawing
        press_ev = QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            QPointF(50, 50),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mousePressEvent(press_ev)
        self.assertEqual(canvas._mode, "drawing")

        # Scroll while drawing
        wheel_ev = QWheelEvent(
            QPointF(100, 100),
            QPointF(100, 100),
            QPoint(0, 0),
            QPoint(0, -120),
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier,
            Qt.ScrollPhase.NoScrollPhase,
            False
        )
        canvas.wheelEvent(wheel_ev)

        # Drawing box must still exist and start anchor must be preserved at (50, 50)
        self.assertIsNotNone(canvas._current_image_box)
        self.assertEqual(canvas._current_image_box[0], 50)
        self.assertEqual(canvas._current_image_box[1], 50)

    def test_alt_disables_magnetic_snap(self):
        canvas = MangaCanvas()
        canvas.native_w = 500
        canvas.native_h = 500
        canvas.set_precision_mode(True)

        # Near page edge (x=3, within snap radius)
        snapped_x, snapped_y = canvas._apply_precision_snap(3, 3, is_alt_held=False)
        self.assertEqual(snapped_x, 0)
        self.assertEqual(snapped_y, 0)

        # Holding Alt must bypass snap completely
        free_x, free_y = canvas._apply_precision_snap(3, 3, is_alt_held=True)
        self.assertEqual(free_x, 3)
        self.assertEqual(free_y, 3)

    def test_snap_outside_black_border(self):
        from PyQt6.QtGui import QImage, QPainter, QColor, QPixmap
        # Create 400x400 white canvas with a 4px black panel border
        # Horizontal stroke: y=100..103 across x=50..250
        # Vertical stroke: x=150..153 across y=50..250
        img = QImage(400, 400, QImage.Format.Format_Grayscale8)
        img.fill(255)  # white paper/gutter
        painter = QPainter(img)
        painter.setPen(QColor(0, 0, 0))
        # Draw 4px horizontal black line: y=100, 101, 102, 103
        for dy in range(4):
            painter.drawLine(50, 100 + dy, 250, 100 + dy)
        # Draw 4px vertical black line: x=150, 151, 152, 153
        for dx in range(4):
            painter.drawLine(150 + dx, 50, 150 + dx, 250)
        painter.end()

        canvas = MangaCanvas()
        canvas.set_page(QPixmap.fromImage(img), [])
        canvas.set_precision_mode(True)

        # Test snapping horizontal border (y=100..103)
        # 1. When bottom border moves near line, it should snap OUTSIDE (y=104, in gutter below)
        _, snap_bottom = canvas._apply_precision_snap(100, 102, is_alt_held=False, side_y="bottom")
        self.assertEqual(snap_bottom, 104)

        # 2. When top border moves near line, it should snap OUTSIDE (y=100, in gutter above)
        _, snap_top = canvas._apply_precision_snap(100, 101, is_alt_held=False, side_y="top")
        self.assertEqual(snap_top, 100)

        # Test snapping vertical border (x=150..153)
        # 3. When right border moves near line, it should snap OUTSIDE (x=154, in gutter right)
        snap_right, _ = canvas._apply_precision_snap(152, 180, is_alt_held=False, side_x="right")
        self.assertEqual(snap_right, 154)

        # 4. When left border moves near line, it should snap OUTSIDE (x=150, in gutter left)
        snap_left, _ = canvas._apply_precision_snap(151, 180, is_alt_held=False, side_x="left")
        self.assertEqual(snap_left, 150)

    def test_mouse_cursor_always_visible_on_hover(self):
        from PyQt6.QtCore import QPointF, Qt
        from PyQt6.QtGui import QMouseEvent, QCursor
        canvas = MangaCanvas()
        canvas.resize(800, 600)
        canvas.set_precision_mode(True)

        # Mouse move without dragging (hover state on empty canvas)
        ev = QMouseEvent(
            QMouseEvent.Type.MouseMove,
            QPointF(200, 200),
            Qt.MouseButton.NoButton,
            Qt.MouseButton.NoButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mouseMoveEvent(ev)

        # Default cursor must be the normal visible ArrowCursor
        self.assertEqual(canvas.cursor().shape(), Qt.CursorShape.ArrowCursor)

    def test_drag_move_existing_panel(self):
        from PyQt6.QtCore import QPointF, Qt
        from PyQt6.QtGui import QMouseEvent
        canvas = MangaCanvas()
        canvas.resize(800, 800)
        canvas.native_w = 400
        canvas.native_h = 400
        canvas.zoom_factor = 1.0
        canvas.offset_x = 0.0
        canvas.offset_y = 0.0
        canvas.panels = [Panel(50, 50, 100, 100)]
        canvas.selected_panel_index = -1

        # Press inside existing panel at (80, 80)
        press_ev = QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            QPointF(80, 80),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mousePressEvent(press_ev)
        self.assertEqual(canvas._mode, "moving")
        self.assertEqual(canvas.selected_panel_index, 0)

        # Drag by +30px X, +40px Y to (110, 120)
        move_ev = QMouseEvent(
            QMouseEvent.Type.MouseMove,
            QPointF(110, 120),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mouseMoveEvent(move_ev)
        self.assertEqual(canvas.panels[0].x, 80)  # 50 + 30
        self.assertEqual(canvas.panels[0].y, 90)  # 50 + 40
        self.assertEqual(canvas.panels[0].w, 100)
        self.assertEqual(canvas.panels[0].h, 100)

        # Release mouse
        rel_ev = QMouseEvent(
            QMouseEvent.Type.MouseButtonRelease,
            QPointF(110, 120),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.NoButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mouseReleaseEvent(rel_ev)
        self.assertEqual(canvas._mode, "idle")
        self.assertEqual((canvas.panels[0].x, canvas.panels[0].y), (80, 90))

    def test_drag_resize_existing_panel(self):
        from PyQt6.QtCore import QPointF, Qt
        from PyQt6.QtGui import QMouseEvent
        canvas = MangaCanvas()
        canvas.resize(800, 800)
        canvas.native_w = 400
        canvas.native_h = 400
        canvas.zoom_factor = 1.0
        canvas.offset_x = 0.0
        canvas.offset_y = 0.0
        canvas.panels = [Panel(50, 50, 100, 100)]
        canvas.selected_panel_index = 0  # panel selected so handles are active

        # Handle BR is at (50 + 100, 50 + 100) = (150, 150)
        press_ev = QMouseEvent(
            QMouseEvent.Type.MouseButtonPress,
            QPointF(150, 150),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mousePressEvent(press_ev)
        self.assertEqual(canvas._mode, "resizing")

        # Drag BR handle by +20px X, +30px Y to (170, 180)
        move_ev = QMouseEvent(
            QMouseEvent.Type.MouseMove,
            QPointF(170, 180),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.LeftButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mouseMoveEvent(move_ev)
        self.assertEqual(canvas.panels[0].w, 120)
        self.assertEqual(canvas.panels[0].h, 130)

        # Release mouse
        rel_ev = QMouseEvent(
            QMouseEvent.Type.MouseButtonRelease,
            QPointF(170, 180),
            Qt.MouseButton.LeftButton,
            Qt.MouseButton.NoButton,
            Qt.KeyboardModifier.NoModifier
        )
        canvas.mouseReleaseEvent(rel_ev)
        self.assertEqual(canvas._mode, "idle")
        self.assertEqual((canvas.panels[0].w, canvas.panels[0].h), (120, 130))

    def test_default_image_paths_en(self):
        pa = PageAnnotation(page_index=1, image_rel_path="my_book/00.png")
        d = pa.to_dict()
        self.assertIn("image_paths", d)
        self.assertIn("en", d["image_paths"])
        self.assertNotIn("ja", d["image_paths"])
        self.assertEqual(d["image_paths"]["en"], "my_book/00.png")

        # Backwards compatibility when reading older ja dictionaries
        legacy_d = {
            "page_index": 2,
            "image_paths": {"ja": "legacy_book/01.png"},
            "frame": [{"x": 10, "y": 20, "w": 100, "h": 200}]
        }
        loaded_pa = PageAnnotation.from_dict(legacy_d)
        self.assertEqual(loaded_pa.image_rel_path, "legacy_book/01.png")
        self.assertEqual(len(loaded_pa.frames), 1)
        self.assertEqual(
            loaded_pa.effective_illustration_type,
            PageAnnotation.SINGLE_PAGE_ILLUSTRATION,
        )
        self.assertEqual(loaded_pa.to_dict()["illustration_type"], "single_page")

    def test_page_annotation_preserves_double_page_illustration_type(self):
        raw = {
            "page_index": 1,
            "illustration_type": "double_page",
            "frame": [{"x": 0, "y": 0, "w": 800, "h": 400}],
        }
        pa = PageAnnotation.from_dict(raw)
        self.assertEqual(pa.illustration_type, PageAnnotation.DOUBLE_PAGE_ILLUSTRATION)
        self.assertEqual(pa.copy().to_dict()["illustration_type"], "double_page")

    def test_annotator_uses_dark_theme_by_default(self):
        win = AnnotatorMainWindow(dataset_dir=os.path.join(self.test_dir, "theme_dataset"))
        self.assertTrue(self.app.property("panelsplus_dark_theme"))
        self.assertIn("background-color: #1e1e1e", self.app.styleSheet())
        win.close()

    def test_bloom_into_you_dataset_100_percent_coverage(self):
        real_ds_dir = "tests/dataset-mangas/dataset"
        book_title = "Bloom_Into_You_Vol_8"
        expected_page_count = 213
        expected_image_paths = [
            os.path.join(real_ds_dir, book_title, f"{page_idx:02d}.png")
            for page_idx in range(expected_page_count)
        ]
        missing_image_paths = [path for path in expected_image_paths if not os.path.isfile(path)]
        if missing_image_paths:
            available_count = expected_page_count - len(missing_image_paths)
            warning = (
                f"Skipping {book_title} full-coverage test: dataset is incomplete "
                f"({available_count}/{expected_page_count} page images available; "
                f"first missing image: {missing_image_paths[0]})."
            )
            warnings.warn(warning, RuntimeWarning)
            self.skipTest(warning)

        mgr = DatasetManager(real_ds_dir)
        self.assertIn(book_title, mgr.books)

        book_pages = mgr.books[book_title]
        self.assertEqual(len(book_pages), expected_page_count, "Expected exactly 213 pages for Bloom Into You")

        meta = mgr.load_book_metadata(book_title)
        self.assertEqual(meta.get("total_pages"), expected_page_count)
        self.assertTrue(meta.get("finished"))

        total_panels = 0
        for page_idx in range(1, expected_page_count + 1):
            self.assertIn(page_idx, book_pages, f"Page index {page_idx} missing from dataset")
            pa = book_pages[page_idx]
            self.assertGreaterEqual(len(pa.frames), 1, f"Page {page_idx} must have >= 1 panel")
            total_panels += len(pa.frames)

            # Check image path exists on disk
            img_path = os.path.join(real_ds_dir, pa.image_rel_path)
            self.assertTrue(os.path.exists(img_path), f"Missing image file: {img_path}")

            for f in pa.frames:
                self.assertGreaterEqual(f.x, 0)
                self.assertGreaterEqual(f.y, 0)
                self.assertGreater(f.w, 0)
                self.assertGreater(f.h, 0)
                self.assertLessEqual(f.x + f.w, 1264)
                self.assertLessEqual(f.y + f.h, 1680)

        self.assertEqual(total_panels, 726, "Expected exactly 726 human-mapped panels")


if __name__ == "__main__":
    unittest.main()
