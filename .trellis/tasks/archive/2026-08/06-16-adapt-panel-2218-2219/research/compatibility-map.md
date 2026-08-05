# APP 适配映射结论

## 面板 v2.2.18

- **必须适配：任务默认 Python 版本**
  - 面板已改为“新建任务默认跟随依赖管理默认 Python 版本”。
  - APP 现状：`lib/features/tasks/views/task_form_page.dart` 中 `_pythonVersion` 仍默认 `3.12`。
  - 结论：必须修。

- **已具备但要继续复核：Python 多版本依赖**
  - APP 依赖页已经接了 `/deps/python-runtimes` 和 `/deps/python-runtime-default`。
  - 结论：任务页要与依赖页保持一致，不然同一能力在 APP 内前后矛盾。

## 面板 v2.2.19

- **必须适配：系统更新返回语义**
  - 面板后端会返回 `update_target`，区分：
    - `deployment_type = binary`
    - `update_manager = watchtower`
    - Docker 普通更新
  - APP 现状：系统设置页仍把更新成功统一提示成“面板将自动重启”。
  - 结论：必须修。

- **建议补齐：更新状态展示**
  - 面板已有 `/api/system/update-status`。
  - APP 现状：没有任何后台更新状态展示。
  - 结论：本轮补一个轻量状态展示，收益高。

- **建议修正：资源不可用时的内存展示**
  - 后端健康检查已把 `memory_total = 0` 判定为“资源采集不可用”。
  - APP 现状：仪表盘会把内存卡片继续按百分比画出来，容易误导。
  - 结论：本轮顺手修正。

## 暂不作为本轮主改项

- 订阅 sparse checkout / 白名单本身，APP 侧主要是表单字段，已有支持，不需要额外协议改动。
- 备份恢复 staging 安全写回是后端内部改进，APP 当前恢复进度页已基本跟上。
- Magisk 运行时能力链路主要在服务端 / 模块端，APP 只需正确展示系统更新行为，不必本轮新增专用页面。
