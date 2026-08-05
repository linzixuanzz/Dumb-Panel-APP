# 适配面板 v2.2.18 和 v2.2.19 并完善 APP 功能

## Goal

让 Flutter APP 端跟上呆呆面板 `v2.2.18` 和 `v2.2.19` 的关键行为变化，优先修复会直接影响移动端操作正确性的适配缺口，并顺手补齐当前 APP 里已经暴露出来的明显状态展示和交互不足。

## What I already know

- 当前 APP 仓库是独立 Flutter 项目，`pubspec.yaml` 版本为 `1.2.1+14`。
- `README.md` 仍写着“适配面板 v2.2.17”，说明 APP 端适配说明已经滞后。
- 面板 `v2.2.18` 的关键 APP 影响点：
  - 新建任务默认 Python 版本应跟随依赖管理默认版本，而不是固定 `3.12`。
  - Python 3.10 / 3.11 / 3.12 多版本运行时与默认版本设置已经成为正式能力。
- 面板 `v2.2.19` 的关键 APP 影响点：
  - 系统更新分为二进制更新、Docker 更新、Watchtower 托管更新三类，返回了更丰富的 `update_target` 信息。
  - Watchtower 手动触发成功时不等同于“面板马上自动重启完成”，旧 APP 的成功提示语已经不准确。
  - 更新链路支持 `update-status` 轮询，但 APP 侧目前没有展示。
  - 系统资源拿不到内存总量时，后端会明确视为“资源采集不可用”，不应继续用 `0%` 误导展示。
- 当前 APP 已经有以下页面或能力：
  - 任务、日志、环境变量、订阅、脚本、依赖、备份恢复、系统设置、Open API、安全设置等。
  - 依赖页已经支持 Python 多版本运行时与默认版本设置。
  - 备份页已经支持恢复进度轮询。
- 当前明确发现的适配缺口：
  - 任务表单 `_pythonVersion` 默认值仍写死为 `3.12`。
  - 系统设置页更新弹窗和成功提示没有区分 Watchtower / 二进制 / Docker。
  - APP 侧没有展示面板后台更新状态。
  - 仪表盘内存卡片在资源不可用时仍会显示 `0%` 风格信息。

## Assumptions

- 本轮优先处理“会误导用户或导致配置错误”的适配问题，不扩展为大规模新功能重构。
- 面板主体返回的关键接口字段保持当前仓库代码所示行为：
  - `/api/deps/python-runtimes`
  - `/api/system/check-update`
  - `/api/system/update`
  - `/api/system/update-status`
  - `/api/system/info`
- APP 端不在本轮内新增完整“系统健康检查”独立页面，但会修正现有资源展示的误导状态。

## Requirements

- 新建任务时，默认 Python 版本必须跟随面板依赖管理中的默认 Python 版本。
- 编辑已有任务时，仍优先显示该任务自己保存的 Python 版本。
- 系统设置页检查更新后，必须正确展示面板返回的更新方式、限制原因和关键元信息。
- 触发系统更新后，APP 必须给出与真实更新方式一致的提示，不再统一写成“面板将自动重启”。
- APP 需要展示可感知的面板后台更新状态，至少能看到运行中 / 重启中 / 失败等状态与消息。
- 仪表盘在拿不到内存总量时，不再把内存使用情况误展示为 `0%`。
- README 和版本说明需要同步说明本次适配目标与变化。

## Acceptance Criteria

- [ ] 新建任务页面在服务器默认 Python 版本为 `3.10` 或 `3.11` 时，会自动带出对应默认值。
- [ ] 编辑已有任务时不会被新的默认 Python 版本覆盖原有值。
- [ ] 系统设置页检查更新后，若后端返回 Watchtower 托管信息，APP 能显示相应说明与正确按钮/提示文案。
- [ ] 触发 Watchtower 更新时，APP 不再提示“面板将自动重启”这类不准确文案。
- [ ] 触发普通后台更新时，APP 能看到后端返回或轮询到的更新状态信息。
- [ ] 仪表盘在 `memory_total = 0` 时，会显示“资源采集不可用”或等价提示，而不是 `0%`。
- [ ] `flutter analyze` 通过。
- [ ] `flutter test` 通过或明确记录无法通过的原因。

## Definition of Done

- 关键适配代码已完成并自测。
- README / 发布说明已同步。
- 运行静态检查和测试，确认没有把现有功能改坏。

## Technical Approach

- 任务表单直接调用 Python 运行时接口读取 `default_version`，只在“新建任务”场景下自动套用默认值。
- 系统设置页读取并展示 `check-update` / `update` / `update-status` 返回的结构化信息。
- 仪表盘继续走现有 `system/info` 接口，但新增“资源不可用”判断，不沿用简单百分比展示。
- 文档层面同步 README 兼容版本，并补一个新的 APP 发布说明文件。

## Decision (ADR-lite)

**Context**：这次需求同时包含“版本适配”和“功能审查”，但用户没有要求立即做大规模新功能扩展。  
**Decision**：本轮先做会影响正确性和状态感知的高优先级适配，再把剩余缺失功能作为审查结果输出。  
**Consequences**：这能最快把 APP 从“兼容 v2.2.17”拉到“正确适配 v2.2.19”，同时避免本轮范围失控。

## Out of Scope

- 新增完整的系统健康检查独立页面。
- 重做底部导航结构。
- 对脚本页、日志页、订阅页做大规模交互重构。
- 引入新的状态管理方案或跨模块架构重构。

## Technical Notes

- 关键 APP 文件：
  - `lib/features/tasks/views/task_form_page.dart`
  - `lib/features/system/views/system_settings_page.dart`
  - `lib/features/dashboard/providers/dashboard_provider.dart`
  - `lib/features/dashboard/views/dashboard_page.dart`
  - `lib/core/network/api_endpoints.dart`
  - `README.md`
- 面板主体对照文件：
  - `D:\爱学习的呆子\呆呆面板开发\docs\release-notes\v2.2.18.md`
  - `D:\爱学习的呆子\呆呆面板开发\docs\release-notes\v2.2.19.md`
  - `D:\爱学习的呆子\呆呆面板开发\server\handler\system.go`
  - `D:\爱学习的呆子\呆呆面板开发\server\handler\system_update.go`
  - `D:\爱学习的呆子\呆呆面板开发\server\handler\deps.go`
