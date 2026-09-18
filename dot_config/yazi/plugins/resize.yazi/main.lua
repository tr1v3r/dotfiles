--- @since 26.8.15
--- @sync entry
--
-- 预览窗宽度实时调整（zoom.yazi 管图片本身的缩放，本插件管预览窗占屏比例）：
--   plugin resize 1      预览窗加宽一档
--   plugin resize -1     预览窗变窄一档
--   plugin resize reset  还原 yazi.toml [mgr] ratio
--
-- 两个坑：
--   1) entry 的 st 参数在多次按键间不持久，持久状态必须走 ya.sync 的插件状态表；
--   2) 26.x 里 rt.mgr.ratio 是数组，.parent/.current/.preview 已废弃。
-- Tab.layout 补丁手法来自 yazi-rs/plugins toggle-pane.yazi，reset 不还原函数、
-- 只把三段比值写回配置值，幂等无泄漏。

local state = ya.sync(function(st)
	return st
end)

local function entry(_, job)
	job = type(job) == "string" and { args = { job } } or job
	local st = state()
	local R = rt.mgr.ratio

	st.parent = st.parent or R[1]
	st.current = st.current or R[2]
	st.preview = st.preview or R[3]

	if job.args[1] == "reset" then
		st.parent, st.current, st.preview = R[1], R[2], R[3]
	else
		st.preview = math.max(1, st.preview + (tonumber(job.args[1]) or 1))
	end

	Tab.layout = function(self)
		local all = st.parent + st.current + st.preview
		self._chunks = ui.Layout()
			:direction(ui.Layout.HORIZONTAL)
			:constraints({
				ui.Constraint.Ratio(st.parent, all),
				ui.Constraint.Ratio(st.current, all),
				ui.Constraint.Ratio(st.preview, all),
			})
			:split(self._area)
	end

	ya.emit("app:resize", {})
end

return { entry = entry }
