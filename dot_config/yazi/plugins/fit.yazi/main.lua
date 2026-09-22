--- @since 26.8.15
--
-- fit.yazi：图片预览器——小图重采样放大到铺满预览窗。
--
-- 背景：yazi 本体"只缩不放"（sxyazi/yazi#3550：max_* 是上限不是目标尺寸，
-- 且不提供配置开关），官方建议的铺满实现就是自定义 previewer。
-- 本插件取代社区的 stellarjmr/image-fit（sips 版），自己维护，要点：
--   * 只在图小于预览窗时才 fork `magick` 放大；大图直接走内建缩小（零开销）
--   * 放大产物写 ya.file_cache（yazi 托管缓存路径），不往 /tmp 堆临时文件
--   * magick 缺失/失败一律回退内建渲染，最坏等于原生行为

local M = {}

-- 预览窗像素上限：终端 cell 尺寸可得时取窗实际像素，再夹 [preview] max_* 配置
local function canvas(area)
	local cw, ch = rt.term.cell_size()
	if not cw then
		return rt.preview.max_width, rt.preview.max_height
	end
	return math.min(rt.preview.max_width, math.floor(area.w * cw)),
		math.min(rt.preview.max_height, math.floor(area.h * ch))
end

local function fallback(job, url)
	ya.image_show(url or job.file.url, job.area)
end

function M:peek(job)
	local url = job.file.url

	local info, err = ya.image_info(url)
	if not info then
		fallback(job, url)
		return ya.preview_widget(job, Err("Failed to get image info: %s", err))
	end

	local max_w, max_h = canvas(job.area)
	local scale = math.min(max_w / info.w, max_h / info.h)
	if scale <= 1 then
		-- 大图：内建渲染本来就是缩到铺满，不过 magick
		return fallback(job, url)
	end

	local cache = ya.file_cache(job)
	if not cache then
		return fallback(job, url)
	end

	local status, cerr = Command("magick"):arg({
		tostring(url),
		"-auto-orient", "-strip",
		"-filter", rt.preview.image_filter,
		"-resize", string.format("%dx%d!", math.floor(info.w * scale), math.floor(info.h * scale)),
		"-quality", rt.preview.image_quality,
		string.format("JPG:%s", tostring(cache)),
	}):status()
	if not status then
		ya.notify { title = "fit", content = "Failed to run `magick`: " .. tostring(cerr), timeout = 5, level = "error" }
		return fallback(job, url)
	elseif not status.success then
		ya.notify { title = "fit", content = "`magick` exited with code " .. status.code, timeout = 5, level = "error" }
		return fallback(job, url)
	end

	ya.image_show(cache, job.area)
end

function M:seek() end

return M
