# 代码复用思考清单

> **用途**：写新代码之前先停一下 —— 它是不是已经存在了？

---

## 问题

**重复代码是不一致 bug 的头号来源。** 复制粘贴之后：

- 修 bug 修不全
- 行为随时间分叉
- 代码越来越难读

本仓库的现状是**重复非常多**，所以这份清单在这里格外重要。

---

## 写新代码之前

### 第一步：先搜

```powershell
rg "函数名" lib
rg "关键字" lib
```

### 第二步：问这四个问题

| 问题 | 如果是 |
|---|---|
| `shared/utils/` 里有类似的吗？ | 用它或扩展它 |
| 别的 feature 已经这么干了吗？ | 跟随既有形态 |
| 这东西第二个页面会用到吗？ | 放 `shared/`，别放 view 文件 |
| 我在从另一个文件复制代码吗？ | **停** —— 先想清楚该抽到哪 |

---

## 本仓库已知的重复形态

在动手抽象之前，先知道哪些重复**已经存在**，避免又造一个新的：

### 1. `_showMessage` —— 7 个文件逐字相同

```dart
void _showMessage(String message) {
  if (!mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
```

出现在：`task_list_page.dart:90`、`log_list_page.dart:238`、`backup_page.dart:308`、
`script_list_page.dart:476`、`server_config_page.dart:98`、`dep_list_page.dart`、
`app_lock_settings_page.dart`。

> 第 0 期共享组件层的候选之一。**不要再复制第 8 份。**

### 2. JSON 解析 helper —— 3 个模型文件各写一遍

`_int` / `_intOrNull` / `_double` / `_date`：`task.dart:189-196`、`env_var.dart:55-59`、`user.dart:54-60`。

### 3. 手写卡片 —— 134 处 `BoxDecoration`

每处自己拼 `color` + `borderRadius` + `border`，配 507 行 `isLight` 三元。
真正用 Flutter `Card` 的只有 6 处。**这是第 0 期 R4 要收敛的主目标。**

### 4. 「暂无 XXX」空状态 —— 27 处硬编码文案

每个列表页各写一遍 Icon + Text + 居中布局，没有一处带错误态或重试。

### 5. `_unset` 哨兵 —— 4 个文件，4 个不同名字

`_unset`（`task_provider.dart:9`）、`_authFieldUnset`（`auth_provider.dart:9`）、
`_panelFieldUnset`（`secure_storage.dart:6`）、`_selectedGroupUnset`（`env_list_page.dart:18`）。

### 6. 影子模型 —— `_User` vs `User`

`user_list_page.dart:68` 的私有 `_User` 与 `shared/models/user.dart` 的公开 `User` 字段大量重合，
还因此触发了 `library_private_types_in_public_api` lint。**不要再造第二个。**

---

## 什么时候该抽象

**该抽**：

- 同一形态出现 3 次以上（上面 6 条全部超标）
- 逻辑复杂到会出 bug（比如「保留未知字段」的合并逻辑）
- 抽出来之后有明确的归属地（`shared/utils/` 或 `shared/widgets/`）

**别抽**：

- 只用一次
- 一行的琐碎逻辑
- 抽象本身比重复更复杂
- **你只是路过**：改动既有 feature 时不要顺手做大范围迁移，diff 会没法审

---

## 本仓库的归属地判断

| 东西 | 放哪 | 依据 |
|---|---|---|
| 被 2+ feature 用的模型 | `lib/shared/models/` | 现有 9 个 |
| 纯函数工具 | `lib/shared/utils/` | 现有 4 个，被引用 92 处 |
| 被 2+ 页面用的 widget | `lib/shared/widgets/` | 现有**只有 2 个**，严重欠缺 |
| 只服务一个页面、<150 行的子组件 | 同 view 文件的私有 `_Xxx` class | 现状主流 |
| 只服务一个 feature、较大的子组件 | `features/<feature>/widgets/` | 仅 dashboard / app_lock / login 有 |
| 应用级基础设施 | `lib/core/` | 判据：2+ feature 依赖且无业务语义 |

---

## 批量改动之后

当你对多个文件做了类似修改：

1. **回看**：是不是所有实例都改到了？
2. **再搜一次**：`rg "旧写法" lib`
3. **想一下**：这次改了 N 处，说明它本来就该被抽出去吗？

---

## 陷阱：两套机制产出同一份结果

**问题**：当两个不同机制必须产出相同结果（例如一处自动派生、一处手工枚举），
结构性变更只会通过自动那条传播，手工那条会静默漂移。

**本仓库的实例**：通知渠道编辑。

- OpenAPI scope 那边用 `_parseScopes(scopes).toSet()`（`open_api_page.dart:671`）
  **完整保留**了未知 scope，保存时原样带回。
- 通知渠道那边 `configMap` 从 `{}` 开始，只填 `_channelFieldMap`（本地写死的 229 行常量表，
  `notification_list_page.dart:361`）里有的字段，然后整串 `jsonEncode` 覆盖回服务端
  （`:735-757`）。

**同一个仓库里两种做法，通知渠道是缺的那个。** 面板支持而 APP 字段表里没有的键保存即丢失。

**预防清单**：

- [ ] 「读取 → 修改 → 回写」时，基底是**服务端返回的原始对象**，不是新建的空对象
- [ ] 客户端写死的字段表（`_channelFieldMap` 这类）只用于**渲染表单**，不得用于**决定提交哪些键**
- [ ] 若同一语义在两处实现，找出保守的那一处并对齐

---

## 提交前自检

- [ ] 搜过了，确认没有现成的
- [ ] 没有复制粘贴本该共享的逻辑
- [ ] 常量只有一个定义处
- [ ] 相似形态遵循了同一结构
- [ ] 没有新增上面 6 条已知重复形态的第 N+1 份
