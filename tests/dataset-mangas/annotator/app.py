"""
Main PyQt6 Application for Manga Comic Reader & Panel Annotator.
Features:
- KOReader-like Library / Recent Projects tab with book covers, progress %, and finished toggle.
- Extraction of .cbz, .cbr, .pdf, .mobi, .epub into dataset/<bookfriendlyname>/00.png, 01.png...
- Dark-themed canvas panel annotator with single-page (F) and double-page spread (S) shortcuts.
- Finished book shortcut (Ctrl+M), auto-saving, and PanelsPlus schema compatibility.
"""

import json
import os
import re
import sys
from typing import Optional, List
from PIL import Image

from PyQt6.QtCore import Qt, QSize, QTimer, pyqtSignal
from PyQt6.QtGui import (
    QAction, QIcon, QImage, QPixmap, QKeySequence, QFont, QColor
)
from PyQt6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout,
    QPushButton, QLabel, QLineEdit, QFileDialog, QMessageBox,
    QListWidget, QListWidgetItem, QSpinBox, QSlider, QStatusBar,
    QSplitter, QGroupBox, QTabWidget, QScrollArea, QFrame,
    QProgressBar, QProgressDialog, QInputDialog, QCheckBox, QDialog,
    QDialogButtonBox
)

from .document_reader import DocumentReader
from .dataset_manager import DatasetManager, Panel, PageAnnotation
from .canvas import MangaCanvas


DARK_THEME_STYLESHEET = """
QMainWindow, QWidget { background-color: #1e1e1e; color: #d4d4d4; }
QTabWidget::pane { border: 1px solid #3e3e42; }
QTabBar::tab { background: #252526; border: 1px solid #3e3e42; padding: 7px 14px; }
QTabBar::tab:selected { background: #2d2d30; border-bottom-color: #007acc; }
QMenuBar, QMenu { background-color: #252526; color: #d4d4d4; }
QMenu::item:selected { background-color: #094771; }
QPushButton { background-color: #3e3e42; border: 1px solid #555555; border-radius: 4px; padding: 5px 9px; }
QPushButton:hover { background-color: #505050; }
QPushButton:pressed { background-color: #2a2d2e; }
QLineEdit, QSpinBox, QListWidget, QScrollArea, QComboBox {
    background-color: #252526; color: #d4d4d4; border: 1px solid #3e3e42; selection-background-color: #094771;
}
QGroupBox { border: 1px solid #3e3e42; border-radius: 4px; margin-top: 8px; padding-top: 8px; }
QGroupBox::title { subcontrol-origin: margin; left: 8px; padding: 0 4px; }
QStatusBar { background-color: #252526; color: #cccccc; }
QToolTip { background-color: #252526; color: #ffffff; border: 1px solid #555555; }
"""


def apply_dark_theme(app: Optional[QApplication] = None) -> None:
    """Apply the annotator's default dark theme once per Qt application."""
    app = app or QApplication.instance()
    if app is not None and not app.property("panelsplus_dark_theme"):
        app.setStyle("Fusion")
        app.setStyleSheet(DARK_THEME_STYLESHEET)
        app.setProperty("panelsplus_dark_theme", True)


def pil_to_qpixmap(pil_img: Image.Image) -> QPixmap:
    """Convert a PIL Image to QPixmap efficiently."""
    if pil_img.mode != "RGBA":
        pil_img = pil_img.convert("RGBA")
    data = pil_img.tobytes("raw", "RGBA")
    qimg = QImage(data, pil_img.width, pil_img.height, QImage.Format.Format_RGBA8888)
    return QPixmap.fromImage(qimg)


class BookCardWidget(QFrame):
    """Card widget representing a book in the KOReader-style Recent Projects view."""

    open_requested = pyqtSignal(str)  # book_title
    toggle_finished_requested = pyqtSignal(str)  # book_title

    def __init__(self, book_info: dict, parent=None):
        super().__init__(parent)
        self.book_title = book_info["book_title"]
        self.setFrameShape(QFrame.Shape.StyledPanel)
        self.setStyleSheet("""
            BookCardWidget {
                background-color: #252526;
                border: 1px solid #3e3e42;
                border-radius: 8px;
                padding: 10px;
            }
            BookCardWidget:hover {
                border: 1px solid #007acc;
                background-color: #2d2d30;
            }
        """)

        layout = QHBoxLayout(self)
        layout.setContentsMargins(12, 10, 12, 10)
        layout.setSpacing(16)

        # 1. Cover image thumbnail
        self.lbl_cover = QLabel()
        self.lbl_cover.setFixedSize(90, 130)
        self.lbl_cover.setAlignment(Qt.AlignmentFlag.AlignCenter)
        self.lbl_cover.setStyleSheet("""
            background-color: #1a1a1a;
            border: 1px solid #444444;
            border-radius: 4px;
        """)

        cover_path = book_info.get("cover_path")
        if cover_path and os.path.exists(cover_path):
            try:
                pix = QPixmap(cover_path)
                if not pix.isNull():
                    scaled = pix.scaled(
                        90, 130,
                        Qt.AspectRatioMode.KeepAspectRatio,
                        Qt.TransformationMode.SmoothTransformation
                    )
                    self.lbl_cover.setPixmap(scaled)
                else:
                    self.lbl_cover.setText("📖\nCover")
            except Exception:
                self.lbl_cover.setText("📖\nCover")
        else:
            self.lbl_cover.setText("📖\nCover")

        layout.addWidget(self.lbl_cover)

        # 2. Book details & progress info
        details_layout = QVBoxLayout()
        details_layout.setSpacing(6)

        # Title + status badge
        title_row = QHBoxLayout()
        lbl_title = QLabel(self.book_title)
        font = QFont()
        font.setPointSize(12)
        font.setBold(True)
        lbl_title.setFont(font)
        lbl_title.setStyleSheet("color: #ffffff;")
        title_row.addWidget(lbl_title)

        is_finished = book_info.get("finished", False)
        lbl_badge = QLabel(" FINISHED " if is_finished else " IN PROGRESS ")
        badge_style = """
            font-size: 10px;
            font-weight: bold;
            padding: 2px 8px;
            border-radius: 4px;
        """
        if is_finished:
            badge_style += "background-color: #2e7d32; color: #ffffff;"
        else:
            badge_style += "background-color: #e65100; color: #ffffff;"
        lbl_badge.setStyleSheet(badge_style)
        title_row.addWidget(lbl_badge)
        title_row.addStretch(1)
        details_layout.addLayout(title_row)

        # Progress bar
        pct = book_info.get("progress_percent", 0)
        pbar = QProgressBar()
        pbar.setRange(0, 100)
        pbar.setValue(pct)
        pbar.setFixedHeight(12)
        pbar.setTextVisible(False)
        pbar_color = "#4caf50" if is_finished else "#2196f3"
        pbar.setStyleSheet(f"""
            QProgressBar {{
                background-color: #333333;
                border-radius: 6px;
            }}
            QProgressBar::chunk {{
                background-color: {pbar_color};
                border-radius: 6px;
            }}
        """)
        details_layout.addWidget(pbar)

        # Progress metrics label
        ann_cnt = book_info.get("annotated_pages", 0)
        tot_cnt = book_info.get("total_pages", 0)
        lbl_info = QLabel(f"Progress: <b>{pct}%</b> ({ann_cnt} of {tot_cnt} pages annotated)")
        lbl_info.setStyleSheet("color: #cccccc; font-size: 11px;")
        details_layout.addWidget(lbl_info)

        # Source file or date
        last_opened = book_info.get("last_opened", "")
        if last_opened:
            date_str = last_opened[:10] + " " + last_opened[11:16]
            lbl_date = QLabel(f"Last accessed: {date_str}")
            lbl_date.setStyleSheet("color: #888888; font-size: 10px;")
            details_layout.addWidget(lbl_date)

        details_layout.addStretch(1)
        layout.addLayout(details_layout, 1)

        # 3. Action buttons
        btn_layout = QVBoxLayout()
        btn_layout.setSpacing(8)

        btn_open = QPushButton("▶ Continue")
        btn_open.setStyleSheet("""
            font-weight: bold;
            padding: 6px 14px;
            background-color: #007acc;
            color: white;
            border-radius: 4px;
        """)
        btn_open.clicked.connect(lambda: self.open_requested.emit(self.book_title))
        btn_layout.addWidget(btn_open)

        btn_toggle = QPushButton("↩ In Progress" if is_finished else "✓ Mark Finished")
        btn_toggle.setStyleSheet("""
            padding: 4px 10px;
            background-color: #3e3e42;
            color: #d4d4d4;
            border-radius: 4px;
        """)
        btn_toggle.clicked.connect(lambda: self.toggle_finished_requested.emit(self.book_title))
        btn_layout.addWidget(btn_toggle)

        btn_layout.addStretch(1)
        layout.addLayout(btn_layout)

    def mouseDoubleClickEvent(self, event):
        self.open_requested.emit(self.book_title)


class AnnotatorMainWindow(QMainWindow):
    """Main application window with Library / Recent tab and Annotator tab."""

    def __init__(
        self,
        initial_file: Optional[str] = None,
        dataset_dir: Optional[str] = None,
        config_path: Optional[str] = None,
    ):
        super().__init__()
        apply_dark_theme()
        self.setWindowTitle("PanelsPlus Manga Annotator")
        self.resize(1300, 860)

        # Default dataset directory: tests/dataset-mangas/dataset
        repo_root = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "..", ".."))
        default_ds_dir = os.path.join(repo_root, "tests", "dataset-mangas", "dataset")
        os.makedirs(default_ds_dir, exist_ok=True)

        self.config_path = config_path or os.path.join(repo_root, "manga-annotator.config.json")
        self.annotator_config = self._load_annotator_config()

        self.dataset_dir = os.path.abspath(dataset_dir) if dataset_dir else default_ds_dir
        self.dataset_mgr = DatasetManager(self.dataset_dir)

        self.reader: Optional[DocumentReader] = None
        self.current_page_num = 1
        self.book_title = ""

        self._init_ui()

        # Refresh recent library
        self.refresh_library()

        if initial_file and os.path.exists(initial_file):
            self.import_or_open_file(initial_file)

    def _load_annotator_config(self) -> dict:
        config = {"phrase_auto_advance_distance": 120}
        try:
            with open(self.config_path, "r", encoding="utf-8") as config_file:
                loaded = json.load(config_file)
            if isinstance(loaded, dict):
                distance = int(loaded.get("phrase_auto_advance_distance", 120))
                config["phrase_auto_advance_distance"] = max(0, min(5000, distance))
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            pass
        return config

    def _save_annotator_config(self):
        config_dir = os.path.dirname(os.path.abspath(self.config_path))
        os.makedirs(config_dir, exist_ok=True)
        temp_path = self.config_path + ".tmp"
        with open(temp_path, "w", encoding="utf-8") as config_file:
            json.dump(self.annotator_config, config_file, indent=2, ensure_ascii=False)
            config_file.write("\n")
        os.replace(temp_path, self.config_path)

    def _init_ui(self):
        self.tabs = QTabWidget(self)
        self.setCentralWidget(self.tabs)

        # Tab 0: 📚 Library & Recent Projects
        self.tab_library = QWidget()
        self._init_library_tab(self.tab_library)
        self.tabs.addTab(self.tab_library, "📚 Recent Projects")

        # Tab 1: ✏️ Panel Annotator
        self.tab_annotator = QWidget()
        self._init_annotator_tab(self.tab_annotator)
        self.tabs.addTab(self.tab_annotator, "✏️ Manga Annotator")

        self.tabs.currentChanged.connect(self._on_tab_changed)

        # Menus
        self._init_menus()

        # Status Bar
        self.status_bar = QStatusBar()
        self.setStatusBar(self.status_bar)
        self.lbl_status_coords = QLabel("X: 0, Y: 0")
        self.lbl_status_zoom = QLabel("Zoom: 100%")
        self.status_bar.addPermanentWidget(self.lbl_status_coords)
        self.status_bar.addPermanentWidget(self.lbl_status_zoom)
        self.status_bar.showMessage("Ready. Select a recent book or import a new comic.")

    def _init_library_tab(self, parent: QWidget):
        layout = QVBoxLayout(parent)
        layout.setContentsMargins(16, 16, 16, 16)
        layout.setSpacing(12)

        # Top Bar: Actions and search
        top_bar = QHBoxLayout()
        self.btn_import = QPushButton("+ Search System for Comic File...")
        self.btn_import.setStyleSheet("""
            font-size: 13px;
            font-weight: bold;
            padding: 8px 18px;
            background-color: #2e7d32;
            color: white;
            border-radius: 4px;
        """)
        self.btn_import.clicked.connect(self._search_system_dialog)
        top_bar.addWidget(self.btn_import)

        top_bar.addSpacing(20)
        self.txt_search = QLineEdit()
        self.txt_search.setPlaceholderText("Filter recent books...")
        self.txt_search.textChanged.connect(self.refresh_library)
        top_bar.addWidget(self.txt_search, 1)

        self.lbl_book_count = QLabel("0 books")
        self.lbl_book_count.setStyleSheet("color: #888888; font-weight: bold;")
        top_bar.addWidget(self.lbl_book_count)

        layout.addLayout(top_bar)

        # Scroll area for book cards
        scroll = QScrollArea()
        scroll.setWidgetResizable(True)
        scroll.setStyleSheet("background-color: #1e1e1e; border: none;")

        self.cards_container = QWidget()
        self.cards_layout = QVBoxLayout(self.cards_container)
        self.cards_layout.setContentsMargins(4, 4, 4, 4)
        self.cards_layout.setSpacing(10)
        self.cards_layout.addStretch(1)

        scroll.setWidget(self.cards_container)
        layout.addWidget(scroll, 1)

    def _init_annotator_tab(self, parent: QWidget):
        layout = QVBoxLayout(parent)
        layout.setContentsMargins(4, 4, 4, 4)
        layout.setSpacing(4)

        # Top Control & Navigation Bar
        top_nav = QHBoxLayout()
        btn_back = QPushButton("← Library")
        btn_back.clicked.connect(lambda: self.tabs.setCurrentIndex(0))
        top_nav.addWidget(btn_back)

        self.lbl_current_book = QLabel("No book loaded")
        self.lbl_current_book.setStyleSheet("font-size: 13px; font-weight: bold; color: #ffffff;")
        top_nav.addWidget(self.lbl_current_book)

        top_nav.addStretch(1)

        self.btn_mark_finished = QPushButton("✓ Mark Finished (Ctrl+M)")
        self.btn_mark_finished.setShortcut(QKeySequence("Ctrl+M"))
        self.btn_mark_finished.clicked.connect(self.toggle_current_book_finished)
        top_nav.addWidget(self.btn_mark_finished)

        self.btn_save_top = QPushButton("💾 Save Dataset (Ctrl+S)")
        self.btn_save_top.setStyleSheet("font-weight: bold; background-color: #1976d2; color: white;")
        self.btn_save_top.clicked.connect(self.save_dataset)
        top_nav.addWidget(self.btn_save_top)

        layout.addLayout(top_nav)

        # Main splitter: Canvas + Panels Sidebar
        splitter = QSplitter(Qt.Orientation.Horizontal)

        canvas_container = QWidget()
        canvas_layout = QVBoxLayout(canvas_container)
        canvas_layout.setContentsMargins(0, 0, 0, 0)

        self.canvas = MangaCanvas()
        self.canvas.set_phrase_auto_advance_distance(
            self.annotator_config["phrase_auto_advance_distance"]
        )
        self.canvas.panels_changed.connect(self._on_panels_changed)
        self.canvas.panel_selected.connect(self._on_canvas_panel_selected)
        self.canvas.cursor_position.connect(self._on_cursor_position)
        self.canvas.zoom_changed.connect(lambda z: self.lbl_status_zoom.setText(f"Zoom: {int(z * 100)}%"))
        self.canvas.single_page_illustration_requested.connect(self.set_single_page_illustration)
        self.canvas.double_page_illustration_requested.connect(self.set_double_page_illustration)
        self.canvas.annotation_mode_changed.connect(self._on_annotation_mode_changed)
        self.canvas.phrase_id_changed.connect(self._on_phrase_id_changed)
        self.canvas.phrase_text_requested.connect(self._prompt_new_phrase_text)
        self.canvas.word_text_requested.connect(self._prompt_new_word_text)
        self.canvas.status_message.connect(lambda message: self.status_bar.showMessage(message, 3000))
        canvas_layout.addWidget(self.canvas, 1)

        # Bottom Page Navigation
        page_nav = QHBoxLayout()
        self.btn_prev = QPushButton("◀ Prev (A)")
        self.btn_prev.setShortcut(QKeySequence(Qt.Key.Key_A))
        self.btn_prev.clicked.connect(self.prev_page)
        page_nav.addWidget(self.btn_prev)

        self.spin_page = QSpinBox()
        self.spin_page.setMinimum(1)
        self.spin_page.setMaximum(1)
        self.spin_page.valueChanged.connect(self.go_to_page)
        page_nav.addWidget(self.spin_page)

        self.lbl_total_pages = QLabel("/ 1")
        page_nav.addWidget(self.lbl_total_pages)

        self.slider_page = QSlider(Qt.Orientation.Horizontal)
        self.slider_page.setMinimum(1)
        self.slider_page.setMaximum(1)
        self.slider_page.valueChanged.connect(self.go_to_page)
        page_nav.addWidget(self.slider_page, 1)

        self.btn_next = QPushButton("Next (D) ▶")
        self.btn_next.setShortcut(QKeySequence(Qt.Key.Key_D))
        self.btn_next.clicked.connect(self.next_page)
        page_nav.addWidget(self.btn_next)

        canvas_layout.addLayout(page_nav)
        splitter.addWidget(canvas_container)

        # Sidebar
        sidebar = QWidget()
        sidebar_layout = QVBoxLayout(sidebar)
        sidebar.setMinimumWidth(260)
        sidebar.setMaximumWidth(360)

        panel_group = QGroupBox("Rectangle Annotations")
        self.annotation_group = panel_group
        p_layout = QVBoxLayout(panel_group)

        mode_layout = QHBoxLayout()
        self.mode_buttons = {}
        for mode, label in (("panel", "1 Panel"), ("phrase", "2 Phrase"), ("word", "3 Word")):
            button = QPushButton(label)
            button.setCheckable(True)
            button.clicked.connect(lambda checked=False, m=mode: self.canvas.set_annotation_mode(m))
            self.mode_buttons[mode] = button
            mode_layout.addWidget(button)
        self.mode_buttons["panel"].setChecked(True)
        p_layout.addLayout(mode_layout)

        phrase_layout = QHBoxLayout()
        self.btn_prev_phrase = QPushButton("◀ Q")
        self.btn_prev_phrase.clicked.connect(lambda: self.canvas.step_phrase_id(-1))
        phrase_layout.addWidget(self.btn_prev_phrase)
        self.lbl_phrase_id = QLabel("Phrase ID: 1")
        self.lbl_phrase_id.setAlignment(Qt.AlignmentFlag.AlignCenter)
        phrase_layout.addWidget(self.lbl_phrase_id, 1)
        self.btn_next_phrase = QPushButton("R ▶")
        self.btn_next_phrase.clicked.connect(lambda: self.canvas.step_phrase_id(1))
        phrase_layout.addWidget(self.btn_next_phrase)
        p_layout.addLayout(phrase_layout)

        self.lbl_phrase_distance = QLabel()
        self.lbl_phrase_distance.setToolTip(
            "A new phrase rectangle farther than this edge-to-edge distance "
            "automatically advances to the next Phrase ID. Coordinates use native image pixels."
        )
        p_layout.addWidget(self.lbl_phrase_distance)

        self.slider_phrase_distance = QSlider(Qt.Orientation.Horizontal)
        self.slider_phrase_distance.setRange(0, 5000)
        self.slider_phrase_distance.setSingleStep(10)
        self.slider_phrase_distance.setPageStep(50)
        self.slider_phrase_distance.setValue(
            self.annotator_config["phrase_auto_advance_distance"]
        )
        self.slider_phrase_distance.valueChanged.connect(self._on_phrase_distance_changed)
        p_layout.addWidget(self.slider_phrase_distance)
        self._refresh_phrase_distance_label()

        self.btn_full_page = QPushButton("Set Single-Page Illustration (F)")
        self.btn_full_page.setStyleSheet("font-weight: bold; background-color: #2e7d32; color: white;")
        self.btn_full_page.clicked.connect(self.set_single_page_illustration)
        p_layout.addWidget(self.btn_full_page)

        self.btn_double_page = QPushButton("Set Double-Page Illustration (S)")
        self.btn_double_page.setStyleSheet("font-weight: bold; background-color: #6a3d9a; color: white;")
        self.btn_double_page.setToolTip(
            "Marks this already-combined wide image as a double-page spread for future rotation support."
        )
        self.btn_double_page.clicked.connect(self.set_double_page_illustration)
        p_layout.addWidget(self.btn_double_page)

        self.lbl_illustration_type = QLabel()
        self.lbl_illustration_type.setStyleSheet("color: #bbbbbb; font-size: 11px;")
        p_layout.addWidget(self.lbl_illustration_type)

        # Undo / Redo controls
        undo_layout = QHBoxLayout()
        self.btn_undo = QPushButton("↶ Undo (Ctrl+Z)")
        self.btn_undo.clicked.connect(self.canvas.undo)
        undo_layout.addWidget(self.btn_undo)

        self.btn_redo = QPushButton("↷ Redo (Ctrl+Y)")
        self.btn_redo.clicked.connect(self.canvas.redo)
        undo_layout.addWidget(self.btn_redo)
        p_layout.addLayout(undo_layout)

        # Precision mouse fine-tuning toggle
        self.chk_precision = QCheckBox("🎯 Precision Fine-Tuning")
        self.chk_precision.setChecked(True)
        self.chk_precision.setToolTip(
            "Loupe HUD in all rectangle modes; magnetic snapping to borders/edges in Panel mode.\n"
            "Uncheck to turn off precision aids. (Shortcut: P, or hold Alt to bypass snapping)"
        )
        self.chk_precision.toggled.connect(self.canvas.set_precision_mode)
        self.canvas.precision_mode_changed.connect(
            lambda en: self.chk_precision.setChecked(en) if self.chk_precision.isChecked() != en else None
        )
        p_layout.addWidget(self.chk_precision)

        self.panel_list = QListWidget()
        self.panel_list.currentRowChanged.connect(self._on_list_row_selected)
        self.panel_list.itemDoubleClicked.connect(lambda: self._edit_selected_annotation_text())
        p_layout.addWidget(self.panel_list, 1)

        self.btn_edit_text = QPushButton("Edit Annotation Text (T)")
        self.btn_edit_text.clicked.connect(self._edit_selected_annotation_text)
        p_layout.addWidget(self.btn_edit_text)

        self.btn_phrase_to_word = QPushButton("Use Phrase Box as Word (W)...")
        self.btn_phrase_to_word.setToolTip(
            "After drawing a phrase line with one word, reuse its exact rectangle "
            "for the word. The phrase rectangle stays in place."
        )
        self.btn_phrase_to_word.clicked.connect(self._add_word_from_selected_phrase)
        p_layout.addWidget(self.btn_phrase_to_word)

        reorder_layout = QHBoxLayout()
        self.btn_move_up = QPushButton("▲ Move Up")
        self.btn_move_up.clicked.connect(self._move_panel_up)
        reorder_layout.addWidget(self.btn_move_up)

        self.btn_move_down = QPushButton("▼ Move Down")
        self.btn_move_down.clicked.connect(self._move_panel_down)
        reorder_layout.addWidget(self.btn_move_down)
        p_layout.addLayout(reorder_layout)

        action_layout = QHBoxLayout()
        self.btn_del = QPushButton("Delete (Del)")
        self.btn_del.clicked.connect(self.canvas.delete_selected_panel)
        action_layout.addWidget(self.btn_del)

        self.btn_clear = QPushButton("Clear Current Mode")
        self.btn_clear.clicked.connect(self.canvas.clear_panels)
        action_layout.addWidget(self.btn_clear)
        p_layout.addLayout(action_layout)

        sidebar_layout.addWidget(panel_group, 1)

        self._on_annotation_mode_changed("panel")

        splitter.addWidget(sidebar)
        splitter.setStretchFactor(0, 4)
        splitter.setStretchFactor(1, 1)
        layout.addWidget(splitter, 1)

    def _init_menus(self):
        menubar = self.menuBar()

        file_menu = menubar.addMenu("&File")
        act_open = QAction("&Search System for Comic...", self)
        act_open.setShortcut(QKeySequence.StandardKey.Open)
        act_open.triggered.connect(self._search_system_dialog)
        file_menu.addAction(act_open)

        act_save = QAction("&Save Dataset", self)
        act_save.setShortcut(QKeySequence.StandardKey.Save)
        act_save.triggered.connect(self.save_dataset)
        file_menu.addAction(act_save)

        file_menu.addSeparator()
        act_exit = QAction("E&xit", self)
        act_exit.setShortcut(QKeySequence.StandardKey.Quit)
        act_exit.triggered.connect(self.close)
        file_menu.addAction(act_exit)

        edit_menu = menubar.addMenu("&Edit")
        act_undo = QAction("&Undo", self)
        act_undo.setShortcut(QKeySequence.StandardKey.Undo)
        act_undo.triggered.connect(self.canvas.undo)
        edit_menu.addAction(act_undo)

        act_redo = QAction("&Redo", self)
        act_redo.setShortcut(QKeySequence.StandardKey.Redo)
        act_redo.triggered.connect(self.canvas.redo)
        edit_menu.addAction(act_redo)

        edit_menu.addSeparator()

        act_full = QAction("Set &Single-Page Illustration", self)
        act_full.setShortcut(QKeySequence(Qt.Key.Key_F))
        act_full.triggered.connect(self.set_single_page_illustration)
        edit_menu.addAction(act_full)

        act_double = QAction("Set Double-Page &Illustration", self)
        act_double.setShortcut(QKeySequence(Qt.Key.Key_S))
        act_double.triggered.connect(self.set_double_page_illustration)
        edit_menu.addAction(act_double)

        act_fin = QAction("Toggle &Finished", self)
        act_fin.setShortcut(QKeySequence("Ctrl+M"))
        act_fin.triggered.connect(self.toggle_current_book_finished)
        edit_menu.addAction(act_fin)

        act_del = QAction("&Delete Selected Rectangle", self)
        act_del.setShortcut(QKeySequence(Qt.Key.Key_Delete))
        act_del.triggered.connect(self.canvas.delete_selected_panel)
        edit_menu.addAction(act_del)

        act_clear = QAction("&Clear Current Rectangle Mode", self)
        act_clear.triggered.connect(self.canvas.clear_panels)
        edit_menu.addAction(act_clear)

        edit_menu.addSeparator()
        for mode, key in (("panel", "1"), ("phrase", "2"), ("word", "3")):
            action = QAction(f"{mode.title()} Rectangle Mode", self)
            action.setShortcut(QKeySequence(key))
            action.triggered.connect(lambda checked=False, m=mode: self.canvas.set_annotation_mode(m))
            edit_menu.addAction(action)

        act_prev_phrase = QAction("Previous Phrase ID", self)
        act_prev_phrase.setShortcut(QKeySequence("Q"))
        act_prev_phrase.triggered.connect(lambda: self.canvas.step_phrase_id(-1))
        edit_menu.addAction(act_prev_phrase)

        act_next_phrase = QAction("Next Phrase ID", self)
        act_next_phrase.setShortcut(QKeySequence("R"))
        act_next_phrase.triggered.connect(lambda: self.canvas.step_phrase_id(1))
        edit_menu.addAction(act_next_phrase)

        act_edit_text = QAction("Edit Selected Text", self)
        act_edit_text.setShortcut(QKeySequence("T"))
        act_edit_text.triggered.connect(self._edit_selected_annotation_text)
        edit_menu.addAction(act_edit_text)

        act_phrase_to_word = QAction("Use Selected Phrase Box as Word", self)
        act_phrase_to_word.setShortcut(QKeySequence("W"))
        act_phrase_to_word.triggered.connect(self._add_word_from_selected_phrase)
        edit_menu.addAction(act_phrase_to_word)

        view_menu = menubar.addMenu("&View")
        act_fit_win = QAction("Fit &Window", self)
        act_fit_win.triggered.connect(lambda: self.canvas.fit_to_window(self.canvas.rect()))
        view_menu.addAction(act_fit_win)

        act_fit_w = QAction("Fit &Width", self)
        act_fit_w.triggered.connect(lambda: self.canvas.fit_to_width(self.canvas.rect()))
        view_menu.addAction(act_fit_w)

        act_zoom_100 = QAction("Zoom &100%", self)
        act_zoom_100.triggered.connect(lambda: self.canvas.set_zoom(1.0))
        view_menu.addAction(act_zoom_100)

        act_zoom_in = QAction("Zoom &In", self)
        act_zoom_in.setShortcut(QKeySequence.StandardKey.ZoomIn)
        act_zoom_in.triggered.connect(lambda: self.canvas.set_zoom(self.canvas.zoom_factor * 1.2))
        view_menu.addAction(act_zoom_in)

        act_zoom_out = QAction("Zoom &Out", self)
        act_zoom_out.setShortcut(QKeySequence.StandardKey.ZoomOut)
        act_zoom_out.triggered.connect(lambda: self.canvas.set_zoom(self.canvas.zoom_factor / 1.2))
        view_menu.addAction(act_zoom_out)

    def refresh_library(self):
        """Re-scan dataset folder and update book cards in Library tab."""
        # Clear existing cards
        while self.cards_layout.count() > 1:
            item = self.cards_layout.takeAt(0)
            if item.widget():
                item.widget().deleteLater()

        books = self.dataset_mgr.get_recent_books()
        filter_text = self.txt_search.text().lower().strip() if hasattr(self, 'txt_search') else ""

        matched_count = 0
        for b in books:
            if filter_text and filter_text not in b["book_title"].lower():
                continue

            card = BookCardWidget(b)
            card.open_requested.connect(self.open_book_by_title)
            card.toggle_finished_requested.connect(self._on_toggle_finished_card)
            self.cards_layout.insertWidget(self.cards_layout.count() - 1, card)
            matched_count += 1

        self.lbl_book_count.setText(f"{matched_count} book(s)")

    def _on_toggle_finished_card(self, book_title: str):
        meta = self.dataset_mgr.load_book_metadata(book_title)
        new_state = not meta.get("finished", False)
        self.dataset_mgr.mark_book_finished(book_title, new_state)
        self.refresh_library()

    def toggle_current_book_finished(self):
        if not self.book_title:
            return
        meta = self.dataset_mgr.load_book_metadata(self.book_title)
        new_state = not meta.get("finished", False)
        self.dataset_mgr.mark_book_finished(self.book_title, new_state)
        label_txt = "✓ Mark Finished (Ctrl+M)" if not new_state else "↩ Mark In Progress (Ctrl+M)"
        self.btn_mark_finished.setText(label_txt)
        status = "Finished" if new_state else "In Progress"
        self.status_bar.showMessage(f"Book '{self.book_title}' marked as {status}.", 3000)
        self.refresh_library()

    def open_book_by_title(self, book_title: str):
        """Open an existing book directory from dataset/<book_title>/."""
        book_dir = self.dataset_mgr.get_book_dir(book_title)
        if not os.path.exists(book_dir):
            QMessageBox.warning(self, "Book Not Found", f"Directory does not exist: {book_dir}")
            return

        self._commit_current_page_panels()
        if self.reader:
            self.reader.close()

        self.reader = DocumentReader(book_dir)
        self.book_title = book_title
        self.lbl_current_book.setText(f"📖 {self.book_title}")

        meta = self.dataset_mgr.load_book_metadata(book_title)
        cur_p = meta.get("current_page", 1)
        cur_p = max(1, min(cur_p, max(1, self.reader.total_pages)))
        self.current_page_num = cur_p

        total = max(1, self.reader.total_pages)
        self.spin_page.setMaximum(total)
        self.slider_page.setMaximum(total)
        self.lbl_total_pages.setText(f"/ {total}")

        is_fin = meta.get("finished", False)
        self.btn_mark_finished.setText("↩ Mark In Progress (Ctrl+M)" if is_fin else "✓ Mark Finished (Ctrl+M)")

        self._render_current_page(fit_width=True)
        self.dataset_mgr.update_last_opened(self.book_title, self.current_page_num)

        # Switch to Annotator tab
        self.tabs.setCurrentIndex(1)
        from PyQt6.QtCore import QTimer
        QTimer.singleShot(50, lambda: self.canvas.fit_to_width(self.canvas.rect()))
        self.status_bar.showMessage(f"Opened book '{self.book_title}'.", 3000)

    def _search_system_dialog(self):
        """File search dialog allowing user to choose comic or document from disk."""
        filt = "Comic & Document Archives (*.cbz *.cbr *.pdf *.epub *.kepub.epub *.mobi *.jpg *.png);;All Files (*)"
        fpath, _ = QFileDialog.getOpenFileName(self, "Select Comic / Document to Import", "", filt)
        if fpath:
            label, ok = QInputDialog.getItem(
                self,
                "Reading Direction",
                "Dataset type:",
                ["Manga (right to left)", "Comic (left to right)"],
                0,
                False,
            )
            if ok:
                dataset_type = "comic" if label.startswith("Comic") else "manga"
                color_mode = None
                if dataset_type == "comic":
                    color_mode, ok = QInputDialog.getItem(
                        self, "Comic Color", "Artwork color mode:",
                        ["true_b/w", "colorless_b/w", "color"], 0, False,
                    )
                    if not ok:
                        return
                self.import_or_open_file(fpath, dataset_type=dataset_type, color_mode=color_mode)

    def import_or_open_file(self, file_path: str, friendly_name: Optional[str] = None, dataset_type: str = "manga", color_mode: Optional[str] = None):
        """Extract file into dataset/<bookfriendlyname>/00.png, 01.png... and open it."""
        try:
            if dataset_type not in ("manga", "comic"):
                raise ValueError('dataset_type must be "manga" or "comic"')
            if color_mode is not None and (
                dataset_type != "comic" or color_mode not in ("true_b/w", "colorless_b/w", "color")
            ):
                raise ValueError('Invalid comic color_mode')
            # 1. Ask or derive friendly book name if not provided
            stem = os.path.splitext(os.path.basename(file_path))[0]
            clean_name = re.sub(r'[\s_]+', '_', stem.strip())

            if not friendly_name:
                user_name, ok = QInputDialog.getText(
                    self, "Book Folder Name",
                    "Enter folder name for this dataset:",
                    QLineEdit.EchoMode.Normal,
                    clean_name
                )
                if not ok or not user_name.strip():
                    return
                friendly_name = user_name

            friendly_name = re.sub(r'[\s_]+', '_', friendly_name.strip())
            target_dir = self.dataset_mgr.get_book_dir(friendly_name)

            # 2. Extract pages into target directory
            temp_reader = DocumentReader(file_path)
            total = temp_reader.total_pages

            if total == 0:
                temp_reader.close()
                QMessageBox.warning(self, "Empty Book", "Could not find any pages in this file.")
                return

            prog = QProgressDialog(f"Extracting {total} pages into {friendly_name}...", "Cancel", 0, total, self)
            prog.setWindowModality(Qt.WindowModality.WindowModal)
            prog.setMinimumDuration(0)
            prog.setValue(0)

            cancelled = False

            def update_progress(curr, tot):
                nonlocal cancelled
                if prog.wasCanceled():
                    cancelled = True
                    return False
                prog.setValue(curr)
                QApplication.processEvents()
                if prog.wasCanceled():
                    cancelled = True
                    return False
                return True

            extracted = temp_reader.extract_all_pages(target_dir, progress_callback=update_progress)
            temp_reader.close()
            prog.close()

            if cancelled or len(extracted) < total:
                # Cancelled by user - clean up partial files
                if os.path.exists(target_dir):
                    import shutil
                    shutil.rmtree(target_dir, ignore_errors=True)
                self.status_bar.showMessage("Extraction cancelled.", 4000)
                return

            # 3. Save initial metadata
            meta = {
                "book_title": friendly_name,
                "type": dataset_type,
                "total_pages": total,
                "finished": False,
                "current_page": 1,
                "last_opened": "",
                "source_file": file_path,
            }
            if color_mode is not None:
                meta["color_mode"] = color_mode
            self.dataset_mgr.save_book_metadata(friendly_name, meta)

            # 4. Open extracted book in annotator
            self.refresh_library()
            self.open_book_by_title(friendly_name)

        except Exception as e:
            QMessageBox.critical(self, "Error Importing File", f"Could not import file:\n{str(e)}")

    def _render_current_page(self, fit_width: bool = False):
        if not self.reader or self.reader.total_pages == 0:
            return

        page = self.reader.get_page(self.current_page_num)
        if not page:
            return

        pil_img = page.get_pil_image()
        pixmap = pil_to_qpixmap(pil_img)

        pa = self.dataset_mgr.get_page_annotation(self.book_title, self.current_page_num)
        panels = [p.copy() for p in pa.frames]
        phrases = [p.copy() for p in pa.phrases]
        words = [w.copy() for w in pa.words]

        self.canvas.set_page(pixmap, panels, phrases, words, fit_width=fit_width)
        if fit_width:
            self.canvas.fit_to_width(self.canvas.rect())

        self.spin_page.blockSignals(True)
        self.slider_page.blockSignals(True)
        self.spin_page.setValue(self.current_page_num)
        self.slider_page.setValue(self.current_page_num)
        self.spin_page.blockSignals(False)
        self.slider_page.blockSignals(False)

        self._refresh_panel_list()
        self._refresh_illustration_type()
        self.lbl_status_zoom.setText(f"Zoom: {int(self.canvas.zoom_factor * 100)}%")

    def _commit_current_page_panels(self):
        if self.book_title and self.reader:
            self.canvas.refresh_word_assignments()
            self.dataset_mgr.set_page_frames(
                self.book_title, self.current_page_num, self.canvas.get_panels()
            )
            self.dataset_mgr.set_page_text_annotations(
                self.book_title,
                self.current_page_num,
                self.canvas.get_phrases(),
                self.canvas.get_words(),
            )
            self.dataset_mgr.update_last_opened(self.book_title, self.current_page_num)

    def set_single_page_illustration(self):
        """Replace annotations with one full-page, single-page illustration."""
        if not self.book_title or not self.reader:
            return
        self.dataset_mgr.set_page_illustration_type(
            self.book_title, self.current_page_num, PageAnnotation.SINGLE_PAGE_ILLUSTRATION
        )
        self.canvas.set_full_page_panel()
        self._refresh_illustration_type()
        self.status_bar.showMessage("Marked as a single-page illustration.", 3000)

    def set_double_page_illustration(self):
        """Replace annotations with one full-page frame marked as an already-combined spread."""
        if not self.book_title or not self.reader:
            return
        self.dataset_mgr.set_page_illustration_type(
            self.book_title, self.current_page_num, PageAnnotation.DOUBLE_PAGE_ILLUSTRATION
        )
        self.canvas.set_full_page_panel()
        self._refresh_illustration_type()
        self.status_bar.showMessage("Marked as an already-combined double-page illustration.", 3000)

    def prev_page(self):
        if self.current_page_num > 1:
            self._commit_current_page_panels()
            self.current_page_num -= 1
            self._render_current_page()

    def next_page(self):
        if self.reader and self.current_page_num < self.reader.total_pages:
            self._commit_current_page_panels()
            self.current_page_num += 1
            self._render_current_page()

    def go_to_page(self, page_num: int):
        if self.reader and 1 <= page_num <= self.reader.total_pages and page_num != self.current_page_num:
            self._commit_current_page_panels()
            self.current_page_num = page_num
            self._render_current_page()

    def save_dataset(self, show_dialog: bool = True):
        self._commit_current_page_panels()
        if not self.book_title:
            if show_dialog:
                QMessageBox.information(self, "Save Dataset", "No book currently loaded.")
            return

        failures = self.dataset_mgr.validate_book_text_annotations(self.book_title)
        if failures:
            details = []
            for page_index, errors in failures.items():
                details.append(f"Page {page_index}: " + "; ".join(errors))
            message = "Text annotations are incomplete:\n\n" + "\n".join(
                f"• {detail}" for detail in details
            )
            self.status_bar.showMessage(message.replace("\n", " "), 5000)
            if show_dialog:
                QMessageBox.warning(self, "Cannot Save Incomplete Text Annotations", message)
            return

        try:
            json_path = self.dataset_mgr.save_book_dataset(self.book_title)
        except ValueError as exc:
            message = str(exc)
            self.status_bar.showMessage(message, 5000)
            if show_dialog:
                QMessageBox.warning(self, "Cannot Save Incomplete Text Annotations", message)
            return
        msg = f"Saved annotations for '{self.book_title}' to:\n{json_path}"
        self.status_bar.showMessage(msg, 5000)
        if show_dialog:
            QMessageBox.information(self, "Dataset Saved", msg)
        self.refresh_library()

    def _on_tab_changed(self, idx: int):
        if idx == 0:
            self._commit_current_page_panels()
            self.refresh_library()
        elif idx == 1:
            if getattr(self.canvas, "_pending_fit_width", False) or self.canvas.zoom_factor == 1.0:
                self.canvas.fit_to_width(self.canvas.rect())

    def _on_panels_changed(self):
        self._clear_invalid_double_page_marker()
        self._commit_current_page_panels()
        self._refresh_panel_list()
        self._refresh_illustration_type()

    def _clear_invalid_double_page_marker(self):
        """A double-page marker is only valid while its single frame covers the whole image."""
        if not self.book_title:
            return
        pa = self.dataset_mgr.get_page_annotation(self.book_title, self.current_page_num)
        if pa.illustration_type != PageAnnotation.DOUBLE_PAGE_ILLUSTRATION:
            return
        panels = self.canvas.get_panels()
        if len(panels) != 1:
            pa.illustration_type = None
            return
        panel = panels[0]
        if (panel.x, panel.y, panel.w, panel.h) != (0, 0, self.canvas.native_w, self.canvas.native_h):
            pa.illustration_type = None

    def _refresh_illustration_type(self):
        if not hasattr(self, "lbl_illustration_type"):
            return
        if not self.book_title:
            self.lbl_illustration_type.setText("")
            return
        pa = self.dataset_mgr.get_page_annotation(self.book_title, self.current_page_num)
        labels = {
            PageAnnotation.SINGLE_PAGE_ILLUSTRATION: "Page type: Single-page illustration",
            PageAnnotation.DOUBLE_PAGE_ILLUSTRATION: "Page type: Double-page illustration",
        }
        self.lbl_illustration_type.setText(labels.get(pa.effective_illustration_type, "Page type: Panel sequence"))

    def _refresh_panel_list(self):
        self.panel_list.blockSignals(True)
        self.panel_list.clear()
        for idx, p in enumerate(self.canvas.panels):
            if self.canvas.annotation_mode == "phrase":
                prefix = f"P{p.phrase_id}.{idx + 1}"
            elif self.canvas.annotation_mode == "word":
                owner = p.phrase_id if p.phrase_id is not None else "?"
                prefix = f"P{owner}:W{idx + 1}"
            else:
                prefix = str(idx + 1)
            suffix = (
                f' “{p.text}”'
                if self.canvas.annotation_mode in ("phrase", "word") and p.text
                else ""
            )
            item = QListWidgetItem(f"[{prefix}] x={p.x}, y={p.y} ({p.w}x{p.h}){suffix}")
            self.panel_list.addItem(item)
        if 0 <= self.canvas.selected_panel_index < self.panel_list.count():
            self.panel_list.setCurrentRow(self.canvas.selected_panel_index)
        self.panel_list.blockSignals(False)
        self._update_phrase_to_word_button()

    def _on_canvas_panel_selected(self, idx: int):
        self.panel_list.blockSignals(True)
        if 0 <= idx < self.panel_list.count():
            self.panel_list.setCurrentRow(idx)
        else:
            self.panel_list.clearSelection()
        self.panel_list.blockSignals(False)
        self._update_phrase_to_word_button()

    def _on_annotation_mode_changed(self, mode: str):
        for name, button in self.mode_buttons.items():
            button.setChecked(name == mode)
        self.annotation_group.setTitle(f"{mode.title()} Rectangles")
        phrase_controls_enabled = mode == "phrase"
        self.btn_prev_phrase.setEnabled(phrase_controls_enabled)
        self.btn_next_phrase.setEnabled(phrase_controls_enabled)
        self.lbl_phrase_id.setEnabled(phrase_controls_enabled)
        self.lbl_phrase_distance.setEnabled(phrase_controls_enabled)
        self.slider_phrase_distance.setEnabled(phrase_controls_enabled)
        self.btn_edit_text.setEnabled(mode in ("phrase", "word"))
        edit_labels = {
            "panel": "Edit Annotation Text (T)",
            "phrase": "Edit Phrase Text (T)",
            "word": "Edit Word Text (T)",
        }
        self.btn_edit_text.setText(edit_labels[mode])
        self._refresh_panel_list()

    def _update_phrase_to_word_button(self):
        self.btn_phrase_to_word.setEnabled(
            self.canvas.annotation_mode == "phrase"
            and 0 <= self.canvas.selected_panel_index < len(self.canvas.get_phrases())
        )

    def _on_phrase_id_changed(self, phrase_id: int):
        self.lbl_phrase_id.setText(f"Phrase ID: {phrase_id}")
        self._refresh_panel_list()

    def _on_phrase_distance_changed(self, distance: int):
        self.canvas.set_phrase_auto_advance_distance(distance)
        self.annotator_config["phrase_auto_advance_distance"] = int(distance)
        self._refresh_phrase_distance_label()
        try:
            self._save_annotator_config()
        except OSError as exc:
            self.status_bar.showMessage(f"Could not save annotator config: {exc}", 5000)

    def _refresh_phrase_distance_label(self):
        distance = self.annotator_config["phrase_auto_advance_distance"]
        self.lbl_phrase_distance.setText(f"New phrase distance: {distance} native px")

    def _prompt_new_word_text(self, index: int):
        self._prompt_word_text(index, discard_on_cancel=True)

    def _prompt_new_phrase_text(self, index: int):
        self._prompt_phrase_text(index, discard_on_cancel=True)

    def _add_word_from_selected_phrase(self):
        if self.canvas.annotation_mode != "phrase":
            return
        index = self.canvas.selected_panel_index
        phrases = self.canvas.get_phrases()
        if not (0 <= index < len(phrases)):
            return
        phrase = phrases[index]
        if any(
            (word.x, word.y, word.w, word.h)
            == (phrase.x, phrase.y, phrase.w, phrase.h)
            for word in self.canvas.get_words()
        ):
            self.status_bar.showMessage("A word already uses this rectangle.", 3000)
            return
        initial_text = phrase.text if len(phrase.text.split()) == 1 else ""
        accepted, text = self._ask_annotation_text(
            "Word Text", "Type the word in this phrase rectangle:", initial_text
        )
        if accepted and self.canvas.add_word_from_phrase(index, text):
            self.status_bar.showMessage("Word created from phrase rectangle.", 3000)

    def _edit_selected_annotation_text(self):
        if self.canvas.annotation_mode not in ("phrase", "word"):
            return
        index = self.panel_list.currentRow()
        if index >= 0:
            if self.canvas.annotation_mode == "phrase":
                self._prompt_phrase_text(index, discard_on_cancel=False)
            else:
                self._prompt_word_text(index, discard_on_cancel=False)

    def _prompt_phrase_text(self, index: int, discard_on_cancel: bool):
        phrases = self.canvas.get_phrases()
        if not (0 <= index < len(phrases)):
            return

        accepted, text = self._ask_annotation_text(
            "Phrase Text",
            f"Type the complete text for phrase {phrases[index].phrase_id}:",
            phrases[index].text,
        )
        if accepted:
            self.canvas.set_phrase_text(index, text)
        elif discard_on_cancel:
            self.canvas.discard_phrase(index)
        self._refresh_panel_list()

    def _prompt_word_text(self, index: int, discard_on_cancel: bool):
        words = self.canvas.get_words()
        if not (0 <= index < len(words)):
            return

        accepted, text = self._ask_annotation_text(
            "Word Text",
            "Type the text inside this word rectangle:",
            words[index].text,
        )
        if accepted:
            self.canvas.set_word_text(index, text)
        elif discard_on_cancel:
            self.canvas.discard_word(index)
        self._refresh_panel_list()

    def _ask_annotation_text(self, title: str, label: str, current_text: str):
        dialog = QInputDialog(self)
        dialog.setWindowTitle(title)
        dialog.setLabelText(label)
        dialog.setInputMode(QInputDialog.InputMode.TextInput)
        dialog.setTextValue(current_text)
        dialog.setOkButtonText("Save")
        dialog.setCancelButtonText("Cancel")

        line_edit = dialog.findChild(QLineEdit)
        button_box = dialog.findChild(QDialogButtonBox)
        ok_button = button_box.button(QDialogButtonBox.StandardButton.Ok) if button_box else None

        def update_ok_button(value: str):
            if ok_button:
                ok_button.setEnabled(bool(value.strip()))

        dialog.textValueChanged.connect(update_ok_button)
        update_ok_button(dialog.textValue())
        if line_edit:
            QTimer.singleShot(0, lambda: (line_edit.setFocus(), line_edit.selectAll()))

        accepted = dialog.exec() == QDialog.DialogCode.Accepted
        text = dialog.textValue().strip()
        return accepted and bool(text), text

    def _on_list_row_selected(self, row: int):
        self.canvas.select_panel(row)

    def _move_panel_up(self):
        idx = self.panel_list.currentRow()
        if idx > 0:
            self.canvas.move_panel_up(idx)

    def _move_panel_down(self):
        idx = self.panel_list.currentRow()
        if idx >= 0:
            self.canvas.move_panel_down(idx)

    def _on_cursor_position(self, ix: int, iy: int):
        self.lbl_status_coords.setText(f"X: {ix}, Y: {iy}")
        self.lbl_status_zoom.setText(f"Zoom: {int(self.canvas.zoom_factor * 100)}%")


def main():
    import argparse
    parser = argparse.ArgumentParser(description="PanelsPlus Manga Panel Annotator")
    parser.add_argument("file", nargs="?", help="Optional path to comic file (.cbz, .cbr, .pdf, .epub, .mobi, etc.)")
    parser.add_argument("--dataset-dir", default=None, help="Target dataset directory (defaults to tests/dataset-mangas/dataset)")
    args = parser.parse_args()

    app = QApplication(sys.argv)
    app.setApplicationName("PanelsPlus Annotator")
    apply_dark_theme(app)

    window = AnnotatorMainWindow(initial_file=args.file, dataset_dir=args.dataset_dir)
    window.show()

    sys.exit(app.exec())


if __name__ == "__main__":
    main()
