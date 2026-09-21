"""
PanelsPlus Manga Dataset Annotator package.
"""

from .document_reader import DocumentReader, DocumentPage
from .dataset_manager import DatasetManager, Panel, PhraseRect, WordRect, PageAnnotation
from .canvas import MangaCanvas
from .app import AnnotatorMainWindow

__all__ = [
    "DocumentReader",
    "DocumentPage",
    "DatasetManager",
    "Panel",
    "PhraseRect",
    "WordRect",
    "PageAnnotation",
    "MangaCanvas",
    "AnnotatorMainWindow",
]
