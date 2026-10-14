#!/bin/sh
# Yazi EPUB previewer backend: <book.epub> <out.png> <max-pixels>
#
# Lives in assets/ because `ya pkg` installs only LICENSE, README.md, main.lua,
# root-level *.lua and the assets/ tree.
#
# Renders the book's first page through PyMuPDF, so no epub-thumbnailer /
# gnome-epub-thumbnailer (both Linux-only) are involved.
#
# main.lua runs this as `sh render.sh ...` because `ya pkg` installs files
# read-only and the executable bit does not survive installation.
set -eu

src=${1:?usage: render.sh <book.epub> <out.png> <max-pixels>}
dst=${2:?usage: render.sh <book.epub> <out.png> <max-pixels>}
size=${3:-1800}

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# Take the first interpreter that can actually import PyMuPDF: a bare `python3`
# often cannot, so every candidate is probed rather than assumed. Set
# EPUB_PREVIEW_PYTHON to try one first.
for py in "${EPUB_PREVIEW_PYTHON:-}" python3 python "$HOME/.local/share/uv/tools/kittypdf/bin/python"; do
	[ -n "$py" ] || continue
	case $py in
	/*) [ -x "$py" ] || continue ;;
	*) command -v "$py" >/dev/null 2>&1 || continue ;;
	esac
	"$py" -c 'import pymupdf' >/dev/null 2>&1 || continue
	exec "$py" "$self_dir/render.py" "$src" "$dst" "$size"
done

echo "epub-preview: no Python with PyMuPDF found. Install it (python3 -m pip install pymupdf, or a venv/uv tool that has it), or set EPUB_PREVIEW_PYTHON to an interpreter that can import it." >&2
exit 1
