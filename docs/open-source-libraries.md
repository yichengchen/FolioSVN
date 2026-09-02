# 开源库选型

## 1. 结论

项目采用 AppKit，首版建议的运行时依赖如下：

| 库 | 状态 | 用途 |
| --- | --- | --- |
| [SnapKit](https://github.com/SnapKit/SnapKit) | 引入 | AppKit 代码布局 DSL |
| [GRDB.swift](https://github.com/groue/GRDB.swift) | 引入 | SQLite、migration、并发访问和文件名搜索索引 |
| [XMLCoder](https://github.com/CoreOffice/XMLCoder) | 引入 | 将 `svn --xml` 输出解码为 Codable DTO |
| [KeychainAccess](https://github.com/kishikawakatsumi/KeychainAccess) | 引入 | Keychain 的 Swift 包装 |
| [CocoaLumberjack](https://github.com/CocoaLumberjack/CocoaLumberjack) | 日志模块启用时引入 | 系统日志、滚动文件日志和诊断包导出 |
| [Alamofire](https://github.com/Alamofire/Alamofire) | 按需启用 | 应用后端、远程配置、反馈或诊断上传等 HTTP 请求 |
| [ZIPFoundation](https://github.com/weichsel/ZIPFoundation) | 功能触发后引入 | 文件夹打包下载或诊断包压缩 |

自动更新暂不开发，因此不引入 Sparkle。选型复核日期为 2026-08-23。

SVN CLI 不是 Swift Package 依赖。正式分发采用 Resources 内置的可重定位运行时，并同时分发 Apache Subversion 及其 APR/APR-util、Serf、OpenSSL 等实际链接依赖对应的许可证与 notices。Debug 可使用本机安装版本，但不得把带 Homebrew 绝对 dylib 路径的二进制直接打包进 App。

### 1.1 工具链基线

项目固定使用 macOS 26+、Xcode 26+、Swift 6 语言模式和严格并发检查：

- 使用 SnapKit 6，不维护 SnapKit 5.x 或旧 macOS 的兼容路径。
- Alamofire 选择支持 Swift 6 的当前 5.x 稳定版本。
- GRDB 使用当前 7.x 稳定版本。
- CocoaLumberjack、XMLCoder 和 KeychainAccess 均以 macOS 26/Swift 6 构建通过为准。

`Package.resolved` 锁定一组经过 CI 验证的确切版本；升级大版本时单独评审。

## 2. 依赖使用边界

### 2.1 SnapKit

使用 SnapKit 管理代码创建的 AppKit 视图约束，避免大量 `NSLayoutConstraint.activate` 样板代码。

约定：

- UI 全部采用 AppKit；SnapKit 只是 Auto Layout DSL，不承担组件、状态或导航。
- 同一个视图层级不混用 Storyboard/XIB 生成约束和 SnapKit 约束。
- 可复用 View 在内部创建自身约束，View Controller 只定义它与容器的约束。
- 动画前使用 `updateConstraints`/`remakeConstraints`，随后调用 AppKit 的 layout 流程。
- 最低 macOS/Xcode/Swift 版本必须满足所选 SnapKit 大版本要求；升级大版本时重新检查其 platform requirements。

### 2.2 GRDB.swift

GRDB 用于：

- 数据库 schema migration。
- 仓库非敏感配置。
- 收藏。
- 目录缓存和文件名搜索索引。
- 任务摘要。

不保存密码、令牌、下载文档正文或可被误认为服务端最终状态的数据。数据库访问统一收口在 `MetadataStore` actor，View Controller 不持有数据库连接，也不直接执行 SQL。

### 2.3 XMLCoder

为 SVN 的三类 XML 输出建立明确 DTO：

```text
SVNListDocument
SVNInfoDocument
SVNLogDocument
```

XMLCoder 仅负责解码，Mapper 再完成 URL、日期、revision 和 entry kind 校验。必须保存不同 SVN 版本生成的真实 XML fixture，覆盖空作者、删除路径、中文名称、属性和 namespace；不能因为用了库就省略协议兼容测试。

### 2.4 KeychainAccess

应用内部再包装一层稳定协议，业务层不依赖第三方类型：

```swift
protocol CredentialStore {
    func credential(for repositoryID: UUID) throws -> RepositoryCredential?
    func save(_ credential: RepositoryCredential, for repositoryID: UUID) throws
    func removeCredential(for repositoryID: UUID) throws
}
```

Keychain item 使用稳定 service 名和仓库 UUID，设置符合锁屏/后台行为的 accessibility。默认不启用 iCloud Keychain 同步，除非未来成为经过安全评审的明确需求。

### 2.5 CocoaLumberjack

建议引入。它相对只用 `os.Logger` 的关键增益是 `DDFileLogger`：可以控制滚动周期、文件数量和本地保留，并让用户主动导出一份确定的诊断日志。对于部署在企业现场、难以实时连接 Console 的桌面客户端，这个能力很实用。

配置建议：

```swift
DDLog.add(DDOSLogger.sharedInstance)

let fileLogger = DDFileLogger()
fileLogger.rollingFrequency = 24 * 60 * 60
fileLogger.logFileManager.maximumNumberOfLogFiles = 7
DDLog.add(fileLogger)
```

实际实现还要增加总容量限制、脱敏 formatter 和诊断包导出确认。CocoaLumberjack 默认不会自动上传数据，但日志内容由应用负责，以下内容一律禁止写入：

- 密码、令牌、Cookie 和 Authorization header。
- SVN 完整认证命令行。
- 文件正文和用户搜索内容。
- 未脱敏的完整仓库 URL、本地路径、用户名。

应用定义 `AppLogger` 协议作为唯一入口，让单元测试能替换 logger，也避免业务层充斥 CocoaLumberjack 宏。日志分类至少包括 connection、command、browser、transfer、database 和 http。

### 2.6 Alamofire

Alamofire 按实际 HTTP 需求启用，但依赖可以在项目初始化时配置好。它用于：

- 未来的应用后端 API。
- 企业远程配置。
- 用户明确同意后的反馈/诊断日志上传。
- 其他 JSON、multipart、重试、认证和服务端信任需求。

它不用于代替 SVN CLI，也不直接处理 `svn://`、Working Copy 或 SVN commit。所有请求通过单一 `HTTPClient`/`APIClient` 包装，View Controller 不直接使用 `AF.request`：

```swift
protocol HTTPClient {
    func send<Response: Decodable & Sendable>(
        _ request: APIRequest<Response>
    ) async throws -> Response
}
```

统一配置一个 `Session`，集中处理 timeout、认证 adapter、retry policy、ServerTrustManager 和日志脱敏。默认不打印 cURL，因为它可能包含凭据。

### 2.7 ZIPFoundation

当前不是核心依赖。只有确定实现以下功能时再添加：

- “将文件夹下载为 ZIP”。
- 将多份滚动日志和环境摘要打包为诊断包。
- 导入/导出离线配置包。

如果首版只是把 SVN 文件夹 export 到用户选择的目录，就无需 ZIP 库。诊断包也可以先导出为目录，等产品确认需要单文件提交时再引入。

## 3. 开发和测试依赖

| 工具/库 | 用途 | 规则 |
| --- | --- | --- |
| [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) | 自动统一 Swift 格式 | 固定版本，在 CI 执行 `--lint`，不链接 App target |
| [SwiftLint](https://github.com/realm/SwiftLint) | 检查危险或不一致写法 | 先启用少量高价值规则，不与 SwiftFormat 重复 |
| [swift-snapshot-testing](https://github.com/pointfreeco/swift-snapshot-testing) | AppKit View Controller 和各种页面状态的视觉回归 | 只加入 test target，固定 macOS、字体和窗口尺寸 |

测试仍以 XCTest 或 Swift Testing 为基础，不引入 Quick/Nimble，除非团队已有统一规范。

## 4. 不再额外引入库的能力

| 能力 | 直接使用 |
| --- | --- |
| 文件树与列表 | `NSOutlineView`、`NSTableView`、系统 diffable data source |
| 菜单、快捷键 | `NSMenu`、Responder Chain |
| 拖放 | AppKit Drag and Drop、Pasteboard |
| 文件选择 | `NSOpenPanel`、`NSSavePanel` |
| 默认应用打开 | `NSWorkspace` |
| 异步、取消、隔离 | Swift Concurrency、`Task`、actor |
| 子进程 | Foundation `Process`、Pipe/FileHandle，由项目的 SVN Gateway 安全包装 |
| 系统网络状态 | Network.framework；Alamofire 只负责其发出的 HTTP 请求 |
| 图片和文件图标 | `NSWorkspace`、`NSImage`、Quick Look |
| 依赖注入 | initializer + protocol injection |

因此不引入 RxSwift/PromiseKit、第三方列表框架、Kingfisher、Swinject 或额外路由框架。

## 5. Swift Package Manager 组织

```text
Application target
├── SnapKit
├── GRDB
├── XMLCoder
├── KeychainAccess
├── CocoaLumberjack + CocoaLumberjackSwift
└── Alamofire                       # HTTP 功能启用时

Test targets
└── SnapshotTesting

Build tools / CI
├── SwiftFormat
└── SwiftLint
```

依赖管理规则：

- 不依赖 `main`/`master` 分支，使用语义版本范围。
- `Package.resolved` 纳入版本控制，确保 CI 和开发机一致。
- 发布构建冻结确切 revision，并生成第三方依赖与许可证清单。
- 依赖升级单独提交，附 changelog、安全公告和回归测试结果。
- 每个依赖由一个项目内部协议或 adapter 隔离，避免第三方 API 扩散到业务/UI 层。

## 6. 许可证与供应链

目前建议库的主要许可证为：SnapKit、GRDB.swift、XMLCoder、KeychainAccess、Alamofire、ZIPFoundation 和 SnapshotTesting 使用 MIT；CocoaLumberjack 使用 BSD 3-Clause。正式分发前仍需以锁定版本仓库中的 LICENSE 为准，由构建流程生成 Third-Party Licenses，并进行人工复核。

每次引入或大版本升级检查：

1. 许可证与企业分发方式。
2. 最近发布和维护状态。
3. 未解决安全公告、最低系统和工具链版本。
4. SPM 中的二进制 target、build plugin、可执行文件和 Privacy Manifest。
5. 对应用签名、公证、Sandbox entitlement 的影响。

## 7. 最小落地组合

```text
当前工程固定引入：SnapKit、GRDB.swift、XMLCoder、KeychainAccess
日志模块启用时：CocoaLumberjack
有 HTTP 接口时：Alamofire
有单文件压缩包需求时：ZIPFoundation
暂不引入：Sparkle 及其他自动更新框架
测试/工具：SnapshotTesting、SwiftFormat、SwiftLint
```

这样既遵循 AppKit 的稳定能力，也把布局、数据库、XML、凭据和现场日志这些容易重复造轮子的部分交给成熟项目。
