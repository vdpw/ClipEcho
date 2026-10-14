# 开发指南

所有命令均从仓库根目录执行。要求 macOS 14+、Swift 6.4.1 及与编译器匹配的
macOS SDK；Apple Command Line Tools 即可，无需完整 Xcode。主程序没有第三方
Swift package 依赖，也不需要 Node.js、pnpm 或 Rust。SQLite 及 AppKit、Foundation、
CryptoKit、ImageIO、ServiceManagement、WebKit 由系统提供。

## 工具链

`scripts/toolchain.sh` 默认选择
`~/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain`，仅为项目进程设置
配套 Swift 编译器，不覆盖全局 PATH、clang 或 `TOOLCHAINS`。其他安装位置：

```sh
CLIPECHO_SWIFT_TOOLCHAIN=/absolute/path/to/swift-6.4.1-RELEASE.xctoolchain \
  ./scripts/test.sh
```

`CLIPECHO_SWIFT_EXEC` 与 `CLIPECHO_SWIFTC_EXEC` 可分别指定 Swift 和 Swift 编译器
入口；二者必须来自同一匹配工具链。测试脚本自动查找工具链内的 Swift Testing
宏，必要时可用 `CLIPECHO_TESTING_MACROS` 指定已有的宏库。
SwiftPM、编译器模块及包缓存全部放在 `.build/`，由 `.gitignore` 排除。

## 构建与运行

```sh
./scripts/build-app.sh debug
open "build/ClipEcho.app"
```

`./scripts/run.sh` 会先构建 debug 包再打开应用，后续参数转交给应用：

```sh
./scripts/run.sh --hidden
```

Release 构建使用 `./scripts/build-app.sh release`。应用包名为 `ClipEcho.app`，
bundle identifier 保留 `com.copy-stack.desktop.native`。构建脚本使用 ad-hoc 签名。
本地 release 默认省略 dSYM；需要调试符号时使用
`CLIPECHO_DEBUG_SYMBOLS=1 ./scripts/build-app.sh release`。

源码目录、依赖方向和并发边界见[架构](architecture.md)。修改设置、编码或存储时
保留 v4 schema、CSB1、原有设置键、内容标识与置顶规则；当前数据库未知版本或
不安全路径应拒绝打开，不能用新建空数据库代替已有历史。

## 验证

```sh
./scripts/test.sh
./scripts/build-app.sh release
./scripts/self-test.sh
codesign --verify --deep --strict "build/ClipEcho.app"
```

Swift Testing 使用合成临时数据库验证纯核心、存储和 actor 行为；`--self-test`
使用真实 AppKit/WebKit API、临时数据库和独立命名剪贴板验证系统集成，不替换
系统主剪贴板。`scripts/self-test.sh` 调用已构建应用的 `--self-test`，同时检查
进程退出状态与最终 `Native self-test passed:` 标记，避免提前退出被误判为通过。
更改采集、恢复、窗口、菜单或设置交互后也需可见界面验收。

现有数据库兼容性检查使用只读入口：

```sh
"build/ClipEcho.app/Contents/MacOS/ClipEcho" --verify-database
"build/ClipEcho.app/Contents/MacOS/ClipEcho" \
  --verify-database --database /absolute/path/clipecho.db
```

默认数据库为 `$HOME/.clipecho/clipecho.db`，应用沿用 `storage.json` 与
`storage-move.json` 查找自定义位置并恢复迁移。只读检查不改写历史或设置；SQLite
仍遵守锁和 WAL 协议，可维护读取所需的协调侧文件。常规 `--read-only` 启动禁用
采集和数据库修改；`--hidden` 隐藏初始窗口。

## 人工 QA

按[QA 指南](../QA/README.md)创建合成夹具，并使用
`--qa --database /absolute/fixture/native/clipecho.db` 或独立 `ClipEcho QA.app`。
界面截图和辅助功能树只能来自该夹具；不要采集生产历史或剪贴板正文。

关注卡片内联展开、搜索焦点、分页/滚动锚点、固定/删除确认、恢复排序、设置、
三种语言及主题、窗口大小、关闭/重新打开和菜单悬停。实际登录启动、另一设备的
Universal Clipboard、支持架构及不同来源应用格式需在目标环境分别验证。
单元测试、自检或菜单辅助功能树不能代替可见悬停面板和状态栏弹出位置检查。

[validation.md](validation.md)保存按日期区分的历史结果。记录新结果时说明环境、
分支、夹具和实际完成的检查；保留未执行或未通过的项目。
