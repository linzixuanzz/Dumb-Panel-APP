# 开工基线（2026-09-01 主会话实测）

工具链：`$env:PATH = "D:\flutter-sdk\bin;" + $env:PATH`（junction，绕开 SDK 路径里的空格）

## `flutter analyze` → 7 issues / 0 warning / 0 error

```
info - use_build_context_synchronously - lib\features\notifications\views\notification_list_page.dart:692:40
info - use_build_context_synchronously - lib\features\openapi\views\open_api_page.dart:809:38
info - use_build_context_synchronously - lib\features\scripts\views\script_list_page.dart:2756:46
info - use_build_context_synchronously - lib\features\security\views\security_page.dart:872:38
info - library_private_types_in_public_api - lib\features\users\views\user_list_page.dart:74:14
info - library_private_types_in_public_api - lib\features\users\views\user_list_page.dart:86:32
info - use_build_context_synchronously - lib\features\users\views\user_list_page.dart:498:40
```

**改动后必须逐条比对这张清单本身，不是只比总数**（会漏掉「修好一个又新增一个」）。
其中 `script_list_page.dart:2756` 落在 issue #6 的主战场里，风险最高。

## `flutter test` → 291 例全过（exit 0）

## 版本

`pubspec.yaml: version: 1.3.3+23`（版本号只在 `chore(release):` 提交里动，功能提交不碰）
