# agent-3

## summary

脚本编辑器是一个**原生 Flutter TextField**（script_list_page.dart:2269），pubspec.yaml 里没有任何 code editor 包，所以行号栏和多段高亮都得自己造。(c)「点下一个不跳转」的根因已定位并可闭环解释：build() 里第 2136-2138 行每次重建都执行 `_contentController.text = state.content`，而 Flutter 的 `TextEditingController.set text` 会把 selection 重置为 `TextSelection.collapsed(offset: -1)`（editable_text.dart:276-282）；`_findInContent` 在第 2038 行自己 `setState` 触发了这次重建，于是刚设好的 selection 在同一帧被抹掉。下一次点「下一个」时 `selection.isValid == false`（isValid 要求 start/end ≥ 0，text.dart:2647），第 2010 行的 `start` 回落成 0，`indexOf` 永远返回第一个命中 —— 表现就是「不跳转」。同一个根因也让 (b) 的高亮消失：collapsed 的 range 在 `_TextHighlightPainter.paint` 里被直接 return（editable.dart:2905-2911）。(d) 的根因是搜索用了 `showModalBottomSheet`（第 2057 行，`isScrollControlled: true` + `autofocus: true`），modal 有遮罩、又被键盘顶高，且按钮不 pop，用户全程看不到编辑区。好消息是 (b)(e) 不必换包：`EditableTextState` 会调用 `widget.controller.buildTextSpan`（editable_text.dart:5956），自定义 TextEditingController 覆写它即可做「全部命中弱高亮 + 当前命中强高亮」。

## currentState

**编辑器控件**：`TextTextField`（script_list_page.dart:2269-2288），`readOnly: !_editing`、`expands: true`、`maxLines: null`、`style: TextStyle(fontSize: 13, fontFamily: 'monospace', height: 1.5)`、`decoration: InputDecoration(border: none, contentPadding: EdgeInsets.all(14))`，外面套 `TextSelectionTheme`（2263-2268）+ `AppCard`（2255-2262，padding 为 0，底色取用户在面板里配的 editor_background_color）。它自带 `scrollController: _contentScrollController`（2272）。pubspec.yaml:9-41 依赖里没有 code_text_field / re_editor / flutter_code_editor 之类，全 app 只有这一处 `expands: true` 的多行编辑器（另一处 env_list_page.dart:1866 是环境变量值编辑，跟搜索无关）。没有行号，没有语法高亮。

**搜索现状**：入口是 AppBar 上的放大镜（2152-2156）→ `_showFindSheet()`（2050-2111）→ `showModalBottomSheet`。状态只有两个字段：`_lastSearchQuery`（1764）和 `_searchHighlightActive`（1766），**没有**「命中列表 / 当前命中序号」这种真正的搜索游标 —— 游标是借用 `_contentController.selection` 临时存的（2005、2010、2017-2018）。匹配算法是双方 `toLowerCase()` 后 `indexOf` / `lastIndexOf`（2003-2024），即全文、大小写不敏感、单向逐个查找、到头回绕。命中后做四件事：设 selection（2032-2035）、requestFocus（2036）、`_scrollToMatch(index)`（2037）、`setState(_searchHighlightActive = true)` 并 2 秒后再 `setState` 关掉（2038-2043），最后弹一个「已定位到第 N 行」的 snackbar（2044-2046）。

**(c) 的根因（已闭环）**：`build()` 第 2136-2138 行

```dart
final state = ref.watch(scriptProvider);
if (!_editing && !state.isBinary) {
  _contentController.text = state.content;   // ← 每次重建都跑
}
```

Flutter 的 setter（`D:\flutter-nospace\packages\flutter\lib\src\widgets\editable_text.dart:276-282`）是：

```dart
set text(String newText) {
  value = value.copyWith(
    text: newText,
    selection: const TextSelection.collapsed(offset: -1),
    composing: TextRange.empty,
  );
}
```

文档注释（同文件 266-275 行）甚至明说「这个 setter 一般只用于测试，它会重置光标位置」「不应在 build / layout / paint 阶段设置」—— 这里两条都踩了。因为新旧 TextEditingValue 的 selection 不同，ValueNotifier 的相等短路救不了，赋值一定发生。

时序：点「下一个」→ `_findInContent` 设好 selection → 第 2038 行 `setState` → build → selection 被打回 collapsed(-1) → 高亮不画、游标丢失 → 再点「下一个」时 `sameQuery && selection.isValid` 为 false（`isValid => start >= 0 && end >= 0`，`sky_engine/lib/ui/text.dart:2647`）→ `start = 0` → 永远命中第一个。注意这条只在**查看模式**成立（`_editing` 默认 false，2762 行初值），进编辑模式后 `!_editing` 守卫挡住赋值，搜索反而能往下走 —— 这也解释了为什么 bug 看起来「有时好使」。

**次要缺陷（叠加在 c 上，即使修好根因也仍需处理）**：`_scrollToMatch`（1967-1988）用 `const lineHeight = 13 * 1.5` 硬编码行高（1974），且只数 `\n` 的个数（1973）。TextField 默认开软换行，逻辑行 ≠ 视觉行，长行一多滚动位置就系统性偏上；同时没算 `contentPadding` 的 14，也没跟 `MediaQuery.textScaler` 挂钩，系统字体缩放不是 1.0 时整体错位。

**(d) 的根因**：`showModalBottomSheet(isScrollControlled: true, showDragHandle: true, ...)`（2057-2060）。三件事叠加：① modal route 自带 scrim，整个编辑区被压暗且不可点；② `autofocus: true`（2076）拉起键盘，`bottomInset`（2062）把 sheet 再顶高一截，drag handle + 标题 + 输入框 + 一行按钮本身就 200px 上下，加键盘后手机上轻松吃掉 40%~55% 屏高；③ 上一个/下一个按钮（2088-2103）**不 pop sheet**，整个 `await` 期间 sheet 一直挡着，用户根本看不到跳转结果，"已定位到第 N 行" 的 snackbar 也被压在下面。

**(b) 的现状**：靠 `TextSelectionThemeData.selectionColor` 在命中时临时换成 `AppColors.amber500.withAlpha(120)`（2265-2267），本质是**把原生选区染成琥珀色**，不是真正的搜索高亮。原生 TextField 只有一个 selection painter，所以天然只能画一段。加上前述 selection 被 build 抹掉，实际上连这一段也画不出来。

## keyFiles

- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :2269-2288 — 脚本编辑器本体：原生 TextField，expands/maxLines:null，monospace 13px/height 1.5，contentPadding 14，自带 _contentScrollController。没有行号、没有语法高亮。
- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :2133-2146 — ★(c) 的根因所在：build() 第 2136-2138 行在查看模式下每帧执行 `_contentController.text = state.content`，把 selection 重置成 collapsed(-1)。
- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :1990-2048 — _findInContent：大小写不敏感 indexOf/lastIndexOf 全文查找，用 controller.selection 当搜索游标（2005/2010/2017），命中后 setState 触发重建→自毁。
- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :1967-1988 — _scrollToMatch：硬编码 lineHeight = 13*1.5、只数 \n、忽略软换行/contentPadding/textScaler，定位系统性偏差。
- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :2050-2111 — ★(d) 的根因：搜索 UI = showModalBottomSheet(isScrollControlled:true, autofocus:true)，带遮罩、被键盘顶高、按钮不 pop。
- `D:\GitHub\Dumb Panel\android-app\lib\features\scripts\views\script_list_page.dart` :1758-1766 — _ScriptViewPageState 的搜索相关状态：只有 _lastSearchQuery 和 _searchHighlightActive，缺「命中列表 + 当前序号」。_editing 默认 false（查看模式=踩坑路径）。
- `D:\GitHub\Dumb Panel\android-app\pubspec.yaml` :9-41 — 依赖清单：确认零 code editor 包（无 re_editor / code_text_field / flutter_code_editor），行号与高亮必须自建或新引依赖。
- `D:\flutter-nospace\packages\flutter\lib\src\widgets\editable_text.dart` :263-282 — 证据：TextEditingController.set text 强制 selection = TextSelection.collapsed(-1)，文档明确警告不要在 build 阶段用。
- `D:\flutter-nospace\packages\flutter\lib\src\widgets\editable_text.dart` :295-303, 5955-5960 — 证据：controller.buildTextSpan 是官方可 override 钩子，EditableTextState 在 5956 行调用它 → 多段高亮不换包也能做。
- `D:\flutter-nospace\packages\flutter\lib\src\rendering\editable.dart` :2905-2911, 386-388 — 证据：_TextHighlightPainter 只画 highlightedRange 这一段且 collapsed 直接 return；painter 不看焦点（所以 readOnly 无焦点也能画高亮，但只能画一段）。
- `D:\GitHub\呆呆面板开发\web\src\components\CodeEditor.vue` :176, 199-200, 116/146-148 — web 端参考：lineNumbers() 行号栏、search({top:true}) 顶部搜索面板、highlightSelectionMatches()、wordWrap prop 默认 'on'。
- `D:\GitHub\呆呆面板开发\web\src\utils\codeEditor.ts` :186-256 — web 端视觉 token：行号色 dark #6b7280 / light #94a3b8；全部命中 rgba(234,179,8,.28/.35)；当前命中 rgba(234,179,8,.5/.6)；选区 #134e4acc / #bfdbfe。
- `D:\GitHub\Dumb Panel\android-app\lib\core\theme\app_theme.dart` :19-20, 38 — APP 侧现成 token：slate400=#94A3B8（正好等于 web 浅色行号色）、slate500=#64748B、amber500=#F59E0B（≠ web 用的 #EAB308，对齐时要注意）。

## detailedFindings

## 1. 编辑器控件：原生 TextField，无任何 code editor 包

`pubspec.yaml:9-41` 的依赖只有 riverpod / dio / go_router / fl_chart / webview_flutter 等，**没有** `code_text_field`、`re_editor`、`flutter_code_editor`、`highlight`、`flutter_highlight`。

编辑器本体在 `script_list_page.dart:2269-2288`：

```dart
child: TextField(
  controller: _contentController,
  focusNode: _contentFocusNode,
  scrollController: _contentScrollController,
  readOnly: !_editing,
  expands: true,
  maxLines: null,
  style: TextStyle(
    fontSize: 13, fontFamily: 'monospace', height: 1.5, color: editorForeground,
  ),
  cursorColor: editorForeground,
  selectionHeightStyle: BoxHeightStyle.max,
  decoration: const InputDecoration(
    border: InputBorder.none,
    contentPadding: EdgeInsets.all(14),
  ),
),
```

后果：
- **行号**：TextField 完全没有 gutter 概念，必须自绘或换包。
- **多段高亮**：RenderEditable 只有一个 `_selectionPainter`（`editable.dart:386-388`、`1011-1013`、`1061`），一次只能画一段 range，`paint` 里还对 collapsed 直接 return（`editable.dart:2905-2911`）。所以「全部命中弱高亮」用 selection 这条路**走不通**。
- 但 `TextEditingController.buildTextSpan` 这条口子是开的（下文第 5 点）。

全 app 仅此一处代码编辑器：grep `expands: true` 只有两处，另一处 `env_list_page.dart:1866` 是环境变量值的全屏编辑框，无搜索需求。`_ScriptDebugRunSheet`（2569+）里是 `RichText + AnsiTextParser`（2805-2806）的日志视图，不是编辑器。

## 2. 搜索完整实现与 (c) 的根因

### 入口与状态

- AppBar 放大镜 → `_showFindSheet`：`script_list_page.dart:2152-2156`
- 状态字段仅两个：`_lastSearchQuery`（1764）、`_searchHighlightActive`（1766）。**没有** matches 列表、没有 currentIndex。

### 匹配算法（1990-2024）

全文、大小写不敏感、单次线性查找、到头回绕：

```dart
final normalizedContent = content.toLowerCase();
final normalizedQuery = query.toLowerCase();
final selection = _contentController.selection;
final sameQuery = _lastSearchQuery == query;
int index = -1;

if (forward) {
  final start = sameQuery && selection.isValid ? selection.end : 0;   // ← 2010
  index = normalizedContent.indexOf(normalizedQuery, start);
  if (index == -1 && start > 0) {
    index = normalizedContent.indexOf(normalizedQuery);               // 回绕
  }
} else {
  final fallbackStart = normalizedContent.length - 1;
  final start = sameQuery && selection.isValid
      ? (selection.start - 1).clamp(0, fallbackStart)                 // ← 2017-2018
      : fallbackStart;
  index = normalizedContent.lastIndexOf(normalizedQuery, start);
  ...
}
```

关键：**搜索游标被寄存在 `_contentController.selection` 上**（2010、2017），没有独立变量。

### 「下一个」的 onPressed（2096-2103）

```dart
child: FilledButton.icon(
  onPressed: () => _findInContent(controller.text, forward: true),
  icon: const Icon(Icons.keyboard_arrow_down, size: 18),
  label: const Text('下一个'),
),
```

只调 `_findInContent`，不 pop sheet。

### ★ 根因：build 里的 `.text =` 每帧抹掉 selection

`script_list_page.dart:2133-2138`：

```dart
@override
Widget build(BuildContext context) {
  final state = ref.watch(scriptProvider);
  if (!_editing && !state.isBinary) {
    _contentController.text = state.content;        // ← 2137
  }
```

Flutter SDK（`D:\flutter-nospace\packages\flutter\lib\src\widgets\editable_text.dart:276-282`）：

```dart
set text(String newText) {
  value = value.copyWith(
    text: newText,
    selection: const TextSelection.collapsed(offset: -1),
    composing: TextRange.empty,
  );
}
```

同文件 266-275 的文档注释：*"This setter is typically only used in tests, as it resets the cursor position... this value should only be set between frames, e.g. in response to user actions, not during the build, layout, or paint phases."* —— 两条禁忌全踩。且因为新旧 value 的 selection 不同，`ValueNotifier` 的 `if (_value == newValue) return` 短路不生效，赋值必然发生。

**完整时序（查看模式，`_editing` 默认 false）**：

1. 点「下一个」→ `_findInContent(forward: true)`
2. 读 `selection` = collapsed(-1)（上一帧被抹的）→ `isValid` 为 false（`sky_engine/lib/ui/text.dart:2647`：`bool get isValid => start >= 0 && end >= 0;`，这里 start = -1）
3. → `start = 0` → `indexOf(query, 0)` → **永远是第 1 个命中**
4. 2032-2035 设好 selection；2037 `_scrollToMatch(index)` 注册 post-frame 回调；2038 `setState(() => _searchHighlightActive = true)`
5. 重建 → 2137 行 `.text =` → selection 打回 collapsed(-1)
6. post-frame 回调执行 `animateTo`（用的是闭包里的 `index`，所以第一次确实会滚到第 1 个命中）
7. 2 秒后 `Future.delayed` 里再 `setState`（2039-2043）→ 又一次重建 → 又一次抹 selection
8. 再点「下一个」→ 回到步骤 2 → **同一个位置，视觉上完全不动**

这同时解释了 (b)：第 5 步之后 `highlightedRange` 是 collapsed，`_TextHighlightPainter.paint`（`editable.dart:2905-2911`）里

```dart
final TextRange? range = highlightedRange;
final Color? color = highlightColor;
if (range == null || color == null || range.isCollapsed) {
  return;                                    // ← 什么都不画
}
```

直接 return，琥珀色高亮**一帧都留不住**。

**边界条件**：进编辑模式（`_editing == true`）后 `!_editing` 守卫挡住赋值，selection 保住，搜索能正常往下跳。所以这个 bug 只在**默认的查看模式**复现 —— 建议按这个条件去复现验证。

### 次要缺陷：`_scrollToMatch` 的偏移量算错（1967-1988）

```dart
final prefix = _contentController.text.substring(0, index);
final lineCount = '\n'.allMatches(prefix).length;      // 只数逻辑换行
const lineHeight = 13 * 1.5;                           // 硬编码 19.5
final rawOffset = (lineCount * lineHeight) - (lineHeight * 2);
```

三个问题：① TextField 默认软换行，一条长行占多个视觉行，`lineCount` 系统性偏小 → 滚不到位；② 没算 `contentPadding` 的 top 14；③ 没跟 `MediaQuery.textScaler` 挂钩，系统字体缩放 ≠ 1.0 时整体错位。即使把根因修了，长行脚本上依然会「跳偏」。

## 3. 搜索 UI 形态与「占屏幕过大」

`script_list_page.dart:2057-2110`：

```dart
await showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,      // ← 上限放开到全屏
  showDragHandle: true,          // ← 顶部再加一条 handle 区
  builder: (sheetContext) {
    final bottomInset = MediaQuery.of(sheetContext).viewInsets.bottom;   // ← 键盘高度
    return Padding(
      padding: EdgeInsets.fromLTRB(20, 0, 20, bottomInset + 20),
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('查找代码', style: TextStyle(fontSize: 18, ...)),      // 标题
        const SizedBox(height: 12),
        TextField(controller: controller, autofocus: true, ...),         // ← 2076 拉键盘
        const SizedBox(height: 12),
        Row(children: [上一个, 下一个]),
      ]),
    );
  },
);
```

「占比过大 + 遮挡」是三件事叠出来的：

1. **modal 遮罩**：`showModalBottomSheet` 是 modal route，整块编辑区被 scrim 压暗且不可交互，视觉上等于全屏被占。
2. **键盘 + 内容高度**：`autofocus: true` 立刻拉起输入法，`bottomInset + 20` 把 sheet 内容再抬高一个键盘的量；drag handle（约 kMinInteractiveDimension）+ 18px 标题 + 输入框 + 一行按钮 + 三个 12px 间距，本体 200px 上下，加键盘后手机竖屏轻松吃 40%~55%。
3. **按钮不关闭 sheet**（2088-2103）：整个 `await` 期间 sheet 常驻，用户按「下一个」时看不到编辑器，跳没跳都不知道；`_showMessage('已定位到第 N 行')`（2046）的 snackbar 也被压在 sheet 下面/边缘。

所以用户说的 (d)，本质诉求和 (c) 是同一件事的两面：**要一个非 modal、常驻、不遮编辑区的 find bar，边搜边看**。

## 4. 行号：现状与实现路径

现状：**完全没有**。唯一和行号沾边的是 `_findInContent` 结尾算出来报个 snackbar（2044-2046）：

```dart
final prefix = _contentController.text.substring(0, index);
final lineNumber = '\n'.allMatches(prefix).length + 1;
_showMessage('已定位到第 $lineNumber 行');
```

### 要加行号会踩的坑

| 坑 | 具体表现 | 证据 |
| --- | --- | --- |
| **软换行** | TextField 没有 `softWrap` 参数，`maxLines: null` + 有界宽度 = 强制换行。逻辑行 ≠ 视觉行，等间距 gutter 在第一条长行之后就全错位 | 2274-2275 |
| **滚动同步** | gutter 要跟 `_contentScrollController`（2272）同步。TextField 内部 Scrollable 与外部 gutter 是两个 viewport | 2272 |
| **度量必须完全一致** | fontSize 13 / height 1.5 / fontFamily 'monospace' / contentPadding.top 14 / `MediaQuery.textScaler`。当前 `_scrollToMatch` 已经因为硬编码 `13*1.5` 而错（1974），gutter 会犯同样的错 | 1974、2276-2286 |
| **'monospace' 的实际字体不确定** | Android 上 'monospace' 解析成什么（Droid Sans Mono / Roboto Mono）随 ROM 变，字宽/行高有差异。gutter 不能靠「我算一遍」，得靠 TextPainter 用同一份 style 实测 | 2278 |

### 可行路径（按代价排序）

**路径 A（推荐，改动最小）：关掉软换行 + 等间距自绘 gutter**
- 把 TextField 包进横向 `SingleChildScrollView`，里面给一个足够宽的 `SizedBox`，让文本不换行 → 逻辑行 = 视觉行，gutter 可以直接按 `i * lineHeight` 摆。
- 顺带把 `_scrollToMatch` 的偏移量算准（同一个前提）。
- gutter 用 `AnimatedBuilder(animation: _contentScrollController, builder: ...)` + `Transform.translate(offset: Offset(0, -offset))`，或 `SingleChildScrollView(physics: NeverScrollableScrollPhysics())` 里跟随。
- 语义上和 web 端的 `wordWrap` prop 对齐（`CodeEditor.vue:116, 146-148`，web 默认 `'on'`），可以给用户一个开关。
- 代价：横向滚动是行为变更，长行需要左右拖，手机上体验要实测。

**路径 B：保留换行 + TextPainter 实测每行高度**
- 用与 TextField 完全相同的 `TextStyle` / `StrutStyle` / `textScaler` / 可用宽度（= 卡片宽 - 14*2 - gutter 宽）建 `TextPainter`，`layout()` 后 `computeLineMetrics()` 拿到每条视觉行的 baseline/height，再把逻辑行号摆到对应 y。
- 视觉正确，但每次内容变化都要重排一遍，大文件性能要测；且宽度依赖 gutter 宽，gutter 宽又依赖最大行号位数，有一次循环依赖要拆开（先按最大行数估位数）。

**路径 C：换 code editor 包（re_editor / flutter_code_editor / code_text_field）**
- 一次拿到行号 + 搜索 + 语法高亮 + 折叠。
- 但要评估：包体积、对 Dart 3.11 / Flutter 3.11 的兼容、以及**会不会丢掉原生长按选择 / 系统文本菜单 / 选择手柄** —— 这正是面板 web 端从 Monaco 换 CodeMirror 时刻意保住的东西（`CodeEditor.vue:91-98` 有大段注释专门讲这个取舍，还刻意不启用 `drawSelection`）。自绘型编辑器在移动端最容易丢的就是这三条，APP 端更敏感。建议先确认候选包在真机上的长按选择表现再决定。

## 5. 高亮命中：能不能做「全部弱高亮 + 当前强高亮」

**当前做法**：靠 `TextSelectionThemeData.selectionColor` 临时染色（2263-2268）：

```dart
child: TextSelectionTheme(
  data: TextSelectionThemeData(
    selectionColor: _searchHighlightActive
        ? AppColors.amber500.withAlpha(120)
        : AppColors.primary.withAlpha(60),
  ),
```

即「把原生选区染成琥珀色 2 秒」，不是真高亮。

**原生 selection 路走不通**：RenderEditable 只挂一个 `_selectionPainter`（`editable.dart:386-388`），`selection` setter 直接把它当唯一 range（`editable.dart:1061`），一次只能画一段。

**但换包不是必需的** —— `TextEditingController.buildTextSpan` 是官方 override 钩子：

`editable_text.dart:295-303`：
```dart
/// Builds [TextSpan] from current editing value.
///
/// By default makes text in composing range appear as underlined. Descendants
/// can override this method to customize appearance of text.
TextSpan buildTextSpan({
  required BuildContext context,
  TextStyle? style,
  required bool withComposing,
}) {
```

`editable_text.dart:5955-5960`（EditableTextState 确实会调它）：
```dart
// Read only mode should not paint text composing.
return widget.controller.buildTextSpan(
  context: context,
  style: _style,
  withComposing: withComposing,
);
```

所以自定义一个 `TextEditingController` 子类，按「命中区间」切片返回带 `backgroundColor` 的 TextSpan 树，就能在**现有 TextField 里**同时画出全部命中（弱）和当前命中（强），而且完全不影响原生选区、长按菜单、选择手柄。这条路同时也是**日后上语法高亮的同一个口子**。

需要注意的代价：每次 setState 会重建整棵 TextSpan 树，超大脚本要设匹配数上限（例如只高亮前 500 个命中）或只对可视区做切片。

**焦点无关**：`_TextHighlightPainter` 的 `shouldRepaint` / `paint` 只看 `highlightColor != null && highlightedRange != null`（`editable.dart:2909、2940`），不看焦点；`selectionColor` 传给 `_Editable` 时也没有 focus 门槛（`editable_text.dart:5838-5842`）。所以 readOnly + 无焦点状态下高亮照样能画，不需要为了显示高亮去 `requestFocus`（现在 2036 行那句 requestFocus 在 sheet 打开时也基本没实际作用，见 openQuestions）。

## 6. 面板 web 端（CodeMirror 6）的交互与视觉约定

`web/package.json:13-29` 引了整套 CM6，编辑器在 `web/src/components/CodeEditor.vue`。

**行号**（`CodeEditor.vue:176-192`）：
```dart
lineNumbers(),
highlightActiveLineGutter(),
highlightActiveLine(),
...
foldGutter(),      // 注释里强调必须排在 lineNumbers() 之后才渲染在行号右侧
```

**搜索**（`CodeEditor.vue:199-208`）：
```dart
search({ top: true }),          // ← 搜索面板固定在编辑器顶部，不是弹窗、不遮内容
highlightSelectionMatches(),    // 选中一个词，同词全部弱高亮
keymap.of([... ...searchKeymap, ...]),
```

`search({ top: true })` 的形态是「**贴在编辑器内容区正上方的一条常驻横条**」（CM6 panel，含输入框 / next / previous / all / replace），不是浮在右上角的悬浮框 —— 用户说的「像编辑器那样在编辑框外右上角显示」更接近 VS Code 的浮动 find widget。APP 端两种都比现在的 modal bottom sheet 好，建议按 web 的「顶部常驻条」做主形态（更好点、不遮字），如果空间紧张再考虑 `Positioned(top, right)` 的紧凑浮层。

**视觉 token**（`web/src/utils/codeEditor.ts:186-256`）：

| 用途 | 深色 | 浅色 | APP 侧对应 |
| --- | --- | --- | --- |
| 行号色 gutter | `#6b7280` | `#94a3b8` | `AppColors.slate400 = #94A3B8`（app_theme.dart:19）浅色完全一致；深色可用 `#6B7280` 或 slate500 `#64748B` |
| 行号栏底色 | 同编辑器底色，`border: none` | 同左 | 直接复用 `editorBackground`（2140-2142） |
| 当前行 | `rgba(255,255,255,0.05)` | `rgba(15,23,42,0.04)` | — |
| **全部命中** `.cm-searchMatch` | `rgba(234,179,8,0.28)` | `rgba(234,179,8,0.35)` | 注意 web 用的是 `#EAB308`（Tailwind yellow-500），而 `AppColors.amber500 = #F59E0B`（app_theme.dart:38，Tailwind amber-500），**不是同一个黄**；要严格对齐得显式写 `Color(0xFFEAB308)` |
| **当前命中** `.cm-searchMatch-selected` | `rgba(234,179,8,0.5)` | `rgba(234,179,8,0.6)` | 同上 |
| 同词弱高亮 `.cm-selectionMatch` | `rgba(52,211,153,0.18)` | `rgba(37,99,235,0.12)` | 可选，APP 端优先级低 |
| 选区 | `#134e4acc` | `#bfdbfe` | 当前 APP 用 `AppColors.primary.withAlpha(60)`（2267） |
| 搜索面板底色 | `var(--el-bg-color)` | 同 | 注释（codeEditor.ts:257-258）明说**面板不跟编辑器底色走**，因为编辑器底色是用户可配项，面板必须始终可读 —— APP 的 find bar 应照抄这条：用 Material surface 色，不用 `editorBackground` |

字体：web `lineHeight: '1.5'`（codeEditor.ts:215）与 APP 的 `height: 1.5`（2279）一致；web 移动端把编辑器字号提到 16px（CodeEditor.vue:386-389，为绕开 iOS Safari 自动放大），APP 是 13px，这条不用跟。

## proposedFix

按「先修 bug，再补能力，最后改形态」的顺序，四步都落在 `script_list_page.dart` 的 `_ScriptViewPageState`（1758-2296）内，不需要动 provider、不需要动其他页面。

---

### Step 1（必做，修 c 和 b 的共同根因）：把 controller 的赋值移出 build，并给搜索一个独立游标

**1a. 删掉 build 里的每帧赋值**（2136-2138）。改成只在内容真正变化时同步，且不经过会重置 selection 的 `.text` setter：

```dart
// build() 里改成：
if (!_editing && !state.isBinary && _contentController.text != state.content) {
  _contentController.value = _contentController.value.copyWith(
    text: state.content,
    selection: const TextSelection.collapsed(offset: -1),
    composing: TextRange.empty,
  );
}
```

更稳妥的写法是彻底不在 build 里改 controller —— 用 `ref.listen<ScriptState>(scriptProvider, (prev, next) { ... })` 在 `initState` 里注册，或在 `loadContent` / `rollbackVersion` 的 await 之后显式赋值（`_format` 在 1827 行已经是这么干的）。注意 `_save()`（1812）把 `_editing` 设回 false 后仍要能看到新内容，`saveContent`（260 行）已经把 `state.content` 更新过了，所以加了 `!=` 判断后这条路径也不会退化。

**1b. 搜索游标不要再寄存在 selection 上**。加两个字段（放在 1764-1766 旁边）：

```dart
List<int> _matchOffsets = const [];   // 当前 query 在全文里的全部命中起点
int _currentMatchIndex = -1;          // 当前停在第几个
String _matchQuery = '';              // _matchOffsets 对应的 query（含大小写原文）
```

`_findInContent` 改成：query 变了就重算 `_matchOffsets`（一次 while + indexOf 扫全文），然后 `_currentMatchIndex = (_currentMatchIndex + 1) % len`（forward）或 `(- 1 + len) % len`（backward）。这样即使 selection 被 IME、焦点切换、内容刷新改写，「下一个」也一定往下走。顺带能免费拿到 `3 / 17` 这种计数展示（web 端 CM6 面板也有，是用户定位的关键反馈）。

**1c. 修 `_scrollToMatch`**（1967-1988）：行高不要硬编码 `13 * 1.5`。要么在 Step 3 关掉软换行后用 `TextPainter` 实测一次单行高度并乘 `MediaQuery.textScalerOf(context)`，要么直接用 `TextPainter.getOffsetForCaret(TextPosition(offset: index), Rect.zero).dy` 拿真实 y（这条对换行也成立），再减去 `contentPadding.top`（14）和两行的余量。

**验证点**：改完后在**查看模式**（不点编辑按钮）连点「下一个」，命中应逐个前移并在到底后回绕。

---

### Step 2（做 b + e）：自定义 TextEditingController 做双档高亮

新建一个私有类，放在 `_ScriptViewPageState` 附近：

```dart
class _ScriptEditingController extends TextEditingController {
  List<int> matches = const [];
  int current = -1;
  int queryLength = 0;

  static const _all = Color(0x59EAB308);      // rgba(234,179,8,0.35) 对齐 web 浅色
  static const _cur = Color(0x99EAB308);      // rgba(234,179,8,0.6)

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    if (matches.isEmpty || queryLength <= 0) {
      return TextSpan(style: style, text: text);
    }
    final spans = <TextSpan>[];
    var cursor = 0;
    for (var i = 0; i < matches.length; i++) {
      final s = matches[i];
      final e = s + queryLength;
      if (s > cursor) spans.add(TextSpan(text: text.substring(cursor, s)));
      spans.add(TextSpan(
        text: text.substring(s, e),
        style: TextStyle(backgroundColor: i == current ? _cur : _all),
      ));
      cursor = e;
    }
    if (cursor < text.length) spans.add(TextSpan(text: text.substring(cursor)));
    return TextSpan(style: style, children: spans);
  }
}
```

把 1759 行的 `late final TextEditingController _contentController` 换成这个类型，1771 行的 `= TextEditingController()` 换掉；`_findInContent` 更新 `matches / current / queryLength` 后 `setState` 即可。

依据：`editable_text.dart:5955-5960` 确实调 `widget.controller.buildTextSpan`，`editable_text.dart:295-303` 是官方开放的 override 点。这样做**完全不动 TextField**，原生长按选择 / 系统菜单 / 选择手柄全部保留（对齐 web 端 `CodeEditor.vue:91-98` 那条取舍）。

同时可以把 2263-2268 那个 2 秒琥珀选区的 hack 删掉（`_searchHighlightActive`、1766 行的字段、2039-2043 的 `Future.delayed` 一并清掉），选区颜色恢复成常驻的 `AppColors.primary.withAlpha(60)`。

**性能护栏**：`matches` 上限建议 500~1000，超过就只高亮前 N 个并在 find bar 上标 `500+`；否则超大脚本每次 setState 重建上千个 TextSpan 会掉帧。

---

### Step 3（做 a）：行号 gutter

推荐 **路径 A**（配合 Step 1c 一起做，两者共享「关掉软换行」这个前提）：

1. 编辑区结构改成 `Row(children: [_LineNumberGutter(...), Expanded(child: 横向可滚的 TextField)])`。
2. 关软换行：TextField 外面套 `SingleChildScrollView(scrollDirection: Axis.horizontal, child: SizedBox(width: max(屏宽, 最长行宽), child: TextField(...)))`。最长行宽用 `TextPainter` 对最长的那条逻辑行 layout 一次拿到。
3. gutter 与内容同步滚动：`AnimatedBuilder(animation: _contentScrollController, builder: (_, __) => ...)` 里用 `Transform.translate(offset: Offset(0, -_contentScrollController.offset))`，或包一层 `ClipRect`。
4. gutter 每行高度必须用与 TextField 完全相同的 `TextStyle(fontSize: 13, fontFamily: 'monospace', height: 1.5)` 加上 `MediaQuery.textScalerOf(context)` 计算，且顶部要留 `contentPadding.top = 14` 的偏移。
5. 配色：`color: isDark ? const Color(0xFF6B7280) : AppColors.slate400`，底色 = `editorBackground`，`border: none`（对齐 `codeEditor.ts:225-229`）。gutter 宽度按 `'$totalLines'.length` 动态算，右侧留 8~10 的 padding。

若产品上不接受横向滚动，走 **路径 B**：保留换行，用 `TextPainter.computeLineMetrics()` 按真实视觉行摆号（逻辑行的第一条视觉行画号，续行留空，和 VS Code 一致）。代价是每次内容变化重排。

---

### Step 4（做 d）：把 modal bottom sheet 换成常驻 find bar

删掉 `_showFindSheet`（2050-2111）整个方法，改成：

- 新增 `bool _findBarVisible = false;` + `final _findController = TextEditingController();`（复用 `_lastSearchQuery` 做初值）。
- AppBar 的放大镜（2152-2156）改成 `setState(() => _findBarVisible = !_findBarVisible)`。
- 在编辑器 `AppCard`（2255）外层套 `Stack`，加一个 `Positioned(top: 8, right: 8, left: 48)` 的紧凑条；或者更贴近 web 的做法 —— 在 2254 的 `Expanded` 之上、路径行（2243-2253）之下插一条 44~48px 高的 bar（对齐 `CodeEditor.vue:199` 的 `search({ top: true })`）。
- bar 内容：输入框（`textInputAction: TextInputAction.search`，`onChanged` 实时重算 matches）+ `${current + 1}/${matches.length}` 计数 + ↑ / ↓ / ✕ 三个 `IconButton`，高度压到 40 以内。
- bar 的配色**不要**用 `editorBackground`，用 `Theme.of(context).colorScheme.surface` —— 编辑器底色是用户可配项，跟着走会不可读（这条 web 端有明确注释，`codeEditor.ts:257-258`）。
- 删掉 2044-2046 的 `_showMessage('已定位到第 N 行')`，位置反馈由 bar 上的计数 + 行号栏承担。
- 因为不再是 modal route，`_contentFocusNode.requestFocus()`（2036）可以按需保留（编辑模式下希望光标落回编辑器）或去掉（查看模式下没必要拉键盘）。

## risks

**Step 1 的回归面**：`_contentController.text = state.content` 是「provider 内容 → 编辑器」的唯一同步点，涉及 4 条路径 —— 首次加载（`loadContent`，215-229）、保存后（`saveContent` 更新 state.content，260）、格式化（`_format` 直接写 controller.text，1827）、版本回滚（`rollbackVersion` 走 provider，2362-2364）。加 `!=` 判断后理论上都还成立，但**回滚**这条要重点回归：回滚后 `_editing` 可能还是 false，内容确实变了，`!=` 应该能命中；如果回滚后 provider 没刷新 content，编辑器会停在旧内容。这四条都要实测。

**在 build 里调 controller setter 本身就是隐患**：`.text =` 会 `notifyListeners()`，`EditableTextState` 收到后 `setState` → 相当于在父级 build 期间给子树 `markNeedsBuild`。现在没崩是因为 TextField 在树里排在赋值之后，属于「碰巧安全」。改掉是净收益，但如果只做半截（比如保留赋值只改 selection），这个隐患还在。

**Step 2 的性能**：自定义 `buildTextSpan` 会在每次 setState 时重建整棵 span 树，命中数没上限的话大脚本（几千行、上百命中）会明显掉帧。必须设匹配数上限。另外 `TextSpan.backgroundColor` 是按字形画背景，和 `selectionHeightStyle: BoxHeightStyle.max`（2283）画出来的选区形状**不完全一致**（高亮块会略矮），视觉上要接受这个差异，或者把 `BoxHeightStyle` 也调一下。

**Step 3 关软换行是行为变更**：现在长行是自动折行的，改成横向滚动后用户要左右拖。这会改变所有人的阅读习惯，属于产品决策而非纯技术修复，建议要么给开关（对齐 web 的 `wordWrap` prop），要么直接走成本更高的路径 B。

**gutter 对齐的设备差异**：`fontFamily: 'monospace'`（2278）在不同 Android ROM 上解析到的实际字体不同，行高/基线可能有细微差异。gutter 的行高绝不能自己算一个常数，必须用 `TextPainter` 用同一份 `TextStyle` + `StrutStyle` + `textScaler` 实测，否则会出现「文件越长，行号偏得越多」的累积误差 —— 这正是现在 `_scrollToMatch` 硬编码 `13*1.5`（1974）已经在犯的错。

**系统字体缩放**：目前代码任何地方都没考虑 `MediaQuery.textScaler`。用户把系统字体调大后，行号栏和滚动定位会同时偏。这是必须一起修的，否则加了行号反而更容易被发现错位。

**颜色对不齐**：`AppColors.amber500 = #F59E0B`（app_theme.dart:38）和 web 用的 `#EAB308`（codeEditor.ts:251-255）是两个不同的黄。直接复用 `AppColors.amber500` 会和 web 端观感不一致；显式写 `#EAB308` 又会引入一个游离于 design token 之外的硬编码色。建议在 `app_theme.dart` 里补一个 `searchMatch` / `searchMatchCurrent` 语义 token，别在页面里裸写颜色。

**find bar 与键盘的空间竞争**：改成常驻 bar 后，编辑模式下键盘一起弹出来时，可用编辑区高度会被 bar + 键盘双重挤压。bar 高度务必压到 40~48，且要在真机上量一遍竖屏可视行数。

**换 code editor 包（路径 C）的最大风险**：可能丢掉移动端原生长按选择 / 系统文本菜单 / 选择手柄 —— 面板 web 端从 Monaco 换到 CodeMirror 就是为了这三条（`CodeEditor.vue:91-98`）。APP 端如果为了行号引入一个自绘型编辑器，等于把 web 端刚踩完的坑再踩一遍。选包前必须在真机上先验这三条。

## openQuestions

- `_contentFocusNode.requestFocus()`（script_list_page.dart:2036）在 modal bottom sheet 打开期间的确切行为没有实测。我的推断是：被 modal 覆盖的路由其 FocusScope 不是当前 focused scope，所以这次 requestFocus 只是把该节点标记为「该 scope 恢复时的首选子节点」，不会立刻抢走 sheet 里 TextField（autofocus: true，2076）的焦点，也不会立刻弹编辑器的键盘。但这条是从 Flutter 焦点模型推的，没有真机验证。改成常驻 find bar 后这个问题自然消失，但如果决定保留 sheet 形态，需要实测确认。
- 查看模式下 TextField 是 `readOnly: !_editing`（2273）。readOnly + 有焦点时，Android 上会不会弹出选择手柄和「复制/全选」浮动工具栏？如果会，现在这个 requestFocus 在 sheet 关闭后可能造成一个用户没预期的工具栏。需要真机确认。
- 面板服务端对脚本文件大小有没有上限？这直接决定 Step 2 的 TextSpan 切片和 Step 3 路径 B 的 TextPainter 重排会不会成为性能瓶颈，以及匹配数上限该设多少。本次只读调查没查 server 侧的 scriptsContent 接口实现。
- 产品上是否接受「关掉软换行、改横向滚动」（Step 3 路径 A 的前提）？还是必须保留自动折行、走成本更高的路径 B？web 端 CodeEditor 有 wordWrap prop 且默认 'on'（CodeEditor.vue:116, 146-148），APP 端是否要跟着做成用户可切换的设置项？
- 是否允许为此引入第三方 code editor 依赖？目前 pubspec 零编辑器依赖，Step 1/2/4 全部可以零新依赖完成，Step 3 也能自建。但如果顺带要做语法高亮（web 端已有，见 codeEditor.ts:39-46 的九种语言），自建的成本会陡增，那时换包可能更划算。
- 用户 (d) 里说的「编辑框外右上角」更像 VS Code 的浮动 find widget，而 web 端 CM6 用的是 `search({ top: true })` 的顶部全宽横条（CodeEditor.vue:199）。两者形态不同，需要确认 APP 端对齐哪一个 —— 我倾向顶部横条（与面板一致、不遮字、手指够得着），但这是产品口味题。
- 搜索是否需要补「区分大小写 / 全词匹配 / 正则」开关？现在是写死的大小写不敏感 indexOf（2003-2004），web 端 CM6 的 search panel 自带这些选项。issue #6 原文没提，属于是否顺带对齐的范围题。