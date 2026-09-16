# 三条 issue 的代码级侦察结论（2026-09-16，主会话只读排查）

所有行号基于 v1.3.4 发版后的工作区（`1b73357`）。

## #9 脚本管理界面不刷新（上传后跳回主目录）

**用户原话**：「app 的脚本管理界面上传一个脚本就自动刷新到主目录，多个脚本上传太痛苦了」。

**真因**：展开状态是**每个树节点 widget 自己的局部 State**。

- `_FileTreeItemState._expanded`（`script_list_page.dart:1697`）默认 `false`，点目录时 `setState(() => _expanded = !_expanded)`（:1711）。
- `ScriptNotifier.loadTree()`（:215）重新拉 `/scripts/tree` 并整体替换 `state.tree` → 整棵树的 widget 重建 → 所有 `_expanded` 回到 `false`，界面折叠回顶层。
- 每一个写操作后都会调 `loadTree()`：`createFile`(:309)、`createDirectory`(:314)、`uploadFiles`(:340)、`renamePath`(:356)、`movePath`(:381)、复制(:411)、删除(:430)。**7 处全部受影响**，不只是上传。

**补充**：文件并没有传错位置。上传弹窗有「上传目录」下拉（:1616-1631），默认值是
`initialDir.isNotEmpty ? initialDir : _defaultScriptDirectory(state.selectedPath)`（:1559）——
顶部菜单进来时 `initialDir` 为空，而 `selectedPath` 只有在**打开过某个文件**后才有值，
所以「只展开目录浏览、没点开文件」时默认就是根目录。这是第二个可改点。

**修复方向**：展开状态提到页面级（按目录路径记一个 `Set<String>`），`loadTree()` 后保留；
上传默认目录改为「当前展开/浏览的目录」。

## #8 不能单独添加环境变量

**用户原话**：「不能单独添加环境变量」。

**已排除的两个假设**：

- 入口存在：列表页右上角 `AppCircleAddButton` → `_showCreateDialog()`（`env_list_page.dart:993`、:1655），
  但**只在非选择模式、非排序模式下显示**（:991）。
- 接口形状没问题：面板 `EnvHandler.Create`（`server/handler/env.go:290`）自己读原始 body，
  `raw[0] == '['` 走数组、否则按单对象解析（:318-330），**单对象和数组都收**；
  App 的 `create()` 发的就是单对象并且之后 `await load()`（`env_list_page.dart:238-248`），列表会刷新。

**剩下的两个候选（待实现者确认并覆盖）**：

1. **静默失败**：创建按钮 `onPressed` 第一行是 `if (nameC.text.trim().isEmpty) return;`（:1743）——
   变量名为空时**什么提示都不给、弹窗也不关**，用户点了没反应，体感就是「加不进去」。
2. **服务端拒绝后的提示是否够清楚**：面板对变量名有 `envNamePattern` 校验，不合规返回
   「第 N 项: 变量名 'x' 格式无效」。App 走 `AppSnack.error(extractErrorMessage(error, '创建环境变量失败'))`（:1763），
   需要确认这条 400 的 message 能否被 `extractErrorMessage` 取出来，而不是退化成兜底文案。

**修复方向**：空名不再静默 return（就地报错并聚焦输入框）；把服务端拒绝原因原样透出；
顺带确认选择/排序模式下新增入口消失是否会让用户以为「没有这个功能」。

## #7 app 卡开屏页面

**用户原话**：同网络下浏览器能正常访问面板，App 有时卡在开屏页，之后无法登录，
「清除缓存也不行，要清空数据重新登录才行，此情况偶有发生」。面板 3.2.0，App 最新版。
截图是 Android 多任务卡片：App 卡片一片空白只剩图标，旁边浏览器打开的面板正常。

**已排除**：

- dio 有超时（`dio_client.dart:21-23` connect 15s / receive 30s / send 15s；rawDio 10s）。
- 续期链路没有「永久悬挂」：`AuthInterceptor` 的 `finally` 里有 `_rejectPending` 兜底（:133-138），
  `TokenRefresher` 用 `whenComplete` 清 `_inFlight`（`token_refresher.dart:80-84`）。
- `handleAuthFailed` 走的是 `setUnauthenticated`（`main.dart:30-34`），不会把状态钉在 `unknown`。
- `main()` 启动只调 `restoreTrustedLocalSession()`（:45），它的三条分支都会把 status
  置成 `authenticated` 或 `unauthenticated`，不会停在 `unknown`。

**仍然可疑（按怀疑度排序，需实现者逐条判定）**：

1. **`_runBootFlow` 全程没有任何整体超时与失败出口**（`app_boot_page.dart:29-131`）。
   页面 UI 只有一个转圈 + 一行文案（:144-172），**没有任何按钮**：一旦某一步没返回，
   用户除了杀进程/清数据别无出路——这正是 issue 描述的形态。
2. **`_jumping` 置真后不复位**（:18、:34）：同一个 State 若因任何原因再次触发 `_runBootFlow`
   会被直接 `return`，页面停在转圈。
3. **7 天可信会话只看本地时间戳**（`secure_storage.dart:134-146`），不校验 token 是否仍有效：
   token 实际失效时仍按 `authenticated` 直接 `_go('/dashboard')`（`app_boot_page.dart:47-53`），
   后续请求 401 → 清会话 → 跳登录页，这条路径本身有兜底，但与「清缓存无效、必须清数据」的现象吻合。
4. **`_go('/dashboard')` 前 `await dashboardProvider.load()`**（:121）：这一步失败/慢都会拖住启动。

**修复方向（不指望复现）**：给启动流程加整体超时与**可自救 UI**（重试 / 返回登录 /
重新配置面板 / 清除本地会话），并把当前卡在哪一步显示出来；`_jumping` 改为可复位；
`dashboard` 预加载改为不阻塞跳转。目标是「即使再卡，用户也能自己走出来，并留下可诊断信息」。
