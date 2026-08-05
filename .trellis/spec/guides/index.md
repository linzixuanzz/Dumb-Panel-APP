# 思考清单

> **用途**：动手前扩展思路，抓住那些「没想到」的东西。
> 本目录已按本仓库（Flutter 客户端 `daidai_app`）的语境改写，示例全部来自真实代码。

---

## 为什么需要思考清单

**多数 bug 和技术债来自「没想到」，不是能力不够。**

本仓库真实发生过的四个「没想到」：

| 没想到 | 结果 | 依据 |
|---|---|---|
| `validateStatus: status < 500` 会让 401 变成「成功」 | 70 行 token 续期逻辑**一次都没执行过**，用户看到的是空白页而不是「请重新登录」 | `lib/core/network/dio_client.dart:16`、`lib/core/auth/auth_interceptor.dart:46-114` |
| 编辑表单用空 map 重建 config 会**覆盖**未知字段 | 用户在 Web 配的 telegram proxy / wecom 参数，经 APP 保存即丢失 | `notification_list_page.dart:735-757` |
| 主题文件不生效 | 圆角改成 0，界面 96% 的卡片纹丝不动 | 手写 `BoxDecoration` 134 处 vs `Card` 6 处 |
| 后端 `page_size` 上限 100，超限会**静默退回 20** | 环境变量列表只显示 40 行 | `env_list_page.dart:67-69` 注释 |

这些都不是「写错了」，是「没往那儿想」。

---

## 可用清单

| 清单 | 用途 | 何时读 |
|---|---|---|
| [代码复用思考清单](./code-reuse-thinking-guide.md) | 发现重复形态、决定该不该抽象 | 你正要新写一个「好像见过」的东西 |
| [跨层思考清单](./cross-layer-thinking-guide.md) | 想清楚数据在层与层之间怎么流 | 改动跨越 面板 API ↔ 模型 ↔ provider ↔ UI |

---

## 触发条件

### 什么时候读跨层清单

- [ ] 改动同时涉及 `api_endpoints` / 模型 / provider / 页面
- [ ] 数据在层与层之间**换了形状**（后端 `List` ↔ 客户端逗号串、UTC ↔ 本地时区）
- [ ] 一个响应被 2 个以上页面消费
- [ ] 你在做「读取 → 修改 → 回写」（这是本仓库丢过数据的地方）
- [ ] 你要动 `dio_client.dart` 的 `validateStatus`（会波及**所有**调用点）

→ 读 [跨层思考清单](./cross-layer-thinking-guide.md)

### 什么时候读复用清单

- [ ] 你正要写的东西，别处好像已经有了
- [ ] 同一形态出现 3 次以上
- [ ] **你要改任何常量或配置值**
- [ ] **你要新建一个 util / helper** ← 先搜！`shared/utils/` 只有 4 个文件，但被引用 92 处
- [ ] 你要新建一个 widget，先问：`shared/widgets/` 里为什么只有 2 个文件

→ 读 [代码复用思考清单](./code-reuse-thinking-guide.md)

---

## 改任何值之前的铁律

> **改任何值之前，先搜。**

```powershell
# Windows / PowerShell
rg "要改的值" lib
```

本仓库特别容易踩的三类值：

| 值 | 为什么危险 |
|---|---|
| `'3.12'`（Python 默认版本） | 后端已提供 `default_version`，客户端还有 3 处兜底常量（`task.dart:47`、`task_form_page.dart:84-85`） |
| `AppColors.primary` | 第 0 期要从 `#10B981` 切到 `#409eff`，但页面到处直接引用 `AppColors.*` 而非 `ColorScheme` |
| `validateStatus` | 一处配置决定全 APP 所有 4xx 是走 try 还是走 catch |

---

## 怎么用

1. **动手前**：扫一眼对应清单
2. **写的过程中**：如果开始觉得重复或绕，回来看
3. **修完 bug 后**：把新的「没想到」补进对应清单

---

**核心原则**：想 30 分钟，省 3 小时调试。
