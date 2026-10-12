# AeroSpace：隐藏 workspace 的窗口露到邻屏

状态：通过调整系统显示器排列绕过，未修改 AeroSpace 的藏窗实现。

本记录仅保留相对屏幕位置、窗口状态和操作步骤；不保存设备型号、
应用名称、窗口 ID、个人路径或原始截图。

## 现象

三屏设置：左侧竖屏，中间横屏为主要操作屏，右侧为内建屏。
初始排列中，左侧竖屏向下延伸超过中间屏；右侧内建屏与中间屏
顶边大致对齐，底边略低于中间屏。

从 workspace 2 切到 workspace 1 后，本应隐藏的普通应用窗口
在右侧内建屏的下沿露出一部分。捕获的查询结果显示，该窗口仍在
workspace 2、仍为平铺状态，而 workspace 2 不可见。

预期是未显示 workspace 的窗口不干扰当前画面；露出可辨认的窗口
内容不应解释为正常的平铺落位或切换动画。

## 官方机制

AeroSpace 的 workspace 不是 macOS 原生 Space。它通过把未显示
workspace 的窗口挪到屏幕左下角或右下角之外来模拟隐藏，而不是
切换到另一个原生 Space，也不是把窗口最小化。

```text
【切换 workspace】
workspace 2 不再可见
  └─ AeroSpace 将其窗口挪到屏幕底角之外
       ├─ 藏窗区域在所有屏幕之外 → 窗口基本不可见
       └─ 藏窗区域与邻屏重叠     → 邻屏下沿露出窗口的一部分
```

官方要求每块显示器至少有一个下角具备足够的屏外空间，否则隐藏
窗口可能在另一块显示器上露出。macOS 不允许窗口完全移出可见区域，
官方说明正常隐藏也可能留下约 1 像素的竖线；这与在邻屏露出一截
窗口内容不同。

上游 `MacWindow.hideInCorner` 使用显示器的 `visibleRect` 底角，
不是完整屏幕 `rect` 的底角。因此不能仅凭排列缩略图中的完整底边
判断藏窗区域是否已经避开邻屏。系统保留区（例如 Dock）可能影响
可用区域，但本次未测量实际坐标，不能将所需偏移量全部归因于 Dock。

## 实测绕过方法

1. 打开 **系统设置 → 显示器 → 排列**。
2. 保留左右顺序，将右侧内建屏的矩形向上移动，让它的底边明显
   高于中间屏底边，为中间屏右下角留出屏外空间。
3. 确认排列，再在 workspace 1 与 workspace 2 之间切换验证。

实测仅轻微上移仍会露出一点；继续上移、留下更大的底边错位后，
用户观察到不再露出窗口。该调整没有修改 AeroSpace 配置或窗口的
floating/tiling 状态。

代价：系统显示器的逻辑排列与实际摆放可能不再完全一致，鼠标跨屏
时的上下对齐位置会改变。

## 结论与边界

- 症状、官方说明和排列调整的效果共同支持“屏外藏窗区域与邻屏
  重叠”的判断，而不是 workspace 自动搬家或窗口变成悬浮。
- 已验证的是这组排列下的绕过效果，不是 AeroSpace 藏窗实现的修复。
- 没有建立通用的最小上移量；不要承诺“底边只错开 1 像素就够”。
- 固定 workspace 到显示器不会改变屏外藏窗机制，不应当作已验证
  的修复方法；本次也未通过调整平铺 gaps 处理此问题。
- 不据此解释原生全屏、焦点跳回其他应用或其他鼠标行为，它们需要
  独立取证。

## 参考

- [官方指南：模拟虚拟 workspace](https://nikitabobko.github.io/AeroSpace/guide#emulation-of-virtual-workspaces)
- [官方指南：显示器排列限制与示意图](https://nikitabobko.github.io/AeroSpace/guide#proper-monitor-arrangement)
- [上游藏窗实现：MacWindow.hideInCorner](https://github.com/nikitabobko/AeroSpace/blob/master/Sources/AppBundle/tree/MacWindow.swift)
- [上游底角选择与布局刷新：layoutWorkspaces](https://github.com/nikitabobko/AeroSpace/blob/master/Sources/AppBundle/layout/refresh.swift)
