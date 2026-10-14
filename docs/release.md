# 发布指南

Swift/AppKit 工作流位于仓库根目录的 `.github/workflows/`，不再使用 Node、pnpm、
Rust 或 Tauri 打包流程。应用产物为 `build/ClipEcho.app`，bundle identifier 沿用
`com.copy-stack.desktop.native`，继续识别 Swift 版本的登录项。

## Pull Request 验证

`ci.yml` 在 `pull_request` 和 `workflow_dispatch` 时运行。相同引用的新运行会取消
尚未完成的旧运行，两个架构各自执行：

| 架构 | GitHub runner | 验证 |
| --- | --- | --- |
| Apple Silicon / arm64 | `macos-15` | Swift Testing、Release 构建、原生自检、严格签名及架构检查 |
| Intel / x86_64 | `macos-15-intel` | Swift Testing、Release 构建、原生自检、严格签名及架构检查 |

工作流安装固定 Swift 6.4.1 官方工具链，校验安装包身份及编译器版本，再使用
项目脚本选择编译器及本地缓存。PR CI 的结果只证明对应构建和自动验证完成；
实际发布由标签工作流处理。

原生自检保留 600×400 至 1000×900 的真实窗口断言。部分 Apple Silicon runner
只有 1024×681 的可视区域，AppKit 会缩小初始窗口。因此 CI 与发布在自检前执行
`scripts/prepare-ci-display.sh`：仅在 GitHub Actions 的 macOS 虚拟机中选择足够大的
公开 CoreGraphics 显示模式，维持当前登录会话；必要时使用已安装的 Anka 工具。
准备失败会让工作流失败，不跳过或放宽窗口断言。本地运行该脚本会拒绝执行，
正常应用和本地自检不会修改用户显示配置。

## 标签发布

`release.yml` 在推送 `v*` 标签时启动。版本使用 `vX.Y.Z`；预发布可带
`-alpha`、`-beta` 或 `-rc` 后缀，例如 `v0.5.0-beta.1`。
打包时将数值版本写入 `CFBundleShortVersionString` 与 `CFBundleVersion`，该例为
`0.5.0`；产物名称去掉标签开头的 `v`，保留预发布后缀。

两个架构分别运行测试、构建、自检和签名/架构验证，再生成 ZIP、DMG 和 SHA-256
校验文件。全部构建成功后集中创建一次 GitHub Release 并上传两个架构的产物。
示例文件名：

- Apple Silicon：`ClipEcho-0.5.0-beta.1-macos-arm64.zip`、`.dmg`、`.sha256`。
- Intel：`ClipEcho-0.5.0-beta.1-macos-x86_64.zip`、`.dmg`、`.sha256`。

按电脑架构选择对应文件。ZIP 保留完整 `.app`，DMG 提供应用与 Applications
入口。同一标签重试发布时，已有 Release 会复用并覆盖同名产物。
不要将单个架构完成或工作流启动视为整体发布已完成。

本地手动打包已构建的应用：

```sh
./scripts/build-app.sh release
./scripts/package-release.sh v0.5.0-beta.1 arm64
```

第二个参数必须匹配已构建的二进制架构；Intel 使用 `x86_64`。
产物写入 `build/release/`，打包会更新本地应用包的版本字段并重新签名。
当前构建和发布使用 ad-hoc 签名，不含 Developer ID 签名或 Apple 公证。制作
Developer ID 分发版本时需要单独配置签名身份、公证凭据与对应发布步骤。

## 发布前验证

```sh
./scripts/test.sh
./scripts/build-app.sh release
./scripts/self-test.sh
codesign --verify --deep --strict "build/ClipEcho.app"
```

对现有数据仅使用 `--verify-database` 的只读检查。可见界面验收使用
[合成 QA 夹具](../QA/README.md)，检查菜单栏、搜索焦点、窗口关闭/重开、主题、
语言、恢复和设置流程；实际登录启动、Universal Clipboard、菜单悬停面板及
Apple Silicon/Intel 目标电脑仍需人工验证。

发布结果以 GitHub Actions 完成状态和 Release 页面中的全部产物为准。
[历史验证记录](validation.md)保留此前环境的结果，不替代当前版本的发布验收。
