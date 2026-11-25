# Journal - Linzixuan (Part 1)

> AI development session journal
> Started: 2026-06-16

---

## Session 1: v1.3.5：脚本树展开保留、新建变量失败可见、启动卡住可自救（#7 #8 #9）

**Date**: 2026-09-16
**Task**: 处理 APP issue #7 #8 #9 并发布 v1.3.5
**Branch**: `main`

### Summary

面板 v3.2.8 发完后清理 APP 侧三条开放 issue。三组「实现 + 对抗复查」并行，复查各抓到一条 major：
#9 折叠父目录时子目录展开记录残留（会让再展开时整棵子树炸开）；#8 的真因比侦察结论更严重——
面板 `POST /envs` 对不合规变量名回的是 **200 + errors**，APP 因此弹「已创建」但列表没有，
修好后错误提示又被弹层整块盖住（实测 hitTest 命中的是弹层），改为写回输入框下方。
门禁绿后发布 v1.3.5，三条 issue 回复并关闭。

### Main Changes

- 脚本树展开状态提到页面级、按目录路径记忆，7 处写操作后的 `loadTree()` 不再折叠回顶层；
  重命名/移动做前缀迁移，目录消失靠过滤兜底；上传/新建脚本/新建文件夹三个弹窗默认目录统一。
- 新建环境变量：空名就地提示并聚焦；面板 200 信封里的 `errors` 被识别为失败并透出原话。
- 启动流程加单步（本地 10s / 网络 50s）与整体 75s 超时，失败态给出卡在哪一步 + 四个自救出口；
  `_jumping` 改为可复位的 `_running`；仪表盘预加载不再阻塞跳转。

### Testing

- [OK] `flutter analyze --no-pub`：7 个 info，与 v1.3.4 基线一致。
- [OK] `flutter test --no-pub`：479 全过（448 基线 + 本轮新增 31 条）。
- [OK] 变异验证 3/3：折叠清理、页面级展开状态、`_running` 复位，逐个改回旧写法后对应用例立刻变红，
  还原后哈希一致。
- [--] 未做真机实测：上传弹窗默认目录那处接线、四个自救出口的实际跳转，只有静态与 widget 层保证。

### Status

[OK] **Completed**

### Next Steps

- NEXT.md 已记三条留到后面的：整体超时后的孤儿流程、环境变量信封解析平移到 utils、
  编辑/详情弹层的提示同样被遮挡。



## Session 1: APP v2.0.0 视觉焕新发布

**Date**: 2026-11-25
**Task**: APP v2.0.0 视觉焕新发布
**Branch**: `main`

### Summary

APP v2.0.0：iOS 26 式留白、5 个 Tab（任务/日志/概览/变量/设置）、常用任务与按住运行、任务详情弹层（月历/P90）、日志四色筛选与错误行、概览页、变量遮蔽（开了应用锁才验证）、安卓快捷方式/桌面小组件/可选常驻通知，含 #27 #28；两波 9 组并行 + 一轮复核，测试 728→955；首次 Release 因 home_widget 要求 iOS 14 失败，提到 14.0 后重打 v2.0.0 发布成功。设计素材移到仓库外 design-assets/app-v2.0。

### Main Changes

(Add details)

### Git Commits

| Hash | Message |
|------|---------|
| `dca0f83` | (see git log) |
| `5f5798d` | (see git log) |
| `034ba3e` | (see git log) |
| `043c856` | (see git log) |
| `d93cdf0` | (see git log) |
| `f8d2a6d` | (see git log) |

### Testing

- [OK] (Add test results)

### Status

[OK] **Completed**

### Next Steps

- None - task complete
