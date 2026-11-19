-- Docs: https://yazi-rs.github.io/

-- https://github.com/llanosrocas/yaziline.yazi
-- require("yaziline"):setup({
-- 	separator_style = "curvy",
-- 	select_symbol = "",
-- 	yank_symbol = "󰆐",
-- 	filename_max_length = 24, -- trim when filename > 24
-- 	filename_trim_length = 6, -- trim 6 chars from both ends
-- })

require("starship"):setup({
	config_file = "~/.config/yazi/starship.toml",
})
require("full-border"):setup({ type = ui.Border.ROUNDED })
require("agent-tui"):setup({ profile = "tui" })

-- CLI Pointer：绕过内建 indicator 的 reversed 背景和两侧 powerline padding，
-- 只保留无背景指针与层级色：当前项 cyan；父目录路径锚点用亮前景、blue 指针。
-- 备选 Cursor Rail：将下方 " " 改为 "▎ "。
function Entity:style()
	local base = self._file:style() or ui.Style()
	if not self._file.is_hovered then
		return base
	elseif self._file.in_current then
		return base:patch(ui.Style():fg("#7dcfff"):bold(false):underline(false):reverse(true))
	elseif self._file.in_preview then
		return base:patch(ui.Style():fg("#7dcfff"):underline(false):reverse(true))
	else
		return base:patch(ui.Style():fg("#89b4fa"):bold(false):reverse(true))
	end
end

Entity:children_remove(1)
Entity:children_add(function(self)
	if not self._file.is_hovered then
		return "  "
	end
	local color = self._file.in_current and "#7dcfff" or "#7aa2f7"
	return ui.Span(" "):fg(color)
end, 1000)

Linemode:children_remove(2)
Linemode:children_add(function()
	return " "
end, 2000)

-- Header / Footer CLI HUD：延续无背景、语义色、细分隔线语言，但不照搬当前项指针。
local hud = {
	fg = "#c0caf5",
	muted = "#565f89",
	blue = "#7aa2f7",
	cyan = "#7dcfff",
	green = "#9ece6a",
	yellow = "#e0af68",
	red = "#f7768e",
	purple = "#bb9af7",
}

local function hud_bold(text, color)
	return ui.Span(text):fg(color):bold(false)
end

local function hud_sep()
	return ui.Span("  │  "):fg(hud.muted)
end

-- Header 右侧计数：去掉默认背景块，保留选择 / 剪切 /复制语义。
Header:children_remove(1, Header.RIGHT)
Header:children_add(function(self)
	local selected = #self._tab.selected
	local yanked = selected > 0 and 0 or #cx.yanked
	if selected > 0 then
		return ui.Line({ hud_sep(), hud_bold(selected .. " selected", hud.cyan), " " })
	elseif yanked <= 0 then
		return ""
	end

	local icon = cx.yanked.is_cut and " " or " "
	local label = cx.yanked.is_cut and " cut" or " yanked"
	local color = cx.yanked.is_cut and hud.red or hud.green
	return ui.Line({ hud_sep(), hud_bold(icon .. yanked .. label, color), " " })
end, 1000, Header.RIGHT)

-- Footer：替换默认 mode/size/name 与 perm/percent/position 胶囊组件。
for _, id in ipairs({ 1, 2, 3 }) do
	Status:children_remove(id, Status.LEFT)
end
for _, id in ipairs({ 4, 5, 6 }) do
	Status:children_remove(id, Status.RIGHT)
end

Status:children_add(function(self)
	local mode = tostring(self._tab.mode):sub(1, 3):upper()
	local mode_color = self._tab.mode.is_select and hud.purple
		or (self._tab.mode.is_unset and hud.red or hud.cyan)
	local parts = { hud_bold(mode, mode_color) }
	local h = self._current.hovered
	if h then
		parts[#parts + 1] = hud_sep()
		parts[#parts + 1] = ui.Span(ya.readable_size(h.cha.len)):fg(hud.yellow)
		parts[#parts + 1] = hud_sep()
		parts[#parts + 1] = ui.Span(ui.printable(h.name)):fg(hud.fg)
	end
	return ui.Line(parts)
end, 1000, Status.LEFT)

Status:children_add(function(self)
	local h = self._current.hovered
	if not h then
		return ""
	end

	local parts = {}
	if ya.target_family() == "unix" then
		local user = ya.user_name(h.cha.uid) or tostring(h.cha.uid)
		local group = ya.group_name(h.cha.gid) or tostring(h.cha.gid)
		parts[#parts + 1] = ui.Span(user .. ":" .. group):fg(hud.purple)
	end

	if h.cha:perm() then
		if #parts > 0 then
			parts[#parts + 1] = hud_sep()
		end
		parts[#parts + 1] = self:perm()
	end

	local total = #self._current.files
	local position = total > 0 and self._current.cursor + 1 or 0
	local percent = total > 0 and math.floor(position * 100 / total + 0.5) or 0
	if #parts > 0 then
		parts[#parts + 1] = hud_sep()
	end
	parts[#parts + 1] = hud_bold(percent .. "%", hud.cyan)
	parts[#parts + 1] = ui.Span(string.format(" · %d/%d ", position, total)):fg(hud.blue)
	return ui.Line(parts)
end, 1000, Status.RIGHT)

local function fingerprints_from_env(name)
	local value = os.getenv(name)
	assert(value and value:match("%S"), name .. " must be set")

	local fingerprints = {}
	for fingerprint in value:gmatch("[^,%s]+") do
		fingerprints[#fingerprints + 1] = fingerprint
	end
	return fingerprints
end

require("gpg"):setup({
	recipients = fingerprints_from_env("YAZI_GPG_RECIPIENTS"),
	signers = fingerprints_from_env("YAZI_GPG_SIGNERS"),
})

require("yamb"):setup({
	cli = "fzf",
})
