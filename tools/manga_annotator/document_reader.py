"""
Document reader engine supporting .cbz, .cbr, .pdf, .mobi, .epub, .kepub.epub, and image directories.
"""

import io
import os
import re
import shutil
import subprocess
import tempfile
import zipfile
from typing import List, Optional, Tuple
from PIL import Image

try:
    import fitz  # PyMuPDF
except ImportError:
    fitz = None


def natural_sort_key(s: str):
    """Sort strings containing numbers naturally (e.g., page 2 before page 10)."""
    return [int(text) if text.isdigit() else text.lower() for text in re.split(r'(\d+)', str(s))]


IMAGE_EXTENSIONS = {'.jpg', '.jpeg', '.png', '.webp', '.bmp', '.gif', '.tiff'}


class DocumentPage:
    """Represents a single page in a document."""

    def __init__(self, page_index: int, source_type: str, native_w: int, native_h: int):
        self.page_index = page_index  # 1-indexed
        self.source_type = source_type
        self.native_w = native_w
        self.native_h = native_h
        self._cached_pil: Optional[Image.Image] = None

    def get_pil_image(self) -> Image.Image:
        """Return PIL Image instance for this page."""
        raise NotImplementedError

    def save_image(self, target_path: str, format: str = "PNG") -> None:
        """Save this page image to the specified path."""
        os.makedirs(os.path.dirname(target_path), exist_ok=True)
        img = self.get_pil_image()
        if format.upper() == "JPEG" or target_path.lower().endswith(('.jpg', '.jpeg')):
            if img.mode in ("RGBA", "P"):
                img = img.convert("RGB")
            img.save(target_path, format="JPEG", quality=95)
        else:
            img.save(target_path, format="PNG")


class ArchiveImagePage(DocumentPage):
    """Page loaded from an image file or archive entry."""

    def __init__(self, page_index: int, image_bytes: Optional[bytes] = None, file_path: Optional[str] = None):
        self._image_bytes = image_bytes
        self._file_path = file_path

        # Determine native size
        if image_bytes is not None:
            with Image.open(io.BytesIO(image_bytes)) as im:
                w, h = im.size
        elif file_path and os.path.exists(file_path):
            with Image.open(file_path) as im:
                w, h = im.size
        else:
            w, h = 0, 0

        super().__init__(page_index=page_index, source_type="image", native_w=w, native_h=h)

    def get_pil_image(self) -> Image.Image:
        if self._cached_pil is not None:
            return self._cached_pil

        if self._image_bytes is not None:
            im = Image.open(io.BytesIO(self._image_bytes))
            im.load()
            self._cached_pil = im
            return im
        elif self._file_path:
            im = Image.open(self._file_path)
            im.load()
            self._cached_pil = im
            return im
        raise ValueError("No image source available for page")


class FitzDocumentPage(DocumentPage):
    """Page rendered from PyMuPDF (PDF, EPUB, MOBI)."""

    def __init__(self, page_index: int, doc: "fitz.Document", fitz_page_num: int, dpi: int = 150):
        self._doc = doc
        self._fitz_page_num = fitz_page_num
        self.dpi = dpi

        # Fetch page dimensions
        page = self._doc.load_page(fitz_page_num)
        rect = page.rect
        scale = dpi / 72.0
        w = max(1, int(rect.width * scale))
        h = max(1, int(rect.height * scale))

        super().__init__(page_index=page_index, source_type="fitz", native_w=w, native_h=h)

    def get_pil_image(self) -> Image.Image:
        if self._cached_pil is not None:
            return self._cached_pil

        page = self._doc.load_page(self._fitz_page_num)
        zoom = self.dpi / 72.0
        mat = fitz.Matrix(zoom, zoom)
        pix = page.get_pixmap(matrix=mat, alpha=False)

        im = Image.frombytes("RGB", [pix.width, pix.height], pix.samples)
        self.native_w = pix.width
        self.native_h = pix.height
        self._cached_pil = im
        return im


class DocumentReader:
    """Unified reader for comic and document archives."""

    def __init__(self, file_or_dir_path: str, render_dpi: int = 150):
        self.source_path = os.path.abspath(file_or_dir_path)
        self.render_dpi = render_dpi
        self.book_title = os.path.splitext(os.path.basename(self.source_path))[0]
        self.book_title = re.sub(r'[\s_]+', '_', self.book_title.strip())
        self.pages: List[DocumentPage] = []
        self._temp_dirs: List[str] = []
        self._fitz_doc = None

        self._load()

    def _load(self):
        if os.path.isdir(self.source_path):
            self._load_directory(self.source_path)
            return

        ext = os.path.splitext(self.source_path)[1].lower()
        if self.source_path.lower().endswith('.kepub.epub'):
            ext = '.kepub.epub'

        if ext == '.cbz':
            self._load_cbz(self.source_path)
        elif ext == '.cbr':
            self._load_cbr(self.source_path)
        elif ext in ('.pdf', '.epub', '.kepub.epub', '.mobi'):
            self._load_fitz(self.source_path)
        elif ext in IMAGE_EXTENSIONS:
            self.pages = [ArchiveImagePage(page_index=1, file_path=self.source_path)]
        else:
            # Try fitz first, then zip, then directory
            try:
                self._load_fitz(self.source_path)
            except Exception:
                try:
                    self._load_cbz(self.source_path)
                except Exception:
                    raise ValueError(f"Unsupported document format: {self.source_path}")

    def _load_directory(self, dir_path: str):
        image_files = []
        for root, _, files in os.walk(dir_path):
            for f in files:
                ext = os.path.splitext(f)[1].lower()
                if ext in IMAGE_EXTENSIONS:
                    image_files.append(os.path.join(root, f))

        image_files.sort(key=natural_sort_key)
        for idx, fpath in enumerate(image_files, start=1):
            self.pages.append(ArchiveImagePage(page_index=idx, file_path=fpath))

    def _load_cbz(self, cbz_path: str):
        with zipfile.ZipFile(cbz_path, 'r') as zf:
            file_list = [f for f in zf.namelist() if os.path.splitext(f)[1].lower() in IMAGE_EXTENSIONS and not f.startswith('__MACOSX/')]
            file_list.sort(key=natural_sort_key)

            for idx, fname in enumerate(file_list, start=1):
                data = zf.read(fname)
                self.pages.append(ArchiveImagePage(page_index=idx, image_bytes=data))

    def _load_cbr(self, cbr_path: str):
        """Extract CBR (RAR or ZIP) into a temp directory."""
        temp_dir = tempfile.mkdtemp(prefix="panelsplus_cbr_")
        self._temp_dirs.append(temp_dir)

        # 1. Try unrar if available
        unrar_bin = shutil.which("unrar")
        extracted = False
        if unrar_bin:
            try:
                res = subprocess.run([unrar_bin, "x", "-y", "-inul", cbr_path, temp_dir], capture_output=True)
                if res.returncode == 0:
                    extracted = True
            except Exception:
                pass

        # 2. Try bsdtar if unrar failed
        if not extracted:
            bsdtar_bin = shutil.which("bsdtar")
            if bsdtar_bin:
                try:
                    res = subprocess.run([bsdtar_bin, "-xf", cbr_path, "-C", temp_dir], capture_output=True)
                    if res.returncode == 0:
                        extracted = True
                except Exception:
                    pass

        # 3. Fallback: might actually be a zip file with .cbr extension
        if not extracted and zipfile.is_zipfile(cbr_path):
            try:
                with zipfile.ZipFile(cbr_path, 'r') as zf:
                    zf.extractall(temp_dir)
                extracted = True
            except Exception:
                pass

        if not extracted:
            raise RuntimeError(f"Could not extract CBR archive: {cbr_path}. Ensure 'unrar' or 'bsdtar' is installed.")

        self._load_directory(temp_dir)

    def _load_fitz(self, doc_path: str):
        if fitz is None:
            raise RuntimeError("PyMuPDF (fitz) is not installed.")

        # Check if EPUB has direct manga images that can be extracted losslessly
        ext = os.path.splitext(doc_path)[1].lower()
        if ext in ('.epub', '.kepub.epub') and zipfile.is_zipfile(doc_path):
            try:
                with zipfile.ZipFile(doc_path, 'r') as zf:
                    image_entries = [
                        f for f in zf.namelist()
                        if os.path.splitext(f)[1].lower() in IMAGE_EXTENSIONS
                        and not f.startswith('__MACOSX/')
                        and not 'thumb' in f.lower()
                    ]
                    if len(image_entries) > 3:
                        image_entries.sort(key=natural_sort_key)
                        for idx, fname in enumerate(image_entries, start=1):
                            data = zf.read(fname)
                            self.pages.append(ArchiveImagePage(page_index=idx, image_bytes=data))
                        return
            except Exception:
                pass

        self._fitz_doc = fitz.open(doc_path)
        for idx in range(len(self._fitz_doc)):
            self.pages.append(FitzDocumentPage(page_index=idx + 1, doc=self._fitz_doc, fitz_page_num=idx, dpi=self.render_dpi))

    def get_page(self, page_index: int) -> Optional[DocumentPage]:
        if 1 <= page_index <= len(self.pages):
            return self.pages[page_index - 1]
        return None

    @property
    def total_pages(self) -> int:
        return len(self.pages)

    def extract_all_pages(self, target_dir: str, progress_callback=None) -> List[str]:
        """Extract all pages as 00.png, 01.png, 02.png... into target_dir.
        If progress_callback returns False, extraction stops immediately.
        """
        os.makedirs(target_dir, exist_ok=True)
        extracted_paths = []
        total = len(self.pages)
        for i, page in enumerate(self.pages):
            if progress_callback:
                if progress_callback(i, total) is False:
                    break
            filename = f"{i:02d}.png"
            out_path = os.path.join(target_dir, filename)
            if not os.path.exists(out_path):
                page.save_image(out_path, format="PNG")
            extracted_paths.append(out_path)
            if progress_callback:
                if progress_callback(i + 1, total) is False:
                    break
        return extracted_paths

    def close(self):
        if self._fitz_doc:
            self._fitz_doc.close()
            self._fitz_doc = None
        for temp_dir in self._temp_dirs:
            if os.path.exists(temp_dir):
                shutil.rmtree(temp_dir, ignore_errors=True)
        self._temp_dirs.clear()

    def __del__(self):
        self.close()
