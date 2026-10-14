# ClipEcho Native

独立的 **Swift 6.4.1 + AppKit** macOS 剪贴板管理器。原来的 React/Tauri/Rust
代码保留在父目录，原生版本的源码、资源、测试和构建脚本全部位于本目录。

## 构建与运行

要求 macOS 14 或更高、Swift 6.4 稳定工具链及 macOS SDK。可以使用 Apple
Command Line Tools，无需完整 Xcode。没有第三方包依赖；AppKit、Foundation、
CryptoKit、ImageIO、ServiceManagement、WebKit 和 SQLite 由系统提供。测试使用工具链
自带的 Swift Testing。

本机使用 Swift.org 官方签名的 6.4.1 稳定工具链，安装在
`~/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain`。终端通过
`~/.local/share/swift-stable/bin` 中的独立入口启动 Swift 命令，不将整个工具链
加入全局 PATH，也不全局设置 `TOOLCHAINS`，因此 Go CGO 继续使用系统 C 编译器。
项目脚本单独选择 Swift 工具链及其 Testing 宏。默认选择上述 6.4.1 路径；其他
电脑可通过 `CLIPECHO_SWIFT_TOOLCHAIN=/absolute/toolchain/path` 指定工具链，或
使用 `CLIPECHO_SWIFT_EXEC` / `CLIPECHO_SWIFTC_EXEC` 指定配套的编译器入口。

```sh
cd native-macos
./scripts/test.sh
./scripts/build-app.sh release
open "build/ClipEcho Native.app"
```

开发运行：`./scripts/run.sh`。应用打包为 `build/ClipEcho Native.app`，使用独立
bundle identifier `com.copy-stack.desktop.native`；关闭窗口会隐藏 Dock 图标，
采集及菜单栏继续运行，重新打开应用会激活同一个窗口。`Command+,` 打开设置，
`Command+F` 搜索，`Command+Q` 退出。

## 现有数据兼容

默认直接打开 `$HOME/.clipecho/clipecho.db`，不另建一份历史数据。原生版本也识别
同一目录的 `storage.json` 及 `storage-move.json`，因此能继续使用已有的自定义
存储位置及迁移恢复记录。`COPY_STACK_QA_DATA_DIR` 可覆盖测试启动目录。

当前 v4 数据库的历史、置顶、搜索索引和设置均可继续使用。二进制 `CSB1` 事件格式、
SHA-256 内容标识及原有设置键保持兼容，新版本写入的记录也能由原版本读取。
v3 可安全添加置顶字段；更早或更新的未知数据库格式会保留并拒绝打开，需先使用
原版本完成迁移。常规使用时选择一个版本运行，避免两个版本同时监控剪贴板。

不修改历史的兼容检查：

```sh
"build/ClipEcho Native.app/Contents/MacOS/ClipEcho" --verify-database
```

可用 `--database /absolute/path/clipecho.db` 指定独立数据库，`--read-only` 禁用采集
及数据库修改，`--hidden` 隐藏启动窗口。只读连接遵守 SQLite 的锁及 WAL 协议，
不会改写历史和设置；SQLite 仍可维护读取所需的协调侧文件。

存储位置调整使用 SQLite 在线备份、完整性检查和原有恢复记录协议，保留历史、
置顶、设置和搜索，并拒绝覆盖目标数据库。该流程独立于原版本的 VACUUM 实现。

## 已实现的功能

- 文本、RTF、HTML、PNG、文件及文件夹等内容采集，多项目原样恢复。
- 原版卡片界面、点击/回车/空格内联展开、50 条分页、自动加载、搜索、固定及删除。
- 按需内联预览、原版 HTML 过滤与排版、图片缩略图和文件路径。
- 原版菜单栏分组和文本悬停；窗口聚焦时采集更新保留锚点，失焦时滚回顶部。
- 保留数量、历史容量、单次采集上限、文本精简模式和恢复排序。
- 系统/浅色/深色主题，英文、简体中文、繁体中文及系统语言。
- 登录启动、存储位置调整、同一用户单实例及关闭窗口后继续运行。
- 原有可选 JSONL 开发镜像，独立读取连接、合并刷新及私有原子写入。

HTML 预览使用系统 WebKit 的非持久隔离视图和原版过滤器，保留原版预览排版，
禁止外部资源、导航和用户脚本。原始 HTML 和其他剪贴板格式仍保留用于恢复。
固定记录不受常规清空和保留策略删除；设置页仅提供清空未固定，删除固定项目
需要原版样式的确认浮层。

代码按领域、应用服务、存储/系统适配器和界面重新组织；外观及操作以原版产品为
兼容契约。窗口为 600×700、隐藏标题栏；设置保留四类侧栏、主题卡片及锚点帮助，
恢复反馈、固定操作和滚动规则与原版一致。

JSONL 镜像只在显式传入原有开发参数时启用，例如：

```sh
./scripts/run.sh --copy-stack-history-jsonl /absolute/private/folder/history.jsonl \
  --copy-stack-history-jsonl-max-data-bytes 4096
```

## 验证

```sh
./scripts/test.sh
./scripts/build-app.sh release
"build/ClipEcho Native.app/Contents/MacOS/ClipEcho" --self-test
"build/ClipEcho Native.app/Contents/MacOS/ClipEcho" --verify-database
```

`--self-test` 使用真实 AppKit API，但只写独立命名的剪贴板和临时数据库；涵盖采集、
恢复、过滤、置顶保护、设置导航、窗口尺寸、关闭/重开、Dock 策略，以及实际 WebKit
HTML 过滤、CSP、字体与高度。测试不会替换系统主
剪贴板。构建产物、数据库和缓存由本目录 `.gitignore` 排除。

界面核对时使用 `--qa --database /absolute/fixture/clipecho.db`，该模式使用独立
命名剪贴板和独立实例锁，可与原版并行运行。不要把真实剪贴板历史用于截图或
辅助功能树采集。`--qa` 必须显式指定独立数据库。

发布前仍需在目标电脑人工验证登录启动、另一设备的 Universal Clipboard、
多种应用的复制格式及所支持架构。本地开发包使用临时签名；公开分发
需要 Developer ID 签名和公证。

架构、职责及并发设计见 [docs/architecture.md](docs/architecture.md)。
本次验证结果见 [docs/validation.md](docs/validation.md)。
