# Working Copy 模式实现方案

## 1. 文档信息

| 项目 | 内容 |
| --- | --- |
| 产品 | Folio SVN |
| 目标平台 | macOS 26+ |
| 技术栈 | AppKit、Swift 6、Swift Concurrency、GRDB、内置 SVN Runtime |
| 文档状态 | M1 纵向闭环已落地，后续能力按本文继续迭代 |
| 首个里程碑 | Checkout、Working Copy 注册、本地变更跟踪 |

当前分支已完成 Checkout 的原子临时目录流程与取消清理、GRDB 注册表、侧边栏分组、本地树形浏览、`svn status --xml` 状态展示、前台与手动刷新、重新定位及安全移除记录。Checkout 进度当前采用不确定进度条；逐路径流式进度、性能遥测和 M2 写操作仍为后续工作。

## 2. 背景与目标

Folio SVN 当前以“远端仓库浏览”作为主要模式：目录和文件来自 SVN 服务端，打开文件时使用应用管理的本地副本，上传、替换和删除直接形成 SVN revision。这种模式适合轻量浏览和文档管理，但不适合需要长期在 Finder、Word、Xcode 或其他本地工具中持续编辑一批文件的用户。

Working Copy 模式作为独立能力加入，不替代现有仓库模式。它负责将一个仓库目录完整检出到用户选择的本地位置，并在明确的刷新时机把文件系统状态转换为用户可理解的 SVN 状态。

首个里程碑的目标：

- 用户可以从任意仓库目录创建 Working Copy。
- Checkout 是可取消、可观察、失败后可恢复的长任务。
- 应用可以记住并重新打开已注册的 Working Copy。
- Finder、Word、Xcode 等外部程序修改文件后，用户回到 Folio SVN 时自动更新状态。
- 用户可以随时手动刷新本地目录和 SVN 状态。
- SVN 状态以 `svn status --xml` 为最终事实来源。
- Working Copy 模式与远端仓库模式在导航、状态和写操作上保持隔离。

首个里程碑明确不包含：

- 提交、更新、解决冲突等远端写操作。
- 自动识别 Finder 中完成的重命名。
- SVN externals、sparse checkout 和 changelist 的完整管理界面。
- 实时文件系统监听、后台常驻或应用退出后继续跟踪。
- Working Copy 自动同步。

## 3. 产品模式边界

主窗口保留两种并列模式：

```text
Folio SVN
├── 仓库
│   ├── 我的收藏
│   └── 已配置服务器
└── 工作副本
    ├── 项目资料
    └── 合同模板
```

| 能力 | 仓库模式 | Working Copy 模式 |
| --- | --- | --- |
| 内容来源 | SVN 服务端和目录缓存 | 本地文件系统 |
| 文件打开 | 应用管理的编辑副本 | 直接打开本地文件 |
| 变更发现 | 服务端刷新 | 打开、回到前台或手动触发 `svn status` |
| 离线浏览 | 仅缓存目录信息 | 支持完整本地内容 |
| 长期编辑 | 不适合 | 适合 |
| 本地状态 | 不暴露 | 修改、新增、删除、冲突等 |
| 提交模型 | 单次文件操作直接提交 | 后续支持选择多个变更统一提交 |

两个模式不能共用 `BrowserViewModel` 中的远端目录状态。可复用 AppKit 单元格、文件图标、格式化器、错误展示和传输任务 UI，但需要独立的 View Model 和领域服务。

## 4. 核心设计原则

1. **SVN 是状态真相**：本地文件时间和界面缓存不直接决定 SVN 状态，统一解析 `svn status --xml`。
2. **本地浏览不依赖网络**：显示文件、展开目录和本地 status 不访问服务器。
3. **远端命令显式触发**：Checkout、Update、Commit 等操作必须由用户主动发起。
4. **同一 Working Copy 串行写入**：禁止同一目录同时执行 Checkout、Update、Commit、Revert 或 Cleanup。
5. **长任务可取消**：Checkout 和后续 Update 必须允许终止子进程并清理中间状态。
6. **在边界时机重新校准**：不把上次保存的文件状态当成事实；应用启动、打开 Working Copy、回到前台或 SVN 操作结束后执行完整 status。
7. **先保证正确，再做实时优化**：M1 不实现文件监听；大 Working Copy 性能和实时状态需求经过验证后再引入局部扫描或 FSEvents。

## 5. 总体架构

```text
┌──────────────────────────────────────────────────────────────┐
│                       AppKit UI                              │
│ WorkingCopySidebar · WorkingCopyBrowser · Checkout Sheet    │
└─────────────────────────────┬────────────────────────────────┘
                              │ intents / view state
┌─────────────────────────────▼────────────────────────────────┐
│                  Working Copy Application Layer             │
│ Registry · CheckoutService · StatusService · OperationQueue │
└───────────────┬───────────────────────┬──────────────────────┘
                │                       │
┌───────────────▼────────────┐  ┌───────▼──────────────────────┐
│ StatusRefreshCoordinator   │  │ SVN Client Gateway          │
│ lifecycle + manual refresh │  │ checkout/info/status XML    │
└───────────────┬────────────┘  └───────────────┬──────────────┘
                │                               │
┌───────────────▼───────────────────────────────▼──────────────┐
│ Local Filesystem · .svn Metadata · Bundled SVN Runtime      │
└──────────────────────────────────────────────────────────────┘
```

建议新增模块：

```text
Sources/SVNClient/
├── Domain/WorkingCopy/
│   ├── WorkingCopy.swift
│   ├── WorkingCopyEntry.swift
│   └── WorkingCopyStatus.swift
├── Application/WorkingCopy/
│   ├── WorkingCopyRegistry.swift
│   ├── WorkingCopyCheckoutService.swift
│   ├── WorkingCopyStatusService.swift
│   ├── WorkingCopyStatusRefreshCoordinator.swift
│   └── WorkingCopyOperationCoordinator.swift
├── Infrastructure/WorkingCopy/
│   └── WorkingCopyStore.swift
└── Presentation/WorkingCopy/
    ├── WorkingCopyViewModel.swift
    ├── WorkingCopyViewController.swift
    └── CheckoutViewController.swift
```

## 6. 领域模型

### 6.1 Working Copy 记录

```swift
struct WorkingCopy: Identifiable, Equatable, Sendable {
    enum Availability: Equatable, Sendable {
        case available
        case missing
        case invalidWorkingCopy
        case inaccessible
    }

    let id: UUID
    let profileID: UUID
    let repositoryURL: URL
    let localURL: URL
    let displayName: String
    let createdAt: Date
    let lastOpenedAt: Date
    let lastKnownRevision: Int?
    let availability: Availability
}
```

`profileID` 用于复用服务器地址、用户名、密码和 HTTPS 证书策略。Working Copy 记录不保存密码，也不从 `.svn` 中提取和持久化认证信息。

### 6.2 本地条目与状态

```swift
enum WorkingCopyItemStatus: String, Codable, Sendable {
    case normal
    case modified
    case added
    case unversioned
    case deleted
    case missing
    case replaced
    case conflicted
    case obstructed
    case ignored
    case external
    case incomplete
}

struct WorkingCopyEntry: Identifiable, Sendable {
    let id: URL
    let localURL: URL
    let relativePath: String
    let kind: EntryKind
    let status: WorkingCopyItemStatus
    let isVersioned: Bool
    let revision: Int?
    let changedAt: Date?
}
```

状态映射以 `svn status --xml` 的 `wc-status item` 为准。未知的新状态不能静默映射成 normal，应保留为 `.unknown(rawValue)` 或产生可诊断错误，避免新版 SVN 状态被误认为无修改。

## 7. 持久化设计

在现有 GRDB 数据库增加 `workingCopies` 表：

| 字段 | 类型 | 说明 |
| --- | --- | --- |
| `id` | TEXT PRIMARY KEY | UUID |
| `profileID` | TEXT NOT NULL | 关联服务器配置 |
| `repositoryURL` | TEXT NOT NULL | Checkout 来源 URL |
| `localPath` | TEXT NOT NULL UNIQUE | 标准化后的本地路径 |
| `displayName` | TEXT NOT NULL | 侧边栏名称 |
| `createdAt` | DATETIME NOT NULL | 创建时间 |
| `lastOpenedAt` | DATETIME NOT NULL | 最近打开时间 |
| `lastKnownRevision` | INTEGER NULL | 最近确认 revision |

约束：

- 本地路径使用 `standardizedFileURL.resolvingSymlinksInPath()` 后的路径作为唯一键。
- 首版不允许注册相互嵌套的 Working Copy，避免状态和操作归属不清。
- 删除注册记录默认不删除本地文件；真正删除目录必须单独确认。
- 用户移动目录后，记录显示“位置不可用”，提供“重新定位”和“移除记录”。
- 如果未来启用 App Sandbox，`localPath` 需要升级为 security-scoped bookmark；当前非沙盒版本先保留模型扩展点。

不持久化逐文件状态。每次启动和重新定位后都由 `svn status` 重建。

## 8. Checkout 设计

### 8.1 用户流程

入口：

- 远端仓库目录右键“检出为工作副本”。
- 工具栏或“文件”菜单中的“新建工作副本”。

Checkout Sheet 字段：

- 仓库位置，只读展示当前仓库路径。
- 本地目标目录，通过 `NSOpenPanel` 选择父目录。
- Working Copy 名称，默认使用仓库目录名。
- “检出后在工作副本中打开”选项，默认开启。

首版固定使用完整深度并忽略 externals，不在界面暴露高级参数。

### 8.2 预检

1. 使用现有 profile 的认证和证书策略执行 `svn info --xml URL`。
2. `svn info` 保持 10 秒连接超时。
3. 确认目标父目录存在、可写。
4. 确认最终目录不存在；若存在，仅允许用户选择一个确认为空的目录。
5. 确认目标不位于另一个已注册 Working Copy 内，也不包含已注册 Working Copy。
6. 检查同路径是否已有正在执行的任务。

磁盘剩余空间只能作为提示，不能根据仓库元数据可靠预测 checkout 体积。

### 8.3 临时目录与原子落地

在最终目录的同级创建临时目录：

```text
.<name>.folio-checkout-<UUID>
```

执行：

```bash
svn checkout <URL> <TEMP_PATH> \
  --depth infinity \
  --ignore-externals \
  --non-interactive
```

成功后：

1. 再次确认最终路径没有被其他程序创建。
2. 将临时目录原子重命名为最终目录。
3. 执行 `svn info --xml FINAL_PATH` 验证 Working Copy。
4. 保存注册记录。
5. 执行首次完整 status 并打开 Working Copy。

失败或取消后删除临时目录，不留下看似可用但实际不完整的 Working Copy。临时目录放在同级可保证最终移动发生在同一文件系统内。

### 8.4 超时和取消

- 10 秒超时只用于 Checkout 前的连接预检，不能作为整个 checkout 的总超时。
- Checkout 运行期间保留取消按钮。
- 取消时向 SVN 子进程发送 `SIGTERM`，1 秒后仍未退出则发送 `SIGKILL`。
- 子进程结束后清理临时目录，再把任务标记为已取消。
- 应用退出时如果仍在 Checkout，提示用户等待或终止并清理。

### 8.5 进度展示

现有命令执行器在进程退出后一次性读取输出，不足以支持 Checkout 进度。应增加流式输出能力：

```swift
protocol StreamingSVNCommandRunning: Sendable {
    func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]?,
        standardInput: Data?,
        onOutputLine: @escaping @Sendable (SVNOutputLine) -> Void
    ) async throws -> SVNProcessOutput
}
```

Checkout 没有稳定的 XML 进度格式，因此 V1 将其视为不确定进度，只从标准输出提取当前处理路径用于辅助展示，不依据文本输出决定业务结果：

```text
正在检出“项目资料”…
当前：合同/2026/采购合同.docx
```

业务成功仍只由退出码和最终 `svn info --xml` 决定。日志继续使用固定英文 locale，并对凭据和敏感路径脱敏。

## 9. SVN Gateway 扩展

建议在现有 `SVNClient` 协议中增加明确的 Working Copy API，不让界面拼接命令参数：

```swift
protocol SVNWorkingCopyClient: Sendable {
    func checkout(
        repositoryURL: URL,
        destinationURL: URL,
        options: SVNRequestOptions,
        progress: @escaping @Sendable (SVNCheckoutProgress) -> Void
    ) async throws -> SVNWorkingCopyInfo

    func workingCopyInfo(
        at localURL: URL,
        options: SVNRequestOptions
    ) async throws -> SVNWorkingCopyInfo

    func workingCopyStatus(
        at localURL: URL,
        includeIgnored: Bool
    ) async throws -> [SVNWorkingCopyStatusEntry]
}
```

本地 status 默认执行：

```bash
svn status <LOCAL_PATH> \
  --xml \
  --ignore-externals \
  --non-interactive
```

该命令不访问网络，不需要密码，也不应使用 10 秒网络超时。远端是否有更新是后续独立能力，通过 `svn status --show-updates --xml` 或 Update 流程实现，不能混入每次本地文件变化检查。

## 10. M1 状态刷新策略

### 10.1 刷新触发时机

M1 不实现文件系统监听。以下边界事件统一请求完整刷新：

- 应用启动后首次打开一个已注册 Working Copy。
- 用户切换到另一个 Working Copy。
- `applicationDidBecomeActive`：用户从 Finder、Word、Xcode 等应用返回 Folio SVN。
- 用户点击“刷新状态”或使用对应键盘快捷键。
- Checkout、重新定位以及后续 SVN 写操作完成。
- 后续执行 Commit、Update 等远端写操作之前。

回到前台时先保留当前文件列表和上一次内存状态，后台重新读取本地目录并执行完整 `svn status --xml`，成功后差量更新界面。刷新失败不能把旧状态清空或误显示为“干净”。

M1 接受一个明确限制：如果 Folio SVN 一直处于前台，而后台进程修改了 Working Copy，界面不会实时变化。用户可以手动刷新；未来所有 Commit 和 Update 在执行前仍必须强制重新校准，因此该限制不影响写操作正确性。

### 10.2 状态刷新协调器

```swift
actor WorkingCopyStatusRefreshCoordinator {
    enum Reason: Sendable {
        case opened
        case applicationBecameActive
        case manual
        case svnOperationCompleted
        case beforeRemoteWrite
    }

    func requestRefresh(for workingCopyID: UUID, reason: Reason) async
}
```

调度规则：

1. 同一 Working Copy 同时只运行一个 status。
2. status 运行期间再次收到请求时设置 `needsAnotherRefresh`，完成后最多补跑一次。
3. 前台激活产生的重复请求可以使用约 1 秒的最小间隔合并；手动刷新和写操作前刷新不得被节流跳过。
4. 只有当前 Working Copy、当前 session generation 的结果可以更新 View Model。
5. 切换 Working Copy 时取消尚未开始的刷新；已经运行的子进程可以取消或允许结束，但其结果不得覆盖新选择。
6. 每次刷新同时核验根目录、`.svn` 元数据和 `svn info` 所指向的仓库身份。

AppDelegate 已有 `applicationDidBecomeActive` 生命周期入口，应由 `MainCoordinator` 将事件传给当前 Working Copy 的刷新协调器，而不是让 View Controller 直接观察全局通知。

### 10.3 未来实时监听扩展

只有在用户确实需要前台实时状态，且完整 status 性能测试可接受后，再在 M1.5 评估 macOS FSEvents。可预留轻量接口：

```swift
protocol WorkingCopyChangeObserving: Sendable {
    func start(workingCopyID: UUID, rootURL: URL) async throws
    func stop(workingCopyID: UUID) async
}
```

M1 不需要提供该协议的生产实现。未来 FSEvents 只能调用现有刷新协调器，不能直接把 created、removed 或 renamed 事件映射为 SVN 状态。出现事件丢失时仍需执行完整 status。

## 11. 操作并发模型

每个 Working Copy 对应一个 `WorkingCopyOperationCoordinator` actor：

```swift
actor WorkingCopyOperationCoordinator {
    enum OperationKind {
        case status
        case checkout
        case update
        case commit
        case revert
        case cleanup
    }
}
```

规则：

- status 可以合并、取消和被写操作取代。
- checkout、update、commit、revert、cleanup 严格串行。
- 写操作开始时取消或等待当前 status，避免同时访问 Working Copy 元数据。
- 写操作结束后强制执行一次完整 status。
- 不同 Working Copy 之间允许并行执行。
- 应用内操作不能阻止用户在 Finder 中修改文件，因此每次远端写入前仍需重新校准。

## 12. UI 设计

### 12.1 侧边栏

新增“工作副本”分组：

```text
工作副本
  项目资料                  3 个修改
  合同模板                  有冲突
  旧项目                    位置不可用
```

右键菜单：

- 打开。
- 在 Finder 中显示。
- 刷新状态。
- 重新定位。
- 修改显示名称。
- 移除记录。

“移除记录”不得删除本地目录。需要删除本地文件时使用独立的危险操作和二次确认。

### 12.2 文件列表

文件列表直接读取本地文件系统，继续采用 Finder 风格 `NSOutlineView`。状态以图标叠加和文字表达：

| 状态 | 建议图标 | 用户文案 |
| --- | --- | --- |
| modified | `pencil.circle.fill` | 已修改 |
| unversioned | `questionmark.circle.fill` | 未纳入版本控制 |
| added | `plus.circle.fill` | 已添加 |
| deleted/missing | `minus.circle.fill` | 已删除或本地丢失 |
| conflicted | `exclamationmark.triangle.fill` | 有冲突 |
| replaced | `arrow.triangle.2.circlepath.circle.fill` | 已替换 |
| normal | 无 | 不显示状态文字 |

首个里程碑的工具栏操作：

- 刷新状态。
- 在 Finder 中显示。
- 打开文件。
- 返回对应仓库位置。

后续里程碑再增加更新、提交、添加、删除、放弃修改和解决冲突。

### 12.3 文件打开

Working Copy 模式使用 `NSWorkspace.shared.open(localURL)` 直接打开本地文件，不创建 `OpenDocuments/<UUID>` 副本。用户从外部编辑应用返回 Folio SVN 后，应用激活事件触发 status 更新；保持在前台时可以手动刷新。

现有“编辑副本修改后上传”流程只属于远端仓库模式，不能同时跟踪 Working Copy 内的同一文件。

## 13. 错误和恢复

| 场景 | 处理 |
| --- | --- |
| Checkout 认证失败 | 保留服务器配置，删除临时目录，允许重试 |
| HTTPS 证书失败 | 复用服务器证书策略提示，不在 Working Copy 单独保存例外 |
| 用户取消 Checkout | 终止进程并删除临时目录，记录为已取消任务 |
| 目标路径被其他程序创建 | 不覆盖，保留临时结果直到错误处理结束后清理 |
| Working Copy 被移动 | 标记位置不可用，提供重新定位 |
| `.svn` 损坏或被删除 | 标记为无效 Working Copy，不将普通目录误判为干净 |
| Working Copy 被其他 SVN 客户端锁定 | 展示可理解错误，后续提供显式 Cleanup，不自动执行 |
| Folio SVN 保持前台时文件被后台进程修改 | 用户手动刷新；远端写操作前强制完整 status |
| status 被取消 | 保留上次成功状态并显示正在刷新，不清空列表 |
| 应用启动时目录不可访问 | 保留注册记录，不自动删除 |

## 14. 后续里程碑

### M1：Checkout 与状态跟踪

- Working Copy GRDB migration 和注册服务。
- Checkout Sheet、预检、临时目录和取消清理。
- Checkout 当前使用不确定进度；逐路径流式 SVN 输出留到后续体验优化。
- `svn info --xml` 和 `svn status --xml` 解析。
- 打开、切换、App 回到前台和手动操作触发的完整状态校准。
- status 请求合并、generation 校验和失败时保留旧状态。
- 侧边栏 Working Copy 分组和本地文件浏览。
- 打开文件、Finder 定位、重新定位和移除记录。

### M1.5：性能验证与可选实时监听

- 采集不同规模 Working Copy 的完整 status 耗时。
- 根据真实需求决定是否增加局部 status。
- 如果需要前台实时状态，使用原生 FSEvents 触发现有刷新协调器，不增加第三方监听库。
- 文件事件只触发刷新，不直接生成 SVN 状态。

### M2：本地版本控制操作

- `svn add`、`svn delete`、`svn revert`。
- 多选和批量操作。
- 缺失文件与未跟踪文件的明确处理。
- 操作结束后的强制状态校准。
- 本地文本差异和现有 Word 差异能力复用。

### M3：Update 与 Commit

- Update 前状态检查和本地修改提示。
- 选择变更项提交；复选框只限定 commit 路径，不伪装成 Git 暂存区。
- Commit 前重新执行 status。
- 可选执行 `svn status --show-updates --xml` 检查远端变化。
- 复用传输任务、取消提示和成功 revision 展示。

### M4：冲突与重命名体验

- 冲突文件分类、Mine/Theirs/Base 入口和外部合并工具。
- 应用内重命名使用 `svn move`。
- Finder 重命名显示为 missing + unversioned；后续通过文件标识、大小和内容哈希提供“确认为移动”，不自动误判。
- Externals 和 sparse checkout 的高级设置。

## 15. 测试策略

### 15.1 单元测试

- SVN status XML 的全部状态映射和未知状态处理。
- Working Copy 路径标准化、重复和嵌套校验。
- App 激活、手动刷新和 Working Copy 切换的触发规则。
- status 请求合并、generation 和二次刷新逻辑。
- 操作协调器的串行规则和 status 合并。
- 目录不可用、重新定位和注册记录生命周期。
- Checkout 取消后的临时目录清理。

App 生命周期通过协议或显式方法注入，不要求单元测试启动完整 `NSApplication`。

### 15.2 本地 SVN 集成测试

使用临时 `svnadmin create` 仓库验证：

1. Checkout 后内容和 revision 正确。
2. 修改已跟踪文件后 status 为 modified。
3. 创建文件后 status 为 unversioned。
4. `svn add` 后状态为 added。
5. 删除文件后状态为 missing；执行 `svn delete` 后为 deleted。
6. Checkout 取消不会注册 Working Copy，也不会留下临时目录。
7. 一次写操作结束后只产生一次最终状态更新。

### 15.3 AppKit 行为测试

- 侧边栏选择在状态刷新后保持不变。
- 展开目录不会因为 status 更新而全部收起。
- Working Copy 不可用时操作按钮正确禁用。
- 仓库模式和 Working Copy 模式切换不会复用错误的选择、缓存或工具栏状态。

## 16. 可观测性与隐私

建议记录：

- Working Copy ID、操作类型、耗时和退出状态。
- status 扫描条目数量、触发原因和被合并的刷新次数。
- App 激活刷新、手动刷新和写操作前校准次数。
- Checkout 已处理文件数量和取消阶段。

不得记录：

- 密码、标准输入内容或认证参数。
- 完整用户文件内容。
- 默认记录完整本地绝对路径；诊断日志应使用 Working Copy ID 和相对路径，导出前允许用户预览。

## 17. M1 验收标准

- 用户能从仓库目录创建完整 Working Copy，并在任务面板看到运行状态。
- Checkout 超过 10 秒不会被错误判定为连接超时。
- 用户取消 Checkout 后 SVN 子进程终止，临时目录被清理，数据库没有无效记录。
- 应用重启后能恢复 Working Copy 列表，并重新确认目录和 SVN 状态。
- 外部程序修改、创建或删除文件后，用户回到 Folio SVN 时界面自动更新。
- 用户不切换应用时，可以通过刷新按钮重新读取目录和 SVN 状态。
- 目录移动或 `.svn` 损坏时不会显示错误的“干净”状态。
- 连续收到 App 激活和界面恢复事件时，不会并行启动多个 status 进程。
- Working Copy 状态刷新不会重置文件树展开状态和当前选择。
- Working Copy 模式打开文件时直接使用本地路径，不生成远端仓库模式的编辑副本。
- M1 不会在未明确实现 Commit 的情况下对远端仓库产生写入。

## 18. 实施决策摘要

- Working Copy 是独立模式，不替代远端仓库模式。
- M1 不实现文件系统监听；打开、切换、App 回到前台和手动操作触发完整 status。
- `svn status --xml` 是唯一状态事实来源，未来 FSEvents 也只能作为可选刷新触发器。
- Checkout 使用连接预检加无总时长限制的可取消长任务。
- Checkout 先写入同级临时目录，成功后原子移动并注册。
- 本地文件状态不持久化，启动时重新扫描。
- 首版固定完整 checkout、忽略 externals，并使用完整 status 保证正确性。
- 第一阶段只完成 Checkout 和状态跟踪，再逐步加入 Revert、Update、Commit 与冲突处理。
