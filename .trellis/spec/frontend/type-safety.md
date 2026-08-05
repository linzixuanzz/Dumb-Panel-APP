# 类型安全与 JSON 解析

> 本文覆盖两件事：
> 1. 模型层解析后端 JSON 的**真实写法**（防御式，无 codegen）；
> 2. 「后端拥有的默认值 / 运行模式」不得写死在客户端 —— 这部分内容来自已归档的
>    `06-16-adapt-panel-2218-2219` 任务，**已在当前代码中复核仍然成立**。

---

## 前提：没有代码生成

全库 **0 个 `.g.dart`**，`pubspec.yaml` 无 `build_runner` / `json_serializable` / `freezed`。
所有 `fromJson` / `toJson` 都是手写的。

---

## `fromJson` 的统一写法：防御式，绝不裸 `as`

每个模型文件底部定义**文件私有**的转换 helper，`fromJson` 里全程走 helper：

```dart
// lib/shared/models/task.dart:189-196
int _int(dynamic v) => (v is num) ? v.toInt() : 0;
int? _intOrNull(dynamic v) => (v is num) ? v.toInt() : null;
double _double(dynamic v) => (v is num) ? v.toDouble() : 0.0;
double? _doubleOrNull(dynamic v) => (v is num) ? v.toDouble() : null;
DateTime? _date(dynamic v) {
  if (v is String && v.isNotEmpty) return DateTime.tryParse(v);
  return null;
}
```

`env_var.dart:55-59`、`user.dart:54-60` 各自复制了同名 helper。
**这是真实存在的重复**（`_int` / `_date` 在 3 个模型文件里各写一遍），
但目前没有集中到 `shared/utils/`。新增模型时按现状复制即可，不要为此单开一次重构。

### 五条解析约定

| 场景 | 写法 | 例 |
|---|---|---|
| 字符串字段 | `json['x']?.toString() ?? ''`（**不用 `as String`**） | `task.dart:122` |
| 数值字段 | `_int(json['x'])` / `_double(...)`，非 num 时给 0 | `task.dart:121, 133` |
| 布尔字段 | `json['x'] == true`（**不用 `as bool`**，null 自然为 false） | `task.dart:150-151`、`env_var.dart:35` |
| 时间字段 | `_date(json['x'])`，必填的补 `?? DateTime.now()` | `task.dart:162-163` |
| 列表字段 | 先 `is List` 判断再 map，否则给 `const []` | `task.dart:125-130` |

**唯一的例外**：`user.dart:34-37` 用了裸 `as`：

```dart
id: (json['id'] as num).toInt(),
username: json['username'] as String,
role: json['role'] as String? ?? 'viewer',
```

`User` 只从可信来源构造（登录响应 / SecureStorage），但这仍是全库最脆的解析点。
**新模型不要模仿它。**

### 后端字段名可能有多种形态，解析层负责兼容

```dart
// lib/shared/models/task.dart:134-136 —— labels 后端有时是 List 有时是逗号串
labels: json['labels'] is List
    ? (json['labels'] as List).join(',')
    : json['labels']?.toString() ?? '',
```

```dart
// lib/core/auth/auth_service.dart:25-41 —— need_init 有 3 种包裹形态
if (raw.containsKey('need_init')) return raw['need_init'] == true;
if (raw['data'] is Map<String, dynamic>) {
  final data = raw['data'] as Map<String, dynamic>;
  if (data.containsKey('need_init')) return data['need_init'] == true;
  if (data.containsKey('initialized')) return data['initialized'] == false;
}
```

---

## `toJson` 只写「可提交」的字段

`toJson` **不是** `fromJson` 的镜像。它是提交给后端的请求体，通常省略 `id` / `created_at` / 只读派生字段：

```dart
// lib/shared/models/task.dart:167-186 —— 没有 id、status、created_at、
// last_run_at、notification_channel_name 等只读字段
Map<String, dynamic> toJson() => {
  'name': name,
  'command': command,
  'cron_expression': cronExpression,
  ...
};
```

`env_var.dart:46-52` 甚至**同时**发 `group`（逗号串）与 `groups`（数组）以兼容新旧面板。

---

## 页面私有模型：写在 view 文件里的 `_Xxx` class

只被一个页面使用的响应模型，现状是写成 view 文件里的私有 class，
仍然遵守上面的防御式解析：`_User`（`user_list_page.dart:68`）、
`_BackupFileRecord`（`backup_page.dart:282`）、`_TaskNotificationChannel`（`task_form_page.dart:185`）。

⚠️ `_User` 与 `shared/models/user.dart` 的 `User` 字段大量重合，且触发了
`library_private_types_in_public_api` lint（见 quality-guidelines.md）。**不要再增加这种影子模型。**

---

## `dynamic` 的合法用法

`dynamic` 只允许出现在**传输边界**（响应解包、错误提取），不得渗到 UI：

```dart
// lib/shared/utils/api_utils.dart:3, 13, 44
dynamic extractData(dynamic responseData) { ... }
({List<Map<String, dynamic>> items, int total}) extractPaginated(dynamic responseData) { ... }
String extractErrorMessage(dynamic error, String fallback) { ... }
```

注意 `extractPaginated` 用了 **Dart 3 record 类型**作为返回值 —— 全库唯一一处 record 用法。

`extractErrorMessage` 内部用 `(error as dynamic).response?.data` 包在 try/catch 里做鸭子类型探测
（`api_utils.dart:46-59`），以便同时吃 `DioException` 和普通异常。**这是刻意的，不要改成强类型 `is DioException`**
——调用方传进来的类型确实不统一（有 `dynamic`、有 `Object`）。

---

## 场景：后端拥有的默认值与运行模式

### 触发条件

Flutter 页面消费的面板 API 中，包含**由后端决定的默认值**或**运行模式元数据**时。
本仓库中的三个：

- `GET /api/deps/python-runtimes`
- `GET /api/system/check-update`
- `GET /api/system/update-status`

### 响应形状

| 端点 | 关键字段 |
|---|---|
| `/api/deps/python-runtimes` | `data: PythonRuntimeInfo[]`、`default_version: string` |
| `/api/system/check-update` | `data.current` / `data.latest` / `data.has_update` / `data.auto_update_supported` / `data.update_disabled_reason` / `data.update_target: map` |
| `/api/system/update-status` | `data.status` / `data.phase` / `data.message` / `data.error` |

### 契约

1. **后端默认值必须从响应里读，不得复制成客户端常量。**
2. 两个以上 feature 读同一响应形状时，模型放 `lib/shared/models/`。
3. UI 只能把 fallback 当作「后端字段缺失时的最后兜底」，有值时必须优先用后端值。
4. `update_target` 这类运行模式载荷必须**按模式分支渲染**：
   `deployment_type = binary` / `update_manager = watchtower` / 默认 Docker 路径。

### 边界与错误矩阵

| 情况 | UI 必须怎么做 |
|---|---|
| `default_version` 缺失 | 可回落 `'3.12'`，但只要后端有值就必须优先用 |
| `data` 列表缺失或不完整 | 不得崩溃；显示兜底下拉项或只读状态文本 |
| `update_target` 有未知字段 | 保留通用状态摘要，不得假定单一更新流程 |
| `auto_update_supported = false` | 禁用/隐藏立即更新按钮，并显示后端给的 `update_disabled_reason` |

### 当前实现（已复核仍成立）

```dart
// lib/features/tasks/views/task_form_page.dart:223, 248-266
// 新建任务时，默认 Python 版本必须跟随后端默认版本，而不是继续写死 3.12。
final defaultVersion = map['default_version']?.toString().trim().isNotEmpty == true
    ? map['default_version'].toString().trim()
    : '3.12';
```

```dart
// lib/features/system/views/system_settings_page.dart:189-194
final target = _updateInfo?['update_target'];
return target['update_manager']?.toString() == 'watchtower'
    || target['watchtower_managed'] == true;
```

`:304` 与 `:654` 据 `auto_update_supported` 控制更新入口是否可见。

### 错误 vs 正确

**错误**

```dart
String _pythonVersion = '3.12';                       // 写死后端拥有的默认值
showSnackBar('更新已启动，面板将自动重启');              // 忽略 watchtower / binary 模式差异
```

**正确**

```dart
_pythonVersion = defaultVersionFromApi;               // 以后端返回为准

if (isWatchtowerManaged) {
  showSnackBar('已触发 Watchtower 检查更新，请稍后查看结果');
} else if (isBinaryUpdate) {
  showSnackBar('后台更新任务已启动，面板完成替换后会自动重启');
}
```

### 需要的测试

- 新建任务表单在后端提供 `default_version` 时使用后端值
- 编辑既有任务时**不覆盖**已存的 Python 版本（`task_form_page.dart:127, 263`）
- `update_target.update_manager == watchtower` 时更新按钮文案/提示随之变化
- `update_target` 字段缺失时渲染通用安全文案

> 这四条目前**都没有测试**（`test/` 只有一个空 smoke test）。第 0 期 R5 补测试时可优先考虑。

---

## 禁止

- 把后端已暴露的默认值写死在表单里
- 把不同的后端运行模式压成一句用户可见文案
- 在 UI 层直接 `as` 转换未经校验的 JSON
- 让 `dynamic` 从 `api_utils` 往上渗透到 widget 参数
