# ClipEcho

使用 **Swift 6.4.1 + AppKit** 的原生 macOS 剪贴板管理器，支持 **macOS 14+**。
源码、资源、测试和构建脚本均位于仓库根目录；构建无需 Node.js、pnpm 或 Rust。
Rust/Tauri/React 版本已移至只读归档仓库
[ClipEcho-rust](https://github.com/vdpw/ClipEcho-rust)，保留原版源码和历史。
本仓库后续维护 Swift/AppKit 实现。

## 构建与运行

要求 macOS 14 或更高、Swift 6.4.1 工具链及配套 macOS SDK。可以使用 Apple
Command Line Tools，无需完整 Xcode。没有第三方包依赖；AppKit、Foundation、
CryptoKit、ImageIO、ServiceManagement、WebKit 和 SQLite 由系统提供。测试使用工具链
自带的 Swift Testing。

项目脚本单独选择 Swift 工具链及其 Testing 宏，默认使用
`~/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain`。
其他安装位置可通过 `CLIPECHO_SWIFT_TOOLCHAIN=/absolute/toolchain/path` 指定，
或用 `CLIPECHO_SWIFT_EXEC` / `CLIPECHO_SWIFTC_EXEC` 指定配套编译器入口。
具体设置见[开发指南](docs/development.md)。以下命令从仓库根目录执行。

```sh
./scripts/test.sh
./scripts/build-app.sh release
open "build/ClipEcho.app"
```

开发运行：`./scripts/run.sh`。应用打包为 `build/ClipEcho.app`，沿用 Swift 版本的
bundle identifier `com.copy-stack.desktop.native`；关闭窗口会隐藏 Dock 图标，
采集及菜单栏继续运行，重新打开应用会激活同一个窗口。`Command+,` 打开设置，
`Command+F` 搜索，`Command+Q` 退出。

关闭主窗口只隐藏窗口，应用继续后台采集；菜单栏图标遵循“在菜单栏中显示”设置。
关闭该设置后，关闭窗口也不会退出应用或重新显示菜单栏图标，可再次打开应用以
显示原窗口。选择“退出”或按 `Command+Q` 才会结束应用。

## 现有数据兼容

默认直接打开 `$HOME/.clipecho/clipecho.db`，不另建一份历史数据。原生版本也识别
同一目录的 `storage.json` 及 `storage-move.json`，因此能继续使用已有的自定义
存储位置及迁移恢复记录。`COPY_STACK_QA_DATA_DIR` 可覆盖测试启动目录。

当前 v4 数据库的历史、置顶、搜索索引和设置均可继续使用。二进制 `CSB1` 事件格式、
SHA-256 内容标识及原有设置键保持兼容，新版本写入的记录也能由原版本读取。
v3 可安全添加置顶字段；更早或更新的未知数据库格式会保留并拒绝打开，需先使用
Rust 版本完成迁移。常规使用时选择一个版本运行，避免两个版本同时监控剪贴板。

不修改历史的兼容检查：

```sh
"build/ClipEcho.app/Contents/MacOS/ClipEcho" --verify-database
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
兼容契约。初始窗口为 600×700，可在 600×400 至 1000×900 内调整，隐藏标题栏；
设置保留四类侧栏、主题卡片及锚点帮助，
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
./scripts/self-test.sh
"build/ClipEcho.app/Contents/MacOS/ClipEcho" --verify-database
codesign --verify --deep --strict "build/ClipEcho.app"
```

`scripts/self-test.sh` 调用已构建应用的 `--self-test`，检查退出状态及最终完成标记。
自检使用真实 AppKit API，但只写独立命名的剪贴板和临时数据库；涵盖采集、
恢复、过滤、置顶保护、设置导航、窗口尺寸、关闭/重开、Dock 策略，以及实际 WebKit
HTML 过滤、CSP、字体与高度。测试不会替换系统主剪贴板。构建产物、数据库和
缓存由 `.gitignore` 排除。

界面核对时使用 `--qa --database /absolute/fixture/clipecho.db`，该模式使用独立
命名剪贴板和独立实例锁。截图和辅助功能树只能使用合成夹具，具体步骤见
[QA 指南](QA/README.md)。`--qa` 必须显式指定独立数据库。

发布前仍需在目标电脑人工验证登录启动、另一设备的 Universal Clipboard、
多种应用的复制格式及所支持架构。本地及当前 GitHub 发布包使用 ad-hoc 签名，
不含 Developer ID 签名或 Apple 公证。

## GitHub Actions 与发布

CI 在 pull request 和手动触发时，分别验证 Apple Silicon（arm64）和 Intel
（x86_64）：Swift Testing、Release 构建、AppKit/WebKit 自检、严格签名及架构检查。
推送 `vX.Y.Z` 或 `vX.Y.Z-beta.1` 等标签时，发布工作流生成两个架构的 ZIP 与
DMG，全部构建成功后发布同一 GitHub Release。

产物选择、版本号规则及发布前验证见[发布指南](docs/release.md)。
完整文档见[文档索引](docs/index.md)。[历史验证记录](docs/validation.md)保留
原生版本开发期间的结果与尚待人工复核的项目，不代表每次目录或工作流变更均
重新完成了全部桌面验收。
