#!/bin/sh
# Yazi EPUB previewer backend: <book.epub> <out.png> <max-pixels>
#
# Kept as a shell hop so the plugin works with whichever Python already has
# PyMuPDF, instead of pinning Yazi's config to one interpreter path.
set -eu

src=${1:?usage: render.sh <book.epub> <out.png> <max-pixels>}
dst=${2:?usage: render.sh <book.epub> <out.png> <max-pixels>}
size=${3:-1800}

self_dir=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)

# First interpreter that actually imports PyMuPDF wins. kittypdf is a uv tool, so
# its interpreter is the one guaranteed to have it on this machine.
for py in "${EPUB_PREVIEW_PYTHON:-}" "$HOME/.local/share/uv/tools/kittypdf/bin/python" python3 python; do
	[ -n "$py" ] || continue
	case $py in
	/*) [ -x "$py" ] || continue ;;
	*) command -v "$py" >/dev/null 2>&1 || continue ;;
	esac
	"$py" -c 'import pymupdf' >/dev/null 2>&1 || continue
	exec "$py" "$self_dir/render.py" "$src" "$dst" "$size"
done

echo "epub-preview: no Python with PyMuPDF found (install it with: uv tool install kittypdf)" >&2
exit 1
