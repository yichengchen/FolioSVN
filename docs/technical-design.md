# 技术方案

## 1. 方案概述

首版采用面向 macOS 26+ 的 AppKit 原生应用，使用 Swift 6 语言模式。通过 `NSWindowController`/`NSViewController` 组织窗口和页面，使用 Swift Concurrency 管理异步任务，通过受控的 SVN 命令执行层访问远端仓库。业务层不向界面暴露命令行语义，所有命令结果转换为稳定的领域模型和用户错误。

产品以远程仓库浏览为主，不维护一个长期、完整的用户可见 Working Copy。涉及新增、替换、移动、删除等复杂写操作时，在应用管理的临时工作区中执行 checkout/update/commit，完成后清理或复用受控工作区。

> 直接对 URL 操作适合 `list`、`info`、`log`、`cat`、`export`、`mkdir`、`delete`、`move` 等场景；上传和替换通常需要临时 working copy。最终可用能力必须以项目选定的 SVN CLI 版本进行集成测试。

## 2. 技术选型

| 层级 | 建议技术 | 说明 |
| --- | --- | --- |
| 系统基线 | macOS 26+、Swift 6、Xcode 26+ | 不维护旧 macOS 兼容路径，启用严格并发检查 |
| UI | AppKit + SnapKit 6 | `NSSplitViewController`、`NSOutlineView`、`NSTableView`、`NSToolbar`；SnapKit 统一代码布局约束 |
| 页面组织 | Window Controller + View Controller + Coordinator | Window Controller 管窗口生命周期，Coordinator 管导航和弹窗，View Controller 处理展示与用户事件 |
| 状态管理 | 显式 View Model + Swift Concurrency actor | `@MainActor` View Model 生成界面状态，actor 隔离 SVN 任务与缓存写入；不引入响应式框架 |
| SVN 访问 | `/usr/bin/env svn` 或应用随附并签名的 SVN 二进制 | 启动时探测版本；生产发布需明确依赖策略 |
| 结构化输出 | SVN XML 输出 + XMLCoder | `list`、`info`、`log` 优先使用 `--xml`，通过 Codable DTO 解码，避免手写通用 XML 解析器 |
| 本地元数据 | SQLite + GRDB.swift | 收藏、目录缓存、搜索索引、任务记录和 schema migration |
| 凭据 | macOS Keychain + KeychainAccess | 使用轻量包装减少 Security.framework 样板代码；不进入 SQLite、UserDefaults 或日志 |
| HTTP 网络 | Alamofire | 仅用于未来应用后端、配置、反馈或诊断上传；SVN 通信仍由 SVN Gateway 完成 |
| 日志 | CocoaLumberjack | `DDOSLogger` 写统一日志，`DDFileLogger` 保存受控滚动文件，支持用户导出诊断包 |
| 文件打开 | `NSWorkspace` | 使用系统默认应用打开下载缓存 |

自动更新当前不在范围内，因此不引入 Sparkle。完整依赖边界见[开源库选型](./open-source-libraries.md)。

### 2.1 SVN 依赖策略

macOS 环境不应假设所有用户都已安装同一版本的 SVN CLI。发布前需要在以下方案中选定一种：

1. 应用随附 SVN 二进制及依赖库：体验一致，但需处理许可证、签名、公证、架构与安全更新。
2. 首次运行检测外部 SVN：实现简单，但企业部署和版本兼容不可控。
3. 使用原生 SVN 库封装：控制力强，但桥接、维护和发布成本最高。

Debug 阶段允许使用外部 CLI；生产版随附经过签名的固定版本。应用首先解析 Resources 下的 `SVNRuntime/bin/svn`，Debug 才回退到显式覆盖、PATH、Homebrew 或系统位置，不能依赖用户 shell 初始化脚本。Release 构建会拒绝缺少内置运行时或仍引用 Homebrew 绝对 dylib 路径的产物。

## 3. 总体架构

```text
┌─────────────────────────────────────────────────────────────┐
│                         AppKit UI                           │
│ NSWindowController · Coordinator · NSViewController        │
│ Sidebar · Browser · Search · History · Transfers · Settings│
└──────────────────────────────┬──────────────────────────────┘
                               │ intents / view state
┌──────────────────────────────▼──────────────────────────────┐
│                       Application Layer                    │
│ RepositoryBrowser · FileActions · Search · History · Tasks │
└──────────────┬──────────────────┬──────────────────┬────────┘
               │                  │                  │
┌──────────────▼──────┐ ┌─────────▼────────┐ ┌──────▼─────────┐
│ SVN Client Gateway │ │ Metadata Store   │ │ CredentialStore │
│ query/write/export │ │ SQLite + index   │ │ macOS Keychain  │
└──────────────┬──────┘ └──────────────────┘ └────────────────┘
               │ Process arguments + XML
┌──────────────▼──────────────────────────────────────────────┐
│  SVN CLI / Managed Temporary Working Copies / SVN Server   │
└─────────────────────────────────────────────────────────────┘
```

## 4. 模块设计

### 4.0 AppKit 界面层

主窗口使用 `NSSplitViewController`：左侧 `NSOutlineView` 展示收藏和仓库目录树，右侧 `NSTableView` 展示当前目录内容，顶部由 `NSToolbar` 承担导航、搜索、刷新、上传和新建操作。视图全部使用代码构建，约束统一通过 SnapKit 声明；不混用 Storyboard/XIB 约束和 SnapKit 管理同一视图层级。

职责划分：

- `MainWindowController`：恢复窗口状态、管理 toolbar、处理窗口关闭和进行中任务提示。
- `MainCoordinator`：页面导航、sheet、设置/历史/任务窗口创建，不持有仓库业务逻辑。
- `SidebarViewController`：目录展开、状态恢复和收藏，只向 View Model 发送用户意图。
- `BrowserViewController`：表格、排序、选择、右键菜单、拖放和键盘操作。
- `BrowserViewModel`：运行在 `@MainActor`，将 Repository Browser 的结果转换为稳定的行模型和 loading/empty/error 状态。
- `InspectorViewController`：文件信息和历史，可作为右侧检查器或独立窗口复用。

列表更新优先使用 macOS 26 的系统差量数据源/快照 API。界面层不直接调用 `Process`、GRDB、Alamofire 或 KeychainAccess，也不保存仓库状态的最终真相。

### 4.1 Repository Browser

职责：

- 列出目录直接子项。
- 获取节点信息。
- 维护面包屑和目录树展开状态。
- 合并缓存结果与刷新状态。

接口示例：

```swift
protocol RepositoryBrowsing {
    func list(_ location: RepositoryLocation,
              revision: RevisionSpecifier) async throws -> [RepositoryEntry]
    func info(_ location: RepositoryLocation) async throws -> RepositoryEntryInfo
}
```

`RepositoryLocation` 应由仓库标识和相对路径组成，禁止业务层随意拼接 URL 字符串。

### 4.2 SVN Client Gateway

职责：

- 构造参数数组并启动子进程。
- 注入非交互参数、认证上下文和环境变量。
- 流式读取 stdout/stderr，支持取消和超时。
- 解析 XML/退出码，映射为领域结果或错误。
- 对日志中的凭据和敏感 URL 脱敏。

超时边界：连接测试、单层目录读取、`info`/`proplist` 和写操作创建浅工作区的首次 checkout 采用 10 秒命令等待上限。超时后先取消 Swift 任务并向子进程发送终止信号，1 秒后仍未退出则强制结束。`export`、上传和提交不使用 10 秒总时长，因为文件体积和服务端提交耗时无法用连接超时衡量；它们由传输任务状态和用户可用的取消边界管理。

建议抽象：

```swift
protocol SVNClient {
    func list(url: URL, depth: SVNDepth) async throws -> [SVNListEntry]
    func info(url: URL) async throws -> SVNInfo
    func log(url: URL, limit: Int?) async throws -> [SVNLogEntry]
    func export(url: URL, revision: SVNRevision?, to localURL: URL) async throws
    func makeDirectory(url: URL, message: String) async throws -> Int
    func move(from: URL, to: URL, message: String) async throws -> Int
    func delete(url: URL, message: String) async throws -> Int
    func commit(_ plan: WorkingCopyCommitPlan) async throws -> Int
}
```

### 4.3 Managed Working Copy

上传和替换建议使用短生命周期工作区，避免把用户整个仓库 checkout 到本地。

工作区策略：

- 每个写任务在应用缓存目录中创建唯一目录。
- 仅 checkout 目标父目录，使用适当 depth 降低数据量；操作前确认所需文件已取回。
- 使用基准 revision 或更新检查保证乐观并发。
- 文件复制采用临时名称，完成后原子移动到目标工作路径。
- 成功提交返回 revision 后清理；失败时仅在确有诊断价值且不含敏感文档的情况下短暂保留，并由清理策略删除。
- 应用启动时清理过期、不完整的工作区。

不建议为每次上传直接 checkout 大目录全部内容。若服务端/客户端版本对浅工作副本操作有约束，应在技术 Spike 中验证并按仓库规模调整。

### 4.4 Transfer Manager

职责：

- 调度上传、下载、导出和索引任务。
- 限制并发数，避免压垮 SVN 服务端。
- 发布进度、支持取消和失败重试。
- 应用窗口关闭后继续执行，应用退出前明确提示进行中的写任务。

当前实现由浏览器 View Model 保存最近 20 条会话内任务摘要，状态栏菜单展示任务类型、文件或数量、大小/目标位置、运行结果和失败原因。普通下载和 Finder 拖出下载共用同一任务模型与取消入口。上传、替换进入 SVN 写操作后不提供取消按钮，避免 commit 已落库但客户端误报取消；后续将任务阶段拆分后，可只允许在 commit 前取消。

状态机：

```text
queued → preparing → running → verifying → succeeded
   │          │          │          │
   └──────────┴──────────┴──────────┴→ failed
                         └────────────→ cancelled
```

写任务一旦进入服务端 commit 阶段，不应向用户承诺能安全取消；取消请求需等待命令结果并重新查询仓库确认最终状态。

### 4.5 Metadata Store

本地数据库保存：

- 仓库非敏感配置。
- 收藏。
- 目录条目缓存。
- 搜索索引。
- 任务摘要和缓存清理信息。

数据库不保存：密码、令牌、完整文档正文、服务端 ACL 副本。

### 4.6 Search Indexer

V1.5 的文件名搜索可由 `svn list -R --xml` 或分目录遍历建立索引。大型仓库建议：

- 首次索引按配置的搜索根目录执行。
- 将最后索引 revision 作为游标；通过日志/变更列表增量更新。
- 索引任务限速、可暂停、可取消。
- 搜索结果标记索引时间，点击后以实时 `info` 校验目标仍存在。

不应在应用启动路径上同步构建全仓索引。

## 5. 领域模型

```swift
struct RepositoryProfile: Identifiable, Codable {
    let id: UUID
    var displayName: String
    var baseURL: URL
    var startPath: RepositoryPath
    var credentialKey: String
}

struct RepositoryEntry: Identifiable, Codable {
    let id: EntryIdentity
    let repositoryID: UUID
    let path: RepositoryPath
    let kind: EntryKind
    let size: Int64?
    let lastChangedRevision: Int
    let lastChangedAt: Date?
    let lastChangedBy: String?
}

enum EntryKind: String, Codable {
    case file
    case directory
}

struct HistoryItem: Identifiable {
    let id: Int              // revision
    let author: String?
    let date: Date?
    let message: String?
    let changedPaths: [ChangedPath]
}
```

`EntryIdentity` 不应只用路径：重命名会导致路径变化。收藏可保存仓库 ID、当前路径、最后已知 revision 和可选节点线索；当路径失效时，可尝试通过历史定位，找不到则标记失效。

## 6. 用户操作与 SVN 映射

以下命令是语义示例。实现必须使用 `Process.executableURL` 与参数数组，不能把示例拼接成 shell 字符串。

| 用户操作 | SVN 语义/示例 | 备注 |
| --- | --- | --- |
| 浏览目录 | `svn list URL --xml` | 只列直接子项；按需请求 |
| 查看信息 | `svn info URL --xml` | 获取 kind、revision、作者、时间等 |
| 下载文件 | `svn export URL LOCAL --force` | 历史版本增加 `-r REV` |
| 打开文件 | export 到缓存后 `NSWorkspace.open` | 缓存键包含仓库、路径和 revision |
| 新建文件夹 | `svn mkdir URL -m MESSAGE` | 可直接 URL commit |
| 重命名/移动 | `svn move OLD_URL NEW_URL -m MESSAGE` | 保留 copy history |
| 删除 | `svn delete URL -m MESSAGE` | 删除仍存在于历史 |
| 查看历史 | `svn log URL --xml` | 按页/数量加载 |
| 搜索索引 | `svn list -R URL --xml` | 大仓库在后台运行 |
| 上传新文件 | 临时 checkout → copy → `svn add` → `svn commit` | 提交前校验父目录状态 |
| 替换文件 | 临时 checkout 目标 → 覆盖 → `svn commit` | 目标路径不变，检查远端更新 |
| 恢复历史版本 | 取历史内容覆盖当前工作文件 → commit | 创建新的 revision，不删除中间历史 |

### 6.1 上传事务

```text
读取父目录当前状态
        ↓
创建受控临时工作区
        ↓
checkout/update 目标父目录
        ↓
复制文件并 svn add
        ↓
再次检查并提交
        ↓
解析 committed revision
        ↓
刷新目录缓存并清理工作区
```

### 6.2 替换并发控制

1. 用户发起替换时读取目标 `lastChangedRevision`。
2. checkout/更新受控工作区中的目标文件。
3. 如果取回的 revision 与用户确认时不同，中止并提示远端变化。
4. 覆盖工作文件并 commit。
5. commit 返回 out-of-date 时映射为 `remoteChanged`，不得自动 update 后重试覆盖。

### 6.3 恢复语义

恢复 r100 的内容时，当前仓库假设为 r150。实现读取目标在 r100 的内容，将其覆盖到基于最新版本建立的工作文件，然后提交为 r151。这样 r101—r150 的历史仍可查，r151 清楚记录恢复动作。

## 7. 命令执行安全

### 7.1 禁止 shell 拼接

正确方式：

```swift
let process = Process()
process.executableURL = svnExecutableURL
process.arguments = ["list", repositoryURL.absoluteString, "--xml", "--non-interactive"]
```

不要构造 `"svn list \(url)"` 再交给 `/bin/zsh -c`。仓库路径和文件名可能包含空格、引号或其他特殊字符。

### 7.2 凭据

- Keychain 条目使用仓库 ID 与用户标识定位。
- 密码由 KeychainAccess 写入 macOS Keychain，GRDB 只保存非敏感服务器配置；默认关闭 iCloud Keychain 同步。
- 调用 SVN CLI 时使用 `--password-from-stdin` 从标准输入传递密码，并附加 `--no-auth-cache`；密码不进入进程参数、SQLite、UserDefaults 或日志。
- 用户名作为单独的 `Process.arguments` 项传递，不经 shell 拼接。

### 7.3 证书信任

- 默认执行严格证书校验。
- 不全局使用忽略证书错误参数；证书策略跟随仓库 UUID 保存。
- “允许自签名或未知 CA”只为 HTTPS 命令追加 `--trust-server-cert-failures=unknown-ca`。
- “允许全部证书错误”还会接受主机名不匹配、过期、尚未生效和其他校验失败，UI 必须展示高风险警告。
- 对 `http://`、`svn://`、`svn+ssh://` 和 `file://` 不追加 HTTPS 信任参数。
- 后续版本可增加证书详情和指纹固定；首版不会修改系统钥匙串中的根证书信任。

## 8. 缓存策略

### 8.1 目录缓存

缓存键建议为：

```text
repositoryID + normalizedPath + requestedRevision/depth
```

- 已有缓存时直接展示；由用户点击刷新按钮时强制读取服务端并替换当前目录缓存。
- 写操作成功后，使父目录、目标路径和受影响的收藏记录失效。
- 缓存必须记录获取时间和对应 revision。

### 8.2 打开文件缓存

缓存键：`repositoryID + path + lastChangedRevision`。不同 revision 使用不同文件，避免用户打开的旧版本被后台覆盖。

清理策略：

- 按总大小上限和最近使用时间淘汰。
- 正被外部应用打开的文件尽量延迟清理。
- 用户可在设置中查看占用并清空缓存。

## 9. 错误模型

```swift
enum RepositoryError: Error {
    case authenticationRequired
    case authenticationFailed
    case certificateUntrusted(CertificateSummary)
    case permissionDenied(operation: RepositoryOperation)
    case notFound(RepositoryPath)
    case alreadyExists(RepositoryPath)
    case remoteChanged(expected: Int?, actual: Int?)
    case networkUnavailable
    case diskFull
    case cancelled
    case clientUnavailable
    case incompatibleClientVersion(String)
    case malformedResponse
    case unknown(exitCode: Int, diagnosticID: UUID)
}
```

映射规则同时参考退出码、XML/结构化结果和 stderr 特征。不要将英文 stderr 直接作为主错误信息；保留脱敏后的技术详情和诊断 ID。

## 10. 性能与扩展性

- `svn list` 默认只读取一层，不在主导航中使用递归模式。
- 对目录请求去重；用户快速切换目录时取消已无消费者的请求。
- 元数据按批次写入 SQLite。
- 下载/上传使用文件流，UI 进度更新节流到合理频率。
- 默认并发建议：交互式读取 4、传输 2、写提交 1；后续按实测调整。
- 同一仓库的写操作串行化，避免临时工作区和用户认知中的顺序混乱。

## 11. 可观测性

采用 CocoaLumberjack 的原因不是替代 macOS Console，而是同时获得系统日志和可控的本地滚动文件：

- `DDOSLogger` 将开发和现场日志接入 macOS unified logging。
- `DDFileLogger` 保存有限数量、有限大小/时长的诊断日志，用户可主动导出给支持人员。
- 应用内部通过 `AppLogger` 协议包装 CocoaLumberjack，业务代码不直接依赖 `DDLog` 全局 API。
- Release 默认记录 `info` 及以上级别；临时 debug 模式需要用户显式开启并自动过期。
- 文件日志建议最多保留 7 天且设置总容量上限，导出前再次执行脱敏过滤。

禁止记录密码、令牌、完整仓库 URL、文件正文、本地绝对路径和 SVN 带认证参数的命令行。仓库路径默认散列或只保留末级名称；需要完整路径排障时必须由用户显式选择生成诊断包。

日志分类：

- `connection`：连接与认证结果，不记录凭据。
- `command`：命令类型、耗时、退出码和诊断 ID，路径脱敏。
- `browser`：目录请求、缓存命中率。
- `transfer`：字节数、耗时、取消和失败原因。
- `database`：迁移与索引任务。
- `http`：Alamofire 请求类型、耗时、状态码和重试次数；不记录请求/响应正文或认证 header。

建议指标：目录 P50/P95 加载时间、命令失败率、认证失败率、缓存命中率、上传/下载吞吐、并发冲突次数。

## 12. 测试方案

### 12.1 单元测试

- URL 和 RepositoryPath 的规范化与编码。
- SVN XML 的 list/info/log 解析。
- stderr/退出码到领域错误的映射。
- 提交说明生成和名称校验。
- 收藏、侧边栏状态及缓存失效规则。
- 任务状态机与取消竞态。

### 12.2 集成测试

通过容器或专用测试服务启动 SVN 仓库，覆盖：

- HTTPS、`svn://` 及项目决定支持的其他协议。
- 中文、空格、`#`、`%`、Unicode 组合字符路径。
- 新建、上传、替换、重命名、删除、历史和恢复。
- 无权限、错误凭据、过期/自签名证书。
- 两个工作区的 out-of-date 并发冲突。
- 大文件和大量直接子项目录。

### 12.3 UI 测试

- 目录导航、面包屑、排序和右键菜单。
- 上传冲突转入替换确认。
- 删除非空目录的确认文案。
- 离线缓存标识和重试。
- 键盘导航、VoiceOver 标签、深浅色模式。

### 12.4 故障注入

- 传输中断网。
- commit 前后取消。
- 磁盘空间耗尽。
- SVN 进程异常退出或返回不可解析输出。
- 应用异常退出后重启，验证临时工作区清理和服务端最终状态核对。

## 13. 交付阶段建议

### Phase 0：技术验证

- 固定 macOS 26、Xcode 26、Swift 6 基线，并确定 SVN CLI 版本。
- 验证各种协议、凭据、证书和中文路径。
- 验证浅工作副本完成上传、替换与并发检查。
- 确定 SVN 二进制发布方式和许可证义务。

### Phase 1：只读浏览

- 仓库配置、Keychain、目录浏览、信息查看、下载并打开。
- 建立 XML 解析、错误映射、缓存与任务框架。

### Phase 2：基础写操作

- 上传、替换、新建文件夹、重命名、删除。
- 引入 Managed Working Copy 与写任务串行化。
- 完成并发冲突与失败恢复测试。

### Phase 3：效率能力

- 收藏、目录缓存、侧边栏状态恢复、文件名索引和搜索。

### Phase 4：历史与企业增强

- 历史下载、恢复、权限体验和操作记录。

## 14. 关键风险与对策

| 风险 | 影响 | 对策 |
| --- | --- | --- |
| macOS 未预装或 SVN 版本不一致 | 应用无法运行或行为不同 | 固定支持矩阵；生产版评估随附签名二进制 |
| 大仓库递归操作耗时 | UI 卡顿、服务端压力 | 按需加载、后台索引、限流和取消 |
| 凭据出现在参数/日志 | 安全泄漏 | Keychain、受控认证机制、参数与日志审计 |
| 用户覆盖他人更新 | 数据冲突 | 基准 revision、提交前检查、禁止自动覆盖重试 |
| 临时工作区遗留敏感文件 | 本地数据泄漏 | 受限权限、生命周期清理、容量/时间上限 |
| 权限不可提前完整判断 | 操作按钮状态不准确 | 预测仅优化体验，以服务端结果为准 |
| 重命名后收藏失效 | 用户入口丢失 | 写操作同步更新；外部变更时尝试历史定位或标失效 |
| SVN 文本输出随语言变化 | 解析不稳定 | 查询命令优先 XML；错误映射按版本做集成测试 |

## 15. 待决策项

- 正式产品名和视觉品牌。
- Intel Mac 支持范围；系统基线已固定为 macOS 26。
- SVN 二进制采用随附、外部依赖还是库封装。
- 首发支持的协议与企业认证方式。
- 单次多文件上传采用原子单提交还是逐文件任务（本文建议一次选择对应一次提交）。
- 搜索范围由管理员配置还是用户自选。
- 本地缓存默认上限和企业集中策略。
