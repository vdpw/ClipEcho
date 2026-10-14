# 历史页兼容核对

参考来源固定于 Rust 版本提交 `f051c0cb286b9af984f0d392eaeee51a99e1fd5c`：

- [macOS 样式](https://github.com/vdpw/ClipEcho-rust/blob/f051c0cb286b9af984f0d392eaeee51a99e1fd5c/src/macos.css)与[应用样式](https://github.com/vdpw/ClipEcho-rust/blob/f051c0cb286b9af984f0d392eaeee51a99e1fd5c/src/App.css)。
- [HistoryView、EventCard、PreviewMedia](https://github.com/vdpw/ClipEcho-rust/tree/f051c0cb286b9af984f0d392eaeee51a99e1fd5c/src/features/history)与[历史状态](https://github.com/vdpw/ClipEcho-rust/blob/f051c0cb286b9af984f0d392eaeee51a99e1fd5c/src/hooks/useClipboardHistory.ts)。
- [显示规则](https://github.com/vdpw/ClipEcho-rust/blob/f051c0cb286b9af984f0d392eaeee51a99e1fd5c/src/lib/display.ts)、[HTML 预览](https://github.com/vdpw/ClipEcho-rust/blob/f051c0cb286b9af984f0d392eaeee51a99e1fd5c/src/lib/htmlPreview.ts)及[语言目录](https://github.com/vdpw/ClipEcho-rust/blob/f051c0cb286b9af984f0d392eaeee51a99e1fd5c/src/i18n.ts)。

- [设置样式](https://github.com/vdpw/ClipEcho-rust/blob/f051c0cb286b9af984f0d392eaeee51a99e1fd5c/src/features/settings/settings.css)与[Rust 原生菜单](https://github.com/vdpw/ClipEcho-rust/blob/f051c0cb286b9af984f0d392eaeee51a99e1fd5c/src-tauri/src/tray.rs)。

以下清单及后续描述保留原生开发时的核对结果，不代表根目录迁移时重新执行了
全部界面验收。现时操作见 [QA 指南](../QA/README.md)；桌面验收必须使用
`QA/create-fixture.py` 生成的独立数据库及命名剪贴板，禁止截取真实历史。

- [x] 卡片流、固定/最近分组、数量徽章、底部分页；无表格行和独立详情窗口。
- [x] 40px 拖拽区；600px 窗口时内容左右 20px，窄窗口 14px；搜索高度 42px。
- [x] 卡片圆角 12px、内距 12/13px、间距 7px；固定卡左边 3px 强调色。
- [x] 原版 Lucide 图标、三个 30px 操作按钮、徽章/正文/时间字号和原文标签。
- [x] 默认文本按 40 个显示列折叠，文件名称保留“更多项目”后缀；展开显示全部文件。
- [x] 点击卡片、回车/空格展开；按钮独立操作；HTML/文本/视频交互不折叠卡片。
- [x] 搜索 180ms 防抖、最大 256 字、清空按钮、Command+F、Escape 清空后移出焦点。
- [x] 每页 50 项、提前 320px 自动加载；刷新保留已加载深度和卡片滚动锚点。
- [x] 固定成功 320ms 回顶；取消固定/删除保留锚点；失焦更新回顶。
- [x] 复制成功唯一绿色反馈 1400ms，卡片边框 900ms 动画；不需要排序时保留位置。
- [x] 复制后处理失败仍显示已复制，保留不可重试错误提示。
- [x] 详情按需查询/后台解码；12 项缓存、32 个片段、8 MiB 内容预算、4 MiB 图片限制。
- [x] 原版 HTML 过滤器和 CSS；简单预览 104px、复杂预览 280px，独立 WebKit 安全上下文。
- [x] 禁止 HTML 外部资源/跳转/内容脚本；弱消息代理；提供实际 DOM 诊断 API。
- [x] HTML 就绪前保持加载行，确定 104/280px 后一次展示；刷新和分页复用未变化卡片及 WebKit。
- [x] HTML 规则/导航/进程/超时失败显示详情不可用；重试丢弃失败视图，重新渲染。
- [x] 设置返回开始新会话；旧分页、搜索、详情请求取消并检查请求世代。
- [x] 文字控件去除系统水平内距，避免精确宽度标题/徽章裁掉末字。

桌面验收清单（与原版使用相同夹具、窗口尺寸、语言和主题）：

- [x] 初始 600×700、标题/徽章末字完整、卡片密度接近原版（最低尺寸由窗口自检验证）。
- [ ] 文本、中文/表情折叠、文件/文件夹、多媒体、HTML 简单/复杂预览的几何布局。
- [ ] 卡片点击/键盘展开、详情正文点击、HTML 滚动边界、搜索清空/焦点。
- [ ] 连续搜索/分页/切换设置时没有过期数据或额外详情请求。
- [ ] 固定回顶、取消固定/删除锚点、固定删除确认取消/确认和焦点。
- [ ] 连续恢复仅上一项取消反馈；保持排序/移到顶部两种设置及首项优化。
- [ ] 英文、简体中文、繁体中文；浅色、深色及系统主题。
- [x] 可见 HTML 正文、原版字体、标题分隔线、列表和 280px 高度均正确；危险节点/属性/CSP由实际WK自检验证。

桌面验收结果按日期记录于 [validation.md](validation.md)；编译通过不替代可见验收。

2026-10-13 已使用 `clipecho-ui-qa-0cf5d85109e34b49904a8500bb208aba`
的 Original QA / Native QA 窗口比对，数据库初始/当前均为 75 条合成记录。
已实际验证 Command+F、180ms 查询、Escape 清空、四行代码展开、Space/Return
折叠与展开、HTML正文点击保持展开、96×64 PNG固有尺寸及圆角、50→75分页。
固定删除仅打开/取消：初始取消焦点、Return取消、Escape恢复搜索焦点均通过；
没有确认删除，也没有恢复生产剪贴板。第三轮 QA 包已实测 Tab→删除、
Shift+Tab→取消、Return 取消，以及搜索栏描边、快捷键徽章、失焦后图标恢复、
滚动时玻璃模糊。全部通过后将 GUI 明确交给设置页验收。

追加文件展开检查发现长路径第二行裁剪：路径绘制行高与高度测量不一致。
源码已统一为原 CSS 的 16.704px，搜索摘录也统一绘制/测量行高；独立 Swift
6.4.1 编译通过。最终 QA 包已用 `txt` 搜索并展开文件/文件夹记录：两个长路径
第二行完整显示，名称、文件图标和时间均没有裁剪。
HTML 滚动边界仅通过 AX scroll 做过观察，未确认真实滚轮事件传播；不将其记为通过。
后续已在合成数据库检查一次恢复至命名剪贴板的绿色反馈、固定/取消固定及分组变化，
并确认恢复后保留 75 条记录、两条固定记录。设置页三种语言、主题和帮助/数字控件
的检查见 `validation.md`；删除确认及连续恢复的完整动态矩阵尚未全部执行。

从设置页通过菜单搜索或 Command+F 返回历史时，原先的 `viewDidAppear` 会覆盖
搜索框焦点。已保留正在编辑的搜索框，并在视图尚未附着窗口时保留一次性焦点请求。
最终 QA 包实测直接输入 `Short` / `txt` 生效，无需额外点击搜索框；AppKit 自检也
检查了生命周期回调后的实际 field editor。
