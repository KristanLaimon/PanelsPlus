"""
Dataset manager for PanelsPlus format annotations.
Stores books under dataset/<bookfriendlyname>/00.png, 01.png...
Maintains per-book metadata and master annotation.json schemas.
"""

import json
import os
import re
import shutil
import time
from datetime import datetime
from typing import Dict, List, Optional, Tuple
from PIL import Image


class Panel:
    """Bounding box for a single panel in native pixel coordinates."""

    def __init__(self, x: int, y: int, w: int, h: int):
        self.x = int(round(x))
        self.y = int(round(y))
        self.w = max(1, int(round(w)))
        self.h = max(1, int(round(h)))

    def to_dict(self) -> dict:
        return {
            "x": self.x,
            "y": self.y,
            "w": self.w,
            "h": self.h,
        }

    @classmethod
    def from_dict(cls, d: dict) -> "Panel":
        return cls(x=d["x"], y=d["y"], w=d["w"], h=d["h"])

    def copy(self) -> "Panel":
        return Panel(self.x, self.y, self.w, self.h)

    def contains_point(self, px: float, py: float) -> bool:
        return self.x <= px <= self.x + self.w and self.y <= py <= self.y + self.h

    def __repr__(self) -> str:
        return f"Panel(x={self.x}, y={self.y}, w={self.w}, h={self.h})"


class PhraseRect(Panel):
    """One rectangular fragment of a phrase; fragments may share a phrase ID."""

    def __init__(self, x: int, y: int, w: int, h: int, phrase_id: int):
        super().__init__(x, y, w, h)
        self.phrase_id = max(1, int(phrase_id))

    def to_dict(self) -> dict:
        d = super().to_dict()
        d["phrase_id"] = self.phrase_id
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "PhraseRect":
        return cls(d["x"], d["y"], d["w"], d["h"], d["phrase_id"])

    def copy(self) -> "PhraseRect":
        return PhraseRect(self.x, self.y, self.w, self.h, self.phrase_id)


class WordRect(Panel):
    """A word rectangle, optionally assigned to a phrase by geometric overlap."""

    def __init__(
        self,
        x: int,
        y: int,
        w: int,
        h: int,
        phrase_id: Optional[int] = None,
        text: str = "",
    ):
        super().__init__(x, y, w, h)
        self.phrase_id = int(phrase_id) if phrase_id is not None else None
        self.text = str(text).strip()

    def to_dict(self) -> dict:
        d = super().to_dict()
        if self.phrase_id is not None:
            d["phrase_id"] = self.phrase_id
        if self.text:
            d["text"] = self.text
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "WordRect":
        return cls(d["x"], d["y"], d["w"], d["h"], d.get("phrase_id"), d.get("text", ""))

    def copy(self) -> "WordRect":
        return WordRect(self.x, self.y, self.w, self.h, self.phrase_id, self.text)


class PageAnnotation:
    """Annotations and optional illustration classification for a single page."""

    SINGLE_PAGE_ILLUSTRATION = "single_page"
    DOUBLE_PAGE_ILLUSTRATION = "double_page"
    ILLUSTRATION_TYPES = {SINGLE_PAGE_ILLUSTRATION, DOUBLE_PAGE_ILLUSTRATION}

    def __init__(
        self,
        page_index: int,
        image_rel_path: Optional[str] = None,
        illustration_type: Optional[str] = None,
    ):
        self.page_index = page_index  # 1-indexed
        self.image_rel_path = image_rel_path
        self.frames: List[Panel] = []
        self.phrases: List[PhraseRect] = []
        self.words: List[WordRect] = []
        self.illustration_type = illustration_type if illustration_type in self.ILLUSTRATION_TYPES else None

    @property
    def effective_illustration_type(self) -> Optional[str]:
        """Return the saved type, defaulting legacy one-frame pages to single-page."""
        if self.illustration_type:
            return self.illustration_type
        if len(self.frames) == 1:
            return self.SINGLE_PAGE_ILLUSTRATION
        return None

    def reassign_word_phrases(self) -> None:
        """Derive word ownership from overlap, preferring the largest intersection."""
        for word in self.words:
            candidates = []
            for phrase in self.phrases:
                overlap_w = max(
                    0,
                    min(word.x + word.w, phrase.x + phrase.w) - max(word.x, phrase.x),
                )
                overlap_h = max(
                    0,
                    min(word.y + word.h, phrase.y + phrase.h) - max(word.y, phrase.y),
                )
                area = overlap_w * overlap_h
                if area > 0:
                    candidates.append((area, phrase.phrase_id))
            word.phrase_id = max(candidates, default=(0, None))[1]

    def to_dict(self) -> dict:
        d = {
            "page_index": self.page_index,
            "frame": [p.to_dict() for p in self.frames],
        }
        if self.phrases:
            d["phrase"] = [p.to_dict() for p in self.phrases]
        if self.words:
            d["word"] = [w.to_dict() for w in self.words]
        if self.phrases or self.words:
            d["text_direction"] = "ltr"
        illustration_type = self.effective_illustration_type
        if illustration_type:
            d["illustration_type"] = illustration_type
        if self.image_rel_path:
            d["image_paths"] = {
                "en": self.image_rel_path
            }
        return d

    @classmethod
    def from_dict(cls, d: dict) -> "PageAnnotation":
        rel_img = None
        if "image_paths" in d and isinstance(d["image_paths"], dict):
            rel_img = d["image_paths"].get("en") or d["image_paths"].get("ja") or next(iter(d["image_paths"].values()), None)
        illustration_type = d.get("illustration_type")
        pa = cls(
            page_index=d["page_index"],
            image_rel_path=rel_img,
            illustration_type=illustration_type,
        )
        for f in d.get("frame", []):
            pa.frames.append(Panel.from_dict(f))
        for phrase in d.get("phrase", []):
            pa.phrases.append(PhraseRect.from_dict(phrase))
        for word in d.get("word", []):
            pa.words.append(WordRect.from_dict(word))
        pa.reassign_word_phrases()
        return pa

    def copy(self) -> "PageAnnotation":
        pa = PageAnnotation(self.page_index, self.image_rel_path, self.illustration_type)
        pa.frames = [p.copy() for p in self.frames]
        pa.phrases = [p.copy() for p in self.phrases]
        pa.words = [w.copy() for w in self.words]
        return pa


class DatasetManager:
    """Manages books, recent projects, pages, and annotations."""

    def __init__(self, dataset_dir: str):
        self.dataset_dir = os.path.abspath(dataset_dir)
        os.makedirs(self.dataset_dir, exist_ok=True)
        self.books: Dict[str, Dict[int, PageAnnotation]] = {}  # book_title -> {page_index: PageAnnotation}
        self.master_annotation_file = os.path.join(self.dataset_dir, "annotation.json")

        self.load_dataset()

    def load_dataset(self) -> None:
        """Load annotations from master annotation.json and individual book folders."""
        # 1. Load from master annotation.json if present
        if os.path.exists(self.master_annotation_file):
            try:
                with open(self.master_annotation_file, "r", encoding="utf-8") as f:
                    data = json.load(f)
                if isinstance(data, list):
                    for book_entry in data:
                        title = book_entry.get("book_title", "untitled")
                        if title not in self.books:
                            self.books[title] = {}
                        for page_entry in book_entry.get("pages", []):
                            pa = PageAnnotation.from_dict(page_entry)
                            self.books[title][pa.page_index] = pa
            except Exception as e:
                print(f"Warning loading {self.master_annotation_file}: {e}")

        # 2. Scan subdirectories in dataset_dir for individual book annotations
        for entry in os.scandir(self.dataset_dir):
            if entry.is_dir() and not entry.name.startswith("."):
                book_dir = entry.path
                book_title = entry.name
                book_ann_file = os.path.join(book_dir, "annotation.json")
                if os.path.exists(book_ann_file):
                    try:
                        with open(book_ann_file, "r", encoding="utf-8") as f:
                            ann_data = json.load(f)
                        if isinstance(ann_data, list) and ann_data:
                            book_entry = ann_data[0]
                            if book_title not in self.books:
                                self.books[book_title] = {}
                            for page_entry in book_entry.get("pages", []):
                                pa = PageAnnotation.from_dict(page_entry)
                                self.books[book_title][pa.page_index] = pa
                    except Exception as e:
                        print(f"Warning loading {book_ann_file}: {e}")

    def get_book_dir(self, book_title: str) -> str:
        """Return the directory path for a book inside dataset/."""
        clean_title = re.sub(r'[\s_]+', '_', book_title.strip())
        return os.path.join(self.dataset_dir, clean_title)

    def get_metadata_path(self, book_title: str) -> str:
        return os.path.join(self.get_book_dir(book_title), "metadata.json")

    def load_book_metadata(self, book_title: str) -> dict:
        meta_file = self.get_metadata_path(book_title)
        if os.path.exists(meta_file):
            try:
                with open(meta_file, "r", encoding="utf-8") as f:
                    return json.load(f)
            except Exception:
                pass
        return {
            "book_title": book_title,
            "type": "manga",
            "total_pages": 0,
            "finished": False,
            "current_page": 1,
            "last_opened": datetime.now().isoformat(),
            "source_file": "",
        }

    def save_book_metadata(self, book_title: str, metadata: dict) -> None:
        dataset_type = metadata.get("type", "manga")
        if dataset_type not in ("manga", "comic"):
            raise ValueError('metadata type must be "manga" or "comic"')
        if "color_mode" in metadata:
            if dataset_type != "comic":
                raise ValueError('color_mode is only valid for comic datasets')
            if metadata["color_mode"] not in ("true_b/w", "colorless_b/w", "color"):
                raise ValueError('color_mode must be "true_b/w", "colorless_b/w", or "color"')
        metadata["type"] = dataset_type
        book_dir = self.get_book_dir(book_title)
        os.makedirs(book_dir, exist_ok=True)
        meta_file = self.get_metadata_path(book_title)
        with open(meta_file, "w", encoding="utf-8") as f:
            json.dump(metadata, f, indent=2, ensure_ascii=False)

    def mark_book_finished(self, book_title: str, finished: bool = True) -> None:
        meta = self.load_book_metadata(book_title)
        meta["finished"] = finished
        meta["last_opened"] = datetime.now().isoformat()
        self.save_book_metadata(book_title, meta)

    def update_last_opened(self, book_title: str, current_page: int = 1) -> None:
        meta = self.load_book_metadata(book_title)
        meta["last_opened"] = datetime.now().isoformat()
        meta["current_page"] = current_page
        self.save_book_metadata(book_title, meta)

    def get_recent_books(self) -> List[dict]:
        """Return list of all books in dataset sorted by last_opened descending."""
        recent_list = []
        for entry in os.scandir(self.dataset_dir):
            if entry.is_dir() and not entry.name.startswith("."):
                book_title = entry.name
                book_dir = entry.path

                # Count extracted pages
                png_files = [f for f in os.listdir(book_dir) if f.lower().endswith(".png")]
                png_files.sort()
                total_pages = len(png_files)

                # Cover image
                cover_file = os.path.join(book_dir, "00.png")
                if not os.path.exists(cover_file) and png_files:
                    cover_file = os.path.join(book_dir, png_files[0])

                # Load metadata
                meta = self.load_book_metadata(book_title)
                if total_pages > 0 and meta.get("total_pages", 0) == 0:
                    meta["total_pages"] = total_pages
                    self.save_book_metadata(book_title, meta)

                total_pages = max(total_pages, meta.get("total_pages", 0))

                # Count annotated pages
                book_pages = self.books.get(book_title, {})
                annotated_count = sum(1 for pa in book_pages.values() if pa.frames)

                # Progress percentage
                if meta.get("finished", False):
                    progress_pct = 100
                elif total_pages > 0:
                    progress_pct = min(100, int((annotated_count / total_pages) * 100))
                else:
                    progress_pct = 0

                recent_list.append({
                    "book_title": book_title,
                    "type": meta.get("type", "manga"),
                    "book_dir": book_dir,
                    "cover_path": cover_file if os.path.exists(cover_file) else None,
                    "total_pages": total_pages,
                    "annotated_pages": annotated_count,
                    "progress_percent": progress_pct,
                    "finished": meta.get("finished", False),
                    "current_page": meta.get("current_page", 1),
                    "last_opened": meta.get("last_opened", ""),
                    "source_file": meta.get("source_file", ""),
                })

        # Sort by last_opened descending
        recent_list.sort(key=lambda b: b.get("last_opened", ""), reverse=True)
        return recent_list

    def get_page_annotation(self, book_title: str, page_index: int) -> PageAnnotation:
        if book_title not in self.books:
            self.books[book_title] = {}
        if page_index not in self.books[book_title]:
            # Default relative image path: <book_title>/00.png, 01.png...
            rel_img = f"{book_title}/{(page_index - 1):02d}.png"
            self.books[book_title][page_index] = PageAnnotation(page_index=page_index, image_rel_path=rel_img)
        return self.books[book_title][page_index]

    def set_page_frames(self, book_title: str, page_index: int, frames: List[Panel]) -> None:
        pa = self.get_page_annotation(book_title, page_index)
        pa.frames = [p.copy() for p in frames]
        if not pa.image_rel_path:
            pa.image_rel_path = f"{book_title}/{(page_index - 1):02d}.png"

    def set_page_text_annotations(
        self,
        book_title: str,
        page_index: int,
        phrases: List[PhraseRect],
        words: List[WordRect],
    ) -> None:
        pa = self.get_page_annotation(book_title, page_index)
        pa.phrases = sorted(
            (p.copy() for p in phrases), key=lambda p: (p.phrase_id, p.y, p.x)
        )
        # Phrase, then visual line, then left-to-right position.
        pa.words = sorted(
            (w.copy() for w in words),
            key=lambda w: (w.phrase_id is None, w.phrase_id or 0, w.y, w.x),
        )
        pa.reassign_word_phrases()
        pa.words.sort(key=lambda w: (w.phrase_id is None, w.phrase_id or 0, w.y, w.x))

    def validate_page_text_annotations(self, book_title: str, page_index: int) -> List[str]:
        """Return human-readable errors without rejecting legacy panel-only pages."""
        pa = self.get_page_annotation(book_title, page_index)
        errors: List[str] = []
        phrase_ids = sorted({p.phrase_id for p in pa.phrases})
        word_phrase_ids = {w.phrase_id for w in pa.words if w.phrase_id is not None}
        missing = [pid for pid in phrase_ids if pid not in word_phrase_ids]
        if missing:
            errors.append("phrases without words: " + ", ".join(str(pid) for pid in missing))
        orphan_count = sum(1 for w in pa.words if w.phrase_id not in phrase_ids)
        if orphan_count:
            errors.append(f"{orphan_count} word rectangle(s) do not overlap a phrase")
        missing_text_count = sum(1 for w in pa.words if not w.text.strip())
        if missing_text_count:
            errors.append(f"{missing_text_count} word rectangle(s) have no text")
        return errors

    def validate_book_text_annotations(self, book_title: str) -> Dict[int, List[str]]:
        """Validate every annotated page in a book, returning errors keyed by page."""
        failures: Dict[int, List[str]] = {}
        for page_index in sorted(self.books.get(book_title, {})):
            errors = self.validate_page_text_annotations(book_title, page_index)
            if errors:
                failures[page_index] = errors
        return failures

    def set_page_illustration_type(
        self, book_title: str, page_index: int, illustration_type: Optional[str]
    ) -> None:
        """Set an explicit full-page illustration type, or clear it for normal panels."""
        if illustration_type is not None and illustration_type not in PageAnnotation.ILLUSTRATION_TYPES:
            raise ValueError(f"Unsupported illustration type: {illustration_type}")
        self.get_page_annotation(book_title, page_index).illustration_type = illustration_type

    def export_page_image(self, book_title: str, page_index: int, pil_image: Image.Image, ext: str = "png") -> str:
        """Save page image to dataset/<book_title>/00.png, 01.png... and return relative path."""
        book_dir = self.get_book_dir(book_title)
        os.makedirs(book_dir, exist_ok=True)
        filename = f"{(page_index - 1):02d}.{ext}"
        abs_path = os.path.join(book_dir, filename)
        rel_path = f"{book_title}/{filename}"
        if ext.lower() in ("jpg", "jpeg"):
            if pil_image.mode in ("RGBA", "P"):
                pil_image = pil_image.convert("RGB")
            pil_image.save(abs_path, format="JPEG", quality=95)
        else:
            pil_image.save(abs_path, format="PNG")
        pa = self.get_page_annotation(book_title, page_index)
        pa.image_rel_path = rel_path
        return rel_path

    def save_book_dataset(self, book_title: str) -> str:
        """Save annotations for a specific book and update master annotation.json."""
        failures = self.validate_book_text_annotations(book_title)
        if failures:
            raise ValueError(f"Incomplete text annotations for {book_title}: {failures}")
        book_dir = self.get_book_dir(book_title)
        os.makedirs(book_dir, exist_ok=True)

        metadata = self.load_book_metadata(book_title)
        metadata["annotation_schema_version"] = 2
        metadata["annotation_layers"] = ["panel", "phrase", "word"]
        metadata["text_direction"] = "ltr"
        self.save_book_metadata(book_title, metadata)

        # 1. Book-specific annotation.json
        pages_dict = self.books.get(book_title, {})
        pages_list = []
        for p_idx in sorted(pages_dict.keys()):
            pa = pages_dict[p_idx]
            if pa.frames or pa.phrases or pa.words or pa.image_rel_path:
                d = pa.to_dict()
                if "image_paths" in d and isinstance(d["image_paths"], dict):
                    for lang in list(d["image_paths"].keys()):
                        fname = os.path.basename(d["image_paths"][lang])
                        d["image_paths"][lang] = f"{book_title}/{fname}"
                pages_list.append(d)

        book_json = [{
            "book_title": book_title,
            "annotation_schema_version": 2,
            "pages": pages_list,
        }]
        book_json_path = os.path.join(book_dir, "annotation.json")
        with open(book_json_path, "w", encoding="utf-8") as f:
            json.dump(book_json, f, indent=2, ensure_ascii=False)

        # 2. Update master dataset/annotation.json if it exists
        if os.path.exists(self.master_annotation_file):
            self.save_master_dataset()
        return book_json_path

    def save_master_dataset(self) -> str:
        """Write current annotations across all books into master annotation.json."""
        for book_title in self.books:
            failures = self.validate_book_text_annotations(book_title)
            if failures:
                raise ValueError(f"Incomplete text annotations for {book_title}: {failures}")
        dataset_array = []
        for book_title in sorted(self.books.keys()):
            pages_dict = self.books[book_title]
            pages_list = []
            for p_idx in sorted(pages_dict.keys()):
                pa = pages_dict[p_idx]
                if pa.frames or pa.phrases or pa.words or pa.image_rel_path:
                    d = pa.to_dict()
                    if "image_paths" in d and isinstance(d["image_paths"], dict):
                        for lang in list(d["image_paths"].keys()):
                            fname = os.path.basename(d["image_paths"][lang])
                            d["image_paths"][lang] = f"{book_title}/{fname}"
                    pages_list.append(d)

            if pages_list:
                dataset_array.append({
                    "book_title": book_title,
                    "annotation_schema_version": 2,
                    "pages": pages_list,
                })

        with open(self.master_annotation_file, "w", encoding="utf-8") as f:
            json.dump(dataset_array, f, indent=2, ensure_ascii=False)

        return self.master_annotation_file

    def save_dataset(self) -> str:
        """Backwards compatible alias for save_master_dataset."""
        return self.save_master_dataset()
