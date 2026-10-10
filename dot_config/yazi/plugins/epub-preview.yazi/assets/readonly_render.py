#!/usr/bin/env python3
"""Render page 1 of an EPUB to a PNG for Yazi's preview pane.

Page 1 of an EPUB is almost always the cover, so this doubles as a thumbnail.
MuPDF's reflowable-HTML engine lays EPUB content out into fixed pages, so no
separate EPUB/OPF parsing is needed and every flavour (EPUB 2, EPUB 3, cover
declared via metadata or not) is handled.

Usage: render.py <book.epub> <out.png> <max-pixels>
"""

import sys


def main(argv):
    src, dst, size = argv[1], argv[2], int(argv[3])

    import pymupdf

    # Hand-made EPUBs reference fonts that were never shipped (e.g. Sony reader
    # paths in converted books); MuPDF narrates every miss on stderr, which would
    # otherwise drown out real errors in Yazi's preview pane.
    pymupdf.TOOLS.mupdf_display_errors(False)
    pymupdf.TOOLS.mupdf_display_warnings(False)

    # PyMuPDF raises a different class per failure mode (EmptyFileError,
    # FileDataError, FzErrorUnsupported, ...); the preview pane wants the gist
    # rather than a traceback, so collapse them into one line on stderr.
    try:
        with pymupdf.open(src) as doc:
            if doc.page_count < 1:
                raise SystemExit(f"no pages in {src}")

            page = doc[0]
            longest = max(page.rect.width, page.rect.height) or 1
            # Aim the long edge at the pane's pixel budget so the cached PNG
            # stays cheap, but never zoom past 4x: a small cover should not be
            # blown up into a blurry blob just because the pane is large.
            zoom = min(max(size, 1) / longest, 4.0)
            pix = page.get_pixmap(matrix=pymupdf.Matrix(zoom, zoom), alpha=False)
            pix.save(dst, "png")
    except SystemExit:
        raise
    except Exception as exc:
        raise SystemExit(f"cannot render {src}: {exc}")


if __name__ == "__main__":
    main(sys.argv)
