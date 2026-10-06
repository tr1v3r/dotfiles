-- EPUB previewer: render page 1 (normally the cover) as an image instead of
-- letting `application/epub+zip` fall through to the `file` preset, which prints
-- nothing but "----- File Type Classification -----\n\nEPUB document".
--
-- Mirrors the built-in `pdf` previewer: pixels are produced out of process,
-- precached into Yazi's image cache, then drawn with `ya.image_show`.

local M = {}

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
	-- stylua: ignore
	local output, err = Command(M:renderer())
		:arg({
			tostring(job.file.path),
			tostring(png),
			tostring(math.min(rt.preview.max_width, rt.preview.max_height)),
		})
		:output()

	if not output then
		return true, Err("Failed to start the EPUB renderer, error: %s", err)
	elseif not output.status.success then
		local stderr = output.stderr:gsub("%s+$", "")
		return true, Err("Failed to render the EPUB cover, stderr: %s", stderr)
	end

	return ya.image_precache(png, cache)
end

-- Resolved per call rather than at load time so YAZI_CONFIG_HOME overrides work.
function M:renderer()
	local config = os.getenv("YAZI_CONFIG_HOME")
		or ((os.getenv("XDG_CONFIG_HOME") or ((os.getenv("HOME") or "") .. "/.config")) .. "/yazi")
	return config .. "/plugins/epub-preview.yazi/render.sh"
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
