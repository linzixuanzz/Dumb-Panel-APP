# 本仓库没有后端

**`D:\GitHub\Dumb Panel\android-app` 是纯 Flutter 客户端（`daidai_app`），不包含任何服务端代码。**

服务端（Go + Gin 的呆呆面板）在**另一个仓库**，其编码规范、ORM / 迁移 / 日志 / 错误处理约定
请到面板仓库的 `.trellis/spec/` 查阅，不要套用到本仓库。

`trellis init` 曾在本目录留下 5 个 Go/ORM 模板（database-guidelines / directory-structure /
error-handling / logging-guidelines / quality-guidelines），与本仓库无关，**已于第 0 期删除**。
保留本文件只为拦住「按目录名找后端规范」的人。

---

## 请改读

| 你要找的 | 去哪 |
|---|---|
| 目录结构、分层 | [`../frontend/directory-structure.md`](../frontend/directory-structure.md) |
| 状态管理 | [`../frontend/state-management.md`](../frontend/state-management.md) |
| 网络层 / API 调用 / 错误传递 | [`../frontend/hook-guidelines.md`](../frontend/hook-guidelines.md) |
| Widget 与样式 | [`../frontend/component-guidelines.md`](../frontend/component-guidelines.md) |
| lint / 测试 / 禁止项 | [`../frontend/quality-guidelines.md`](../frontend/quality-guidelines.md) |
| JSON 解析与后端契约 | [`../frontend/type-safety.md`](../frontend/type-safety.md) |
| 索引 | [`../frontend/index.md`](../frontend/index.md) |

---

## 本仓库与面板的关系

客户端只通过 HTTP 消费面板 API：

- 全部路径常量集中在 `lib/core/network/api_endpoints.dart`（193 行，两个前缀 `/api` 与 `/api/v1`）
- 响应形状的兼容处理集中在 `lib/shared/utils/api_utils.dart`
- 流式接口（任务日志、依赖安装、订阅拉取）走 `lib/core/network/sse_client.dart`，不经 dio

面板升级导致的客户端适配记录见
`.trellis/tasks/08-05-app-v2-phase0-foundation/research/legacy-compatibility-map-v2218-2219.md`。
