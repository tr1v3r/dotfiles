-- Preview an EPUB by rendering its first page -- normally the cover -- into
-- Yazi's image pipeline.
--
-- Yazi ships no EPUB previewer, and `application/epub+zip` matches none of the
-- built-in rules: the archive rule `application/{,g}zip` expands to exactly
-- `application/zip` and `application/gzip`, never `application/epub+zip`. An
-- EPUB therefore fell through to the `file` preset, whose entire output is
-- "----- File Type Classification -----\n\nEPUB document".
--
-- The pixels come from PyMuPDF (see assets/render.sh, assets/render.py). This
-- built-in `pdf` preset: render out of process, precache into Yazi's image
-- cache, then draw it.

local M = {}

local function config_dir()
	return os.getenv("YAZI_CONFIG_HOME")
		or ((os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")) .. "/yazi")
end

function M:setup(opts)
	opts = opts or {}
	self._renderer = opts.renderer
	self._size = opts.size
end

-- Helpers live in assets/ because `ya pkg` installs only LICENSE, README.md,
-- main.lua, root-level *.lua and the assets/ tree -- a root-level render.sh
-- would silently never be installed.
-- Overridable, since Yazi does not tell a plugin where it was installed.
function M:renderer()
	return self._renderer or (config_dir() .. "/plugins/epub-preview.yazi/assets/render.sh")
end

function M:size()
	return self._size or math.min(rt.preview.max_width, rt.preview.max_height)
end

function M:peek(job)
	local start, cache = os.clock(), ya.file_cache(job)
	if not cache then
		return
	end

	local ok, err = self:preload(job)
	if not ok or err then
		return ya.preview_widget(job, err)
	end

	ya.sleep(math.max(0, rt.preview.image_delay / 1000 + start - os.clock()))

	local _, err = ya.image_show(cache, job.area)
	ya.preview_widget(job, err)
end

function M:seek() end

function M:preload(job)
	local cache = ya.file_cache(job)
	if not cache or fs.cha(cache) then
		return true
	end

	local png = Url(cache .. ".png")
	-- Run through `sh` rather than executing the script directly: `ya pkg` seals
	-- installed files read-only, so the executable bit does not survive.
	-- stylua: ignore
	local output, err = Command("sh")
		:arg({
			self:renderer(),
			tostring(job.file.path),
			tostring(png),
			tostring(self:size()),
		})
		:output()

	if not output then
		return true, Err("Failed to start the EPUB renderer, error: %s", err)
	elseif not output.status.success then
		local stderr = (output.stderr:gsub("%s+$", ""))
		return true, Err("Failed to render the EPUB cover, stderr: %s", stderr)
	end

	return ya.image_precache(png, cache)
end

function M:spot(job)
	local rows = self:spot_base(job)
	rows[#rows + 1] = ui.Row {}

	ya.spot_table(
		job,
		ui.Table(ya.list_merge(rows, require("file"):spot_base(job)))
			:area(ui.Pos { "center", w = 60, h = 20 })
			:row(1)
			:col(1)
			:col_style(th.spot.tbl_col)
			:cell_style(th.spot.tbl_cell)
			:widths { ui.Constraint.Length(14), ui.Constraint.Fill(1) }
	)
end

function M:spot_base(job)
	local cache = ya.file_cache(job)
	local png = cache and Url(cache .. ".png")
	local info = png and fs.cha(png) and ya.image_info(png)
	if not info then
		return {}
	end

	return {
		ui.Row({ "Cover" }):style(ui.Style():fg("green")),
		ui.Row { "  Format:", tostring(info.format) },
		ui.Row { "  Size:", string.format("%dx%d", info.w, info.h) },
	}
end

return M
