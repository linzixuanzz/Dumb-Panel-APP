# NEXT

## 目标版本

- **预计 APP 版本**：v1.3.2
- **当前基线版本**：v1.3.1+21
- **记录日期**：2026-08-10

## 更新内容

> 待发布版本草稿。后续每修复一个问题、优化一个体验或新增一个功能，都先记录到这里；最终发版时再整理为正式版本号文件，例如 `v1.3.2.md`。

### 新增

- 暂无。

### 优化

- 暂无。

### 修复

- 暂无。

### 说明

- 本文件用于收集下一轮 APP 端更新内容，正式发布前会根据实际改动整理成用户可读版本。

## v1.3.1 遗留的已知项

v1.3.0 那份 7 条遗留**已全部处理完**（见 `v1.3.1.md` 末尾的对照表）。下面是本轮做完之后**新发现**、但没有在本轮解决的：

- **`copyWith` 的「不传即清空」语义是个反复踩的陷阱**。六个列表 State 的 `error` 都是裸赋值
  （`error: error` 而不是 `error ?? this.error`），这是有意的：`load()` 开头一句
  `copyWith(loading: true)` 就能顺手清掉上次的错误。代价是**任何**不传 `error` 的
  `copyWith` 都会把它抹掉。本轮已修掉两处会造成用户可见问题的
  （`DepListNotifier.loadPythonRuntimes` 与 `ScriptNotifier.setKeyword`），
  但 `ScriptNotifier` 里还有约 10 处同形状的调用（`loadContent` / `saveContent` /
  重命名与移动后的 `selectedPath` 更新等）没有显式回传 `error`。
  它们目前都发生在「树已经加载成功」之后所以看不出问题，**但这个陷阱会一直在**。
  彻底的解法是把 `copyWith` 改成哨兵语义、让 `load()` 显式写 `error: null`，
  那要同时改 6 个 State、11 个 Notifier 和 25 条测试，本轮没做。

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
