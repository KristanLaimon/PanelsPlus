"""Continuous native-pixel geometry; rectangles belong to the page they start on.

A rectangle may extend past its owner's bottom edge. Never split it at a seam:
that would turn one human annotation into two panels. Source images stay intact.
"""
from bisect import bisect_left, bisect_right


class StripLayout:
    def __init__(self, reader):
        self.offsets = []
        self.width = self.height = 0
        for page in reader.pages:
            self.offsets.append(self.height)
            self.width = max(self.width, page.native_w)
            self.height += page.native_h

    def owner(self, y):
        return max(0, min(len(self.offsets) - 1, bisect_right(self.offsets, y) - 1))

    def intersecting(self, top, bottom):
        """Source pages overlapping a vertical interval, found without a chapter scan."""
        top, bottom = max(0, top), min(self.height, bottom)
        if top >= bottom:
            return range(0)
        return range(self.owner(top), bisect_left(self.offsets, bottom))

    def join(self, manager, title, layer, algorithm="smart"):
        result = []
        for index, offset in enumerate(self.offsets, 1):
            annotation = (manager.get_panel_annotation(title, index, algorithm)
                          if layer == "frames" else manager.get_page_annotation(title, index))
            for rect in getattr(annotation, layer):
                rect = rect.copy()
                rect.y += offset
                result.append(rect)
        return result

    def split(self, rectangles):
        pages = [[] for _ in self.offsets]
        for rectangle in rectangles:
            index = self.owner(rectangle.y)
            rectangle = rectangle.copy()
            rectangle.y -= self.offsets[index]
            pages[index].append(rectangle)
        return pages
