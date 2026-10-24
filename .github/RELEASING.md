# 本地打包与 Release

在项目根目录运行：

```bash
./scripts/release-local.py
```

脚本使用 macOS 自带的 `/usr/bin/python3`，无需安装 pip 或 Node 依赖。打包仍使用项目已有的 Swift、Xcode 与 DMG 构建脚本。

方向键移动，空格勾选，`V` 修改版本与构建号，`C` 切换 Stable / Nightly，Enter 继续，Esc 或 `q` 取消。修改版本或渠道后会保留已勾选的选项。可选项如下：

| 选项 | 默认 |
| --- | --- |
| Apple Silicon（arm64） | 勾选 |
| Intel（x86_64） | 勾选 |
| 运行 Release 测试 | 勾选 |
| 备份已有同名安装包 | 不勾选 |
| 创建 GitHub Release 并公开发布 | 不勾选 |

只查看计划、不执行测试、构建或上传：

```bash
./scripts/release-local.py --dry-run
```

## 发布渠道

仅有 Stable 和 Nightly 两种渠道，默认 Stable。

| 渠道 | Tag 示例 | GitHub 类型 |
| --- | --- | --- |
| Stable | `v0.1.1` | 正式版本 |
| Nightly | `v0.1.1-nightly.4` | Pre-release |

Nightly tag 末尾使用 `CFBundleVersion` 构建号，每次发布同一版本的 Nightly 需增加构建号。Stable 与 Nightly 的 tag 独立，不会互相覆盖。

可以在勾选界面按 `C` 切换，也可直接指定：

```bash
./scripts/release-local.py --release-channel nightly
```

两种渠道都直接公开发布 Release。GitHub 工作流在版本 tag 构建成功后发布；本地脚本在展示产物并收到完整确认文字后发布。

## 版本与产物

可直接通过命令行修改版本号和构建号：

```bash
./scripts/release-local.py --set-version 0.1.1 --set-build 4
```

也可以只修改其中一项，另一项保持原值：

```bash
./scripts/release-local.py --set-build 5
```

想按提示输入并确认保存，运行：

```bash
./scripts/release-local.py --edit-version
```

以上命令只修改 `Sources/Clipato/Resources/Version.plist`，完成后退出；不会构建或操作 Git、GitHub。添加 `--dry-run` 可预览改动而不保存。版本号须为 `major.minor.patch`，构建号须为正整数；未填写的交互项保留原值。

原字段仍为 `CFBundleShortVersionString` 和 `CFBundleVersion`。后续打包、文件名和 tag 均使用这份配置。上传前需提交全部改动，工作区必须干净。更改构建号不会改变 Stable 的 `v<版本号>` tag；新建 Stable Release 需使用尚未发布的版本号。

两种发布渠道都沿用 `adhoc` 签名，安装包尚未经过 Developer ID 签名和 Apple 公证。发布渠道与签名方式相互独立。每种已选架构在 `dist/` 下生成一个 `.dmg` 和对应 `.dmg.sha256`，例如：

```text
Clipato-0.1.0-3-arm64.dmg
Clipato-0.1.0-3-arm64.dmg.sha256
Clipato-0.1.0-3-x86_64.dmg
Clipato-0.1.0-3-x86_64.dmg.sha256
```

已有同名文件不会静默覆盖。勾选备份后，旧文件移入 `dist/archive/`；否则需先修改构建号或自行处理旧文件。

## 上传到 GitHub

只有需要上传时才要求安装并登录 GitHub CLI，请自行执行：

```bash
brew install gh
gh auth login
```

勾选“创建 GitHub Release 并公开发布”后，脚本根据所选渠道生成 tag；本地或远程已有同名 tag 时会停止。Stable 需使用新版本号，Nightly 需使用新的版本 / 构建号组合。

测试、构建成功后，脚本展示实际安装包与发布说明。只有输入与渠道和版本匹配的完整确认文字，例如 `publish v0.1.0` 或 `publish v0.1.0-nightly.3`，才会创建并推送带注释的 tag、上传选中架构的安装包及校验文件，并公开发布 Release。脚本不会推送分支。

tag 注释含有 `Clipato-Local-Build: <commit SHA>`，标明此次本地构建对应的提交。云端工作流识别该标记后会跳过 macOS 打包，只运行轻量的 Ubuntu 检查，避免重复构建。

标题明确显示 Stable 或 Nightly；只有 Nightly 标记为 Pre-release。

## 云端打包

日常推送和 PR 暂不触发工作流，也没有定时构建。推送 `v<版本号>` 或 `v<版本号>-nightly.<构建号>` tag 会触发双架构打包，并自动识别渠道。

也可在 Actions 中手动运行，选择 `channel` 为 `stable` 或 `nightly`。不填写 tag 时仅保存 Artifacts；填写现有 tag 时，所选渠道必须与 tag 一致，验证版本号 / 构建号并构建成功后直接公开发布。

云端与本地使用相同标题：`Clipato <版本号> (build <构建号>) · Stable` 或 `· Nightly`。签名与公证情况写在安装说明中。

Actions 的 Artifacts 是构建附件；只有发布 Release 的条件满足且相关任务成功时，才会公开出现 Stable 或 Nightly Release。

手动运行时，先在运行来源选择已包含最新工作流的分支，再在 `tag` 输入要打包的版本 tag；这样使用最新发布流程，源码仍严格取自所填 tag。选择旧 tag 作为运行来源会继续使用该 tag 中保存的旧工作流。已经启动的运行不受后续文件修改影响。
