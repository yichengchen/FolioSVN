# Folio SVN

面向企业文档管理场景的 macOS 26+ SVN 客户端。界面使用 AppKit，布局使用 SnapKit，工程采用 XcodeGen 保持可复现。

## 当前进度

- 已完成 V1、V1.5 与 V2 历史能力（FR-01～FR-12、FR-14～FR-17）的 AppKit 文件管理闭环；FR-13 最近访问已按产品决策移出范围。
- 已完成服务器新增、测试、编辑、移除、默认起始路径，以及 GRDB/Keychain 持久化。
- 已完成懒加载目录树、面包屑、前进后退、刷新、排序、空目录和错误状态；右侧文件列表支持文件夹原地展开/收起，双击进入仍然保留。
- 已完成下载/打开缓存、上传、revision 并发保护的替换、新建文件夹、SVN move 重命名、删除、信息与路径复制。
- 文件右键可查看最近 100 条历史，展示 revision、修改人、时间和提交说明；历史版本可以另存、直接打开，或恢复为一个新的 revision。
- 已支持文本输入的撤销、剪切、复制、粘贴、全选快捷键；文件列表支持空格 Quick Look、Return 重命名，以及 `⌘O` 打开、`⌘S` 下载、`⌘R` 刷新、`⇧⌘N` 新建文件夹。重命名文件默认只选中主文件名，保留扩展名。
- Finder 文件可拖入上传，仓库文件或文件夹可拖到 Finder 触发下载；目录右键可直接“上传到这里”或“在这里新建文件夹”。
- 文件列表支持 `⌘`/`⇧` 多选；可批量下载、删除、添加收藏或移除收藏。批量删除作为一次 SVN revision 提交，批量拖到 Finder 时按队列下载，父文件夹与其子项同时选中时不会重复下载或删除。
- 状态栏提供传输任务入口，记录最近 20 个下载、上传和替换任务的阶段、完成、失败或取消状态；下载可取消并安全重试，完成后可打开文件或在 Finder 中显示，失败原因可回看。
- 已完成本机收藏以及当前目录/配置范围的本地文件名搜索；收藏可在侧边栏右键设置独立显示名称，侧边栏会恢复展开、收起和当前选中状态。
- SVN 目录列表已写入 GRDB 缓存，重复进出目录直接使用缓存；工具栏刷新会强制读取 SVN 并更新对应目录缓存。
- 搜索索引按需创建、支持手动刷新与取消，状态栏展示索引更新时间；打开结果前会实时校验服务端状态。
- 已完成 SVN CLI 版本探测和 XMLCoder 结构化输出解析；用户名/密码、HTTPS 证书例外和中文路径均由安全参数数组处理。
- 已完成首次启动的“添加 SVN 服务器”页面、连接测试、服务器列表和快速重连。
- 已完成 GRDB 仓库配置持久化，以及 KeychainAccess 管理的本机密码存储。
- 已完成严格校验、允许未知 CA/自签名证书、允许全部证书错误三档 HTTPS 策略；策略按服务器保存。
- 已完成 Process 取消、stdout/stderr 持续读取和结构化错误处理。
- 连接测试、目录读取、文件信息和浅工作区初始化采用 10 秒等待上限；超时会终止底层 SVN 进程，大文件上传、下载不套用 10 秒总时长。
- 已内置 SVN 1.14.5 arm64 Runtime、HTTPS CA bundle 及全部非系统动态库；Debug/Release 默认使用同一份可重定位运行时，终端用户无需安装 Homebrew 或 SVN。
- 自动化验证为 50/50 通过；其中真实本地仓库测试覆盖递归索引、新建、上传、属性读取、文件/目录下载、历史查询与恢复、替换、重命名、删除和过期 revision 拒绝。
- 下一阶段：文件夹上传；之后再考虑文本差异、权限提示和操作记录体验。

## 环境

- macOS 26+
- Xcode 26+
- Swift 6
- XcodeGen 2.46+

## 生成工程

```sh
xcodegen generate
```

`SVNClient.xcodeproj` 会一并纳入版本控制，修改 `project.yml` 或新增源码后需要重新生成并提交工程文件。

## 构建与测试

```sh
xcodebuild \
  -project SVNClient.xcodeproj \
  -scheme SVNClient \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  build

xcodebuild \
  -project SVNClient.xcodeproj \
  -scheme SVNClient \
  -destination 'platform=macOS,arch=arm64' \
  CODE_SIGNING_ALLOWED=NO \
  test
```

GitHub Actions 使用 `macos-26` arm64 runner，在不安装 Homebrew、不开启代码签名的环境中验证已提交的 SVN Runtime，检查 `project.yml` 与 Xcode 工程是否同步，并完成 Debug 测试和 Release 构建。正式发布仍需在持有 Fuzhou West2online Internet Inc. Developer ID 证书的电脑上执行 Archive、签名与公证。

产品与技术文档见 [docs/README.md](./docs/README.md)。
