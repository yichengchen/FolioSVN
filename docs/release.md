# Tag 发布

`.github/workflows/release.yaml` 在推送 `v1.0.0` 或 `v1.0.0-beta.1` 形式的 tag 时运行。只发布 arm64、macOS 26+ 版本。预发布 tag 会创建 GitHub prerelease。

流程：构建 Word diff runtime → 无签名 Debug 测试 → 导入临时签名钥匙串 → Developer ID Archive → 应用公证/staple/验证 → 创建并签名 DMG → DMG 公证/staple/验证 → GitHub Release。应用和 DMG 都带公证票据。使用 Xcode 默认 DerivedData；Archive 和临时文件在 runner 临时目录中。任一公证非 Accepted 时都不会发布。中间 ZIP 仅用于应用公证，不作为 Release 资产上传。

## 一次性配置

仓库 Settings → Environments，新建 `release`，添加以下 Environment Secrets（也可以使用同名 Repository Secrets）：

| Secret | 内容 |
| --- | --- |
| `MACOS_CERTIFICATE_BASE64` | 包含私钥的 Developer ID Application `.p12` 的 Base64 |
| `MACOS_CERTIFICATE_PASSWORD` | 导出 `.p12` 时设置的非空密码 |
| `NOTARY_APPLE_ID` | 属于开发者团队、具备公证权限的 Apple ID（邮箱） |
| `NOTARY_APP_PASSWORD` | 该 Apple ID 生成的应用程序专用密码，原样保存，无需 Base64 |

当前签名和公证 Team ID 为 `MEWHFZ92DY`，与 `project.yml` 一致。证书和 Apple ID 必须属于该团队，证书须未过期，`.p12` 中应只有一个有效的 Developer ID Application 签名身份。本流程不使用 Apple Development 证书或 App Store Connect API Key。

在钥匙串访问的“我的证书”中导出 Developer ID Application（包含对应私钥）为带密码 `.p12`。在本机编码并复制到 Secret：

```sh
base64 -i DeveloperID.p12 | pbcopy
```

将复制的内容保存到 `MACOS_CERTIFICATE_BASE64`。Base64 不是加密；由 GitHub Secrets 加密保存。不要把 `.p12`、编码后的文件或密码提交到 Git，也不要发到聊天中。

在 [Apple 账户](https://account.apple.com/) 的“登录和安全性 → 应用程序专用密码”中创建专门用于 GitHub Release 的密码，保存到 `NOTARY_APP_PASSWORD`；该功能需要开启双重认证。不能使用 Apple ID 登录密码。邮箱保存到 `NOTARY_APPLE_ID`。公证提交及失败日志下载都使用这两个 Secrets 和配置的 Team ID。此前配置的 `NOTARY_API_KEY_BASE64`、`NOTARY_KEY_ID`、`NOTARY_ISSUER_ID` 不再使用，可从 GitHub Secrets 中移除。

Environment 的 Required reviewers 可选，不设置就是全自动；如果设置，发布 job 在获得批准前不能读取 Environment Secrets。个人项目需要自己批准时不要开启 Prevent self-review。建议限制 `release` Environment 仅允许 `v*` tag，并用 tag ruleset 限制哪些用户可以创建、修改或删除发布 tag；tag 通配符本身不是访问控制。

## 发布

在要发布的提交上执行：

```sh
git tag v1.0.0
git push origin v1.0.0
```

应用版本使用 tag 的数字部分，构建号使用 GitHub run number。最终资产：`FolioSVN-v1.0.0.dmg` 和 `SHA256SUMS`，文件名不带架构后缀（应用仍为 arm64）。DMG 内含已签名、公证且 staple 的 `Folio SVN.app` 及 `/Applications` 快捷方式，用户可拖拽安装。DMG 本身也签名、公证并 staple，校验和在最终 staple 后生成。

已有 Release 不会被工作流覆盖。公证或构建失败可重跑同一 run；若该版本已经成功发布，修复代码后使用新版本 tag，不移动已有发布 tag。公证失败日志显示在 Actions 的公证步骤中；超时或认证失败不会发布未公证产物。

runner 结束前会删除临时钥匙串和证书；这些文件不上传为 artifact、不写入缓存。公证邮箱和应用程序专用密码仅通过 step 环境变量传入，不写入文件。签名、公证和发布仍需首次配置 Secrets 后在 GitHub 上端到端验证。

参考：[Apple 自定义公证流程](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)、[GitHub macOS 证书导入](https://docs.github.com/en/actions/how-tos/deploy/deploy-to-third-party-platforms/sign-xcode-applications)。
