# NEXT

## 目标版本

- **预计 APP 版本**：v1.3.6
- **当前基线版本**：v1.3.5+25
- **记录日期**：2026-09-16

## 更新内容

> 待发布版本草稿。后续每修复一个问题、优化一个体验或新增一个功能，都先记录到这里；最终发版时再整理为正式版本号文件，例如 `v1.3.6.md`。

（暂无）

## v1.3.5 遗留的已知项

v1.3.5 修了 issue #7 #8 #9，下面三条是那一轮新记下、但刻意留到后面的：

- **开屏页的整体超时不会取消已经在跑的启动流程**。`Future.timeout` 不取消源 future：
  每一步都没超时、合计超过 75s 时，失败态已经显示出来，孤儿流程随后仍可能登录成功并
  `_go('/dashboard')`，把用户从失败屏拽走；用户若已点过「重试」，还会有两条流程并发导航。
  `_go` / `_step` 都判了 `mounted`，离开页面后全部空转，所以爆炸半径有限。
  干净的修法是加一个 generation 计数并穿进 `_bootSteps`，在 `_go` / `_step` 里比对。

- **环境变量的「信封解析」写了第二份**。`envCreateFailureMessage` 与
  `EnvImportOutcome.fromResponse`（`utils/env_transfer.dart`）都在做「Map → 遍历 errors → 取第一条」，
  且前者连同 `EnvWriteException` 一起定义在 `env_list_page.dart` 里，而不是按仓库惯例放进 `utils/`。
  合并时可以整体搬进 `env_transfer.dart` 并共用一个 errors 提取器，测试只需改 import 一行。

- **环境变量页另外两条失败路径的提示同样会被弹层盖住**。编辑弹层保存失败、详情弹层里的
  启用/禁用失败，都是「失败时不关弹层 + 只发 AppSnack」，而 AppSnack 挂在页面 Scaffold 上、
  整块压在 `useRootNavigator: true` 的弹层之下（v1.3.5 已实测过新建那条的几何：snack 完全落在 sheet 内）。
  这是 v1.3.4 就有的行为，建议按 v1.3.5 新建路径的写法（把原因写回弹层内的 errorText）一次性收口。

## v1.3.4 遗留的已知项

v1.3.4 没动下面这些遗留项，原样顺延；末尾两条是 v1.3.4 那轮新记下、但不在其范围内的：

- **`copyWith` 的「不传即清空」语义是个反复踩的陷阱**。六个列表 State 的 `error` 都是裸赋值
  （`error: error` 而不是 `error ?? this.error`），这是有意的：`load()` 开头一句
  `copyWith(loading: true)` 就能顺手清掉上次的错误。代价是**任何**不传 `error` 的
  `copyWith` 都会把它抹掉。`v1.3.1` 已修掉两处会造成用户可见问题的
  （`DepListNotifier.loadPythonRuntimes` 与 `ScriptNotifier.setKeyword`），
  但 `ScriptNotifier` 里还有约 10 处同形状的调用（`loadContent` / `saveContent` /
  重命名与移动后的 `selectedPath` 更新等）没有显式回传 `error`。
  它们目前都发生在「树已经加载成功」之后所以看不出问题，**但这个陷阱会一直在**。
  彻底的解法是把 `copyWith` 改成哨兵语义、让 `load()` 显式写 `error: null`，
  那要同时改 6 个 State、11 个 Notifier 和 25 条测试，至今没做。

- **通知渠道页在「渠道列表失败但类型表成功」时会丢掉已取回的类型表**。
  `NotificationListNotifier.load()` 并发打两个接口，渠道列表失败时 `typesFuture`
  被直接丢弃、从不 await，catch 分支只能回落到内置快照。不会崩（`_fetchTypes`
  内部吞掉所有异常），但那份已经拿到手的数据白白浪费了。注释里写明类型表要单独降级，
  所以这可能是有意的，值得确认一次。

- **`open_api_page.dart` 的权限范围仍是硬编码**，与面板服务端的 `OpenAPIAccess`
  没有任何机制绑定。面板侧 `v3.0.2` 加了测试把服务端与面板 Web 双向锁死，
  但**管不到这个仓库** —— 面板将来加第 9 个权限范围时，APP 还是会漏。
  要根治得让面板下发 scope 字典（那是另一期的事，且第 2 期方案 §6.b 已经
  明确砍掉过 `/api/system/enums`，要重新论证）。

- **`user_list_page.dart` 的两个 `library_private_types_in_public_api`**
  仍在基线 7 个 info 里。根因是 `UserListState.items` 用了私有类型 `List<_User>`。

- **APP 全仓没有任何 CI 门禁**：`.github/workflows/` 下 grep 不到 `dart format` /
  `analyze` / `flutter test`，三项全靠本地自觉。面板那边 release 前有 checks job 挡着。

- **自动登录路径遇到两步验证账号只能退回登录页重来一次**。
  `app_boot_page.dart` 的自动登录走的是同一个登录接口，但它不带 `totpCode`、
  也不认 `two_factor_required`：v1.3.2 修完之后它不再抛异常，而是发现拿不到
  `access_token`，跳到 `/login?manual=1`。行为是正确的（总比卡在启动页强），
  账号密码也会自动回填，但用户仍然要在登录页**再点一次登录**，
  才会看到验证码输入框——等于自动登录对开了两步验证的账号事实上无效。
  彻底的做法是让启动页自己接住这个中间态、直接把 TOTP 输入框推到前面，
  至今没做。

- **`login_page.dart` 的两步验证分支不清空验证码输入框**。
  `two_factor_required` 分支的 `setState` 只写了 `_needsTotp` / `_error` / `_loading`，
  没有 `_totpController.clear()`。动态码输错之后，旧的 6 位数字会原样留在框里，
  用户得先手动全选删掉才能重输，而框上那个 `x/6` 计数器还显示着 `6/6`，
  看起来像是已经填好了。纯体验问题，不影响能否登录。

- **任务页之外的长列表还没做过同样的体检**。v1.3.3 只处理了任务页，
  但「把分组/分节包进 `Column`，再塞进一个 `ListView`」这个写法是否在
  脚本、依赖、日志、订阅等页面还有同形状的复制品，没有逐页确认过。

- **切换面板后，视图编辑器的「分组」选项可能沿用上一个面板的探测结论**（v1.3.4 新记）。
  `taskViewProvider` 是全局的，切面板时没有被 invalidate；新面板的 `/api/tasks/groups`
  探测恰好超时或回 5xx 时，按「保留上一次结论」的设计会沿用前一个面板的结果。
  要叠加一次瞬时失败才会发生；要修就得牺牲「同一面板遇到 5xx 不闪烁」，暂未处理。

- **任务启用 / 禁用按钮没有 widget 级测试**（v1.3.4 新记）。侧滑按钮的文案、图标、颜色
  与 `_toggleTaskEnabled` 的分支写在私有 widget 和页面 State 里，单测只覆盖了它们依赖的
  `isSwitchOn` / `switchActionLabel` 两个 getter；仓库还没有 TaskListPage 的 widget 测试脚手架。
