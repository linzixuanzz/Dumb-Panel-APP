import 'package:daidai_app/core/network/api_endpoints.dart';
import 'package:daidai_app/core/network/dio_client.dart';
import 'package:daidai_app/features/scripts/views/script_list_page.dart';
import 'package:daidai_app/features/scripts/widgets/script_code_editor.dart';
import 'package:daidai_app/features/system/views/config_script_page.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:re_editor/re_editor.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../support/fake_http_adapter.dart';

/// APP #25：长脚本编辑卡顿，编辑器从「装着全文的 TextField」换成按行渲染的 re_editor。
///
/// 钉住的事：
/// 1. 5000 行（约 150KB）的脚本能加载，而且只排版视口附近的几十行（卡顿的根因就是整篇重排）；
/// 2. 原来行号栏的行为：软换行续行不编号、中文行 / 空行一行一号、空文件也有第 1 行、
///    栏宽最少按两位算（这几条原来由 script_line_number_gutter_test 钉着，那个组件已删）；
/// 3. 只读不能改，选择菜单是中文、只读时只有「复制 / 全选」，全选后能复制 / 粘贴替换 / 删除整篇；
/// 4. 中文输入法组合输入期间不丢字、不重复上屏；
/// 5. 两个页面都用上了新组件：脚本页编辑后保存发出去的是编辑器里的全文，查找计数与跳转不退化。

/// 造一份 [lines] 行的 JS，结构与真实长脚本相近：注释行（含中文）、普通语句、偶尔一条长行。
String _buildJs(int lines) {
  final out = <String>[];
  for (var i = 0; i < lines; i++) {
    if (i % 10 == 0) {
      out.add('// 第 $i 行：中文注释说明一下这一段在做什么');
    } else if (i % 40 == 7) {
      out.add(
        '  const longLine$i = [${List.generate(12, (j) => '"item$j"').join(', ')}];',
      );
    } else {
      out.add('  const v$i = fn($i, "a");');
    }
  }
  return out.join('\n');
}

class _Harness {
  _Harness(String text, {this.readOnly = false})
    : controller = CodeLineEditingController.fromText(text);

  final CodeLineEditingController controller;
  final ScriptEditorFindController find = ScriptEditorFindController();
  final FocusNode focusNode = FocusNode();
  final bool readOnly;

  Future<void> pump(
    WidgetTester tester, {
    bool? readOnlyOverride,
    bool boldText = false,
  }) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        // 模拟系统「无障碍 → 粗体文字」。
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(boldText: boldText),
          child: child!,
        ),
        home: Scaffold(
          body: ScriptCodeEditor(
            controller: controller,
            findController: find,
            focusNode: focusNode,
            readOnly: readOnlyOverride ?? readOnly,
            background: Colors.white,
          ),
        ),
      ),
    );
    await tester.pump();
  }

  Future<void> dispose(WidgetTester tester) async {
    // re_editor 拿到焦点后会排一个 100ms 的定时器去点亮光标，定时器不跟着编辑器销毁取消；
    // 先把它放完再拆，否则 debug 下报「disposed 之后还在用」（真机上只是 debug 断言）。
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 1));
    controller.dispose();
    find.dispose();
    focusNode.dispose();
  }
}

/// 行号栏这一帧画的段落：一个逻辑行一个段落，软换行的续行在同一个段落里。
List<CodeLineRenderParagraph> _paragraphs(WidgetTester tester) => tester
    .widget<DefaultCodeLineNumber>(find.byType(DefaultCodeLineNumber))
    .notifier
    .value!
    .paragraphs;

/// 光标（选区终点）所在的「行, 列」。不比 affinity：re_editor 左右移动时会顺带改它。
(int, int) _caret(CodeLineEditingController controller) =>
    (controller.selection.extentIndex, controller.selection.extentOffset);

/// 截住剪贴板：setData 记下来，getData 回 [pasteText]。
List<String> _mockClipboard(WidgetTester tester, {String pasteText = ''}) {
  final copied = <String>[];
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
        return null;
      }
      if (call.method == 'Clipboard.getData') {
        return <String, dynamic>{'text': pasteText};
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  return copied;
}

/// 长按第一行开头的那个词，弹出选择菜单。
Future<void> _longPressFirstWord(WidgetTester tester) async {
  final origin = tester.getTopLeft(find.byType(CodeEditor));
  // 行号栏约 30 宽 + 正文内边距 14，第一行在内边距 14 之下。
  await tester.longPressAt(origin + const Offset(60, 22));
  await tester.pump(const Duration(milliseconds: 300));
}

/// 按面板 IME 的方式送一条增量（delta）编辑。
Future<void> _sendDelta(
  WidgetTester tester, {
  required String oldText,
  required String deltaText,
  required int start,
  required int end,
  required int selection,
  required int composingBase,
  required int composingExtent,
}) async {
  final setClient = tester.testTextInput.log.lastWhere(
    (call) => call.method == 'TextInput.setClient',
  );
  final clientId = (setClient.arguments as List)[0] as int;
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
    SystemChannels.textInput.name,
    SystemChannels.textInput.codec.encodeMethodCall(
      MethodCall('TextInputClient.updateEditingStateWithDeltas', [
        clientId,
        {
          'deltas': [
            {
              'oldText': oldText,
              'deltaText': deltaText,
              'deltaStart': start,
              'deltaEnd': end,
              'selectionBase': selection,
              'selectionExtent': selection,
              'selectionAffinity': 'TextAffinity.downstream',
              'selectionIsDirectional': false,
              'composingBase': composingBase,
              'composingExtent': composingExtent,
            },
          ],
        },
      ]),
    ),
    (_) {},
  );
  await tester.pump();
}

void main() {
  group('ScriptCodeEditor 组件', () {
    testWidgets('5000 行约 150KB：能加载，只排版视口附近的行；敲一个字内容正确、仍只排一屏', (tester) async {
      final text = _buildJs(5000);
      // 前提：确实是「约 150KB」量级的长脚本。
      expect(text.length, greaterThan(150000));
      final h = _Harness(text);
      await h.pump(tester);

      expect(h.controller.lineCount, 5000);
      expect(h.controller.text, text);
      final before = _paragraphs(tester);
      expect(before, isNotEmpty);
      expect(before.first.index, 0);
      // 640 高的视口一屏也就二三十行：排版的段落数与全文 5000 行无关。
      expect(before.length, lessThan(100));

      // 在第 4 行第 4 列插入一个字（与输入法上屏同一条路径：edit 收到当前行的新值）。
      final line = h.controller.codeLines[3].text;
      h.controller.selection = const CodeLineSelection.collapsed(
        index: 3,
        offset: 4,
      );
      h.controller.edit(
        TextEditingValue(
          text: '${line.substring(0, 4)}x${line.substring(4)}',
          selection: const TextSelection.collapsed(offset: 5),
        ),
      );
      await tester.pump();
      final lines = text.split('\n');
      lines[3] = '${lines[3].substring(0, 4)}x${lines[3].substring(4)}';
      expect(h.controller.text, lines.join('\n'));
      expect(_paragraphs(tester).length, lessThan(100));

      await h.dispose(tester);
    });

    testWidgets('软换行：长行折成多条视觉行但只占一个行号；中文行、空行一行一号', (tester) async {
      final text = [
        'short',
        '',
        '// 中文注释一行，中文注释一行',
        List.filled(60, 'word').join(' '),
        'after_wrap',
      ].join('\n');
      final h = _Harness(text);
      await h.pump(tester);

      expect(tester.widget<CodeEditor>(find.byType(CodeEditor)).wordWrap, isTrue);
      final paragraphs = _paragraphs(tester);
      // 一个逻辑行一个段落，行号按段落画：5 条逻辑行 5 个号，续行不另编号。
      expect(paragraphs.map((p) => p.index), [0, 1, 2, 3, 4]);
      final lineHeight = paragraphs.first.height;
      expect(paragraphs[1].height, closeTo(lineHeight, 0.5));
      expect(paragraphs[2].height, closeTo(lineHeight, 0.5));
      // 第 4 行确实被折断了，否则这条用例没在测软换行。
      expect(paragraphs[3].height, greaterThan(lineHeight * 2));
      // 段落首尾相接：下一行的号画在上一行（含续行）的下面。
      for (var i = 1; i < paragraphs.length; i++) {
        expect(paragraphs[i].top, closeTo(paragraphs[i - 1].bottom, 0.5));
      }

      await h.dispose(tester);
    });

    testWidgets('空文件也有第 1 行；行号栏最少按两位算宽，9 行与 42 行一样宽、1234 行更宽', (tester) async {
      final empty = _Harness('');
      await empty.pump(tester);
      expect(empty.controller.text, '');
      expect(_paragraphs(tester).map((p) => p.index), [0]);
      await empty.dispose(tester);

      Future<double> gutterWidth(int lines) async {
        final h = _Harness(List.generate(lines, (i) => 'l$i').join('\n'));
        await h.pump(tester);
        final width = tester.getSize(find.byType(DefaultCodeLineNumber)).width;
        await h.dispose(tester);
        return width;
      }

      final nine = await gutterWidth(9);
      final fortyTwo = await gutterWidth(42);
      final big = await gutterWidth(1234);
      expect(nine, fortyTwo);
      expect(big, greaterThan(fortyTwo));
    });

    testWidgets('只读：拿到焦点也不开输入法；菜单只有「复制 / 全选」，全选后复制得到整篇', (tester) async {
      const text = 'hello world\nsecond line\n';
      final copied = _mockClipboard(tester);
      final h = _Harness(text, readOnly: true);
      await h.pump(tester);

      h.focusNode.requestFocus();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isFalse);

      await _longPressFirstWord(tester);
      expect(h.controller.selectedText, 'hello');
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);
      expect(find.text('剪切'), findsNothing);
      expect(find.text('粘贴'), findsNothing);

      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(h.controller.isAllSelected, isTrue);
      await tester.tap(find.text('复制'));
      await tester.pump();
      expect(copied, [text]);
      // 只读：内容一个字没变。
      expect(h.controller.text, text);

      await h.dispose(tester);
    });

    testWidgets('可编辑：中文菜单四项齐全；全选后粘贴替换整篇、全选后退格清空整篇', (tester) async {
      const text = 'hello world\nsecond line\n';
      _mockClipboard(tester, pasteText: 'export A=1\n');
      final h = _Harness(text);
      await h.pump(tester);

      await _longPressFirstWord(tester);
      expect(find.text('剪切'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('粘贴'), findsOneWidget);
      expect(find.text('全选'), findsOneWidget);

      await tester.tap(find.text('全选'));
      await tester.pump();
      expect(h.controller.isAllSelected, isTrue);
      await tester.tap(find.text('粘贴'));
      await tester.pump();
      expect(h.controller.text, 'export A=1\n');

      await _longPressFirstWord(tester);
      await tester.tap(find.text('全选'));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(h.controller.text, '');

      await h.dispose(tester);
    });

    testWidgets('中文输入法：拼音组合期间不丢字、选词上屏后不重复', (tester) async {
      final h = _Harness('ab\ncd');
      await h.pump(tester);

      h.focusNode.requestFocus();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);
      h.controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 2,
      );
      await tester.pump();

      // 编辑器只把光标所在的那一行交给输入法（移动端前面还垫了一个占位字符）。
      final state = tester.testTextInput.editingState!;
      final remote = state['text'] as String;
      final caret = state['selectionBase'] as int;
      expect(remote.endsWith('ab'), isTrue);

      // 敲 n：组合中。
      await _sendDelta(
        tester,
        oldText: remote,
        deltaText: 'n',
        start: caret,
        end: caret,
        selection: caret + 1,
        composingBase: caret,
        composingExtent: caret + 1,
      );
      expect(h.controller.text, 'abn\ncd');
      expect(h.controller.isComposing, isTrue);

      // 再敲 i：组合区从 n 变成 ni，不是追加出 nni。
      await _sendDelta(
        tester,
        oldText: '${remote}n',
        deltaText: 'ni',
        start: caret,
        end: caret + 1,
        selection: caret + 2,
        composingBase: caret,
        composingExtent: caret + 2,
      );
      expect(h.controller.text, 'abni\ncd');

      // 选「你」上屏：组合区整体换成一个汉字，组合结束。
      await _sendDelta(
        tester,
        oldText: '${remote}ni',
        deltaText: '你',
        start: caret,
        end: caret + 2,
        selection: caret + 1,
        composingBase: -1,
        composingExtent: -1,
      );
      expect(h.controller.text, 'ab你\ncd');
      expect(h.controller.isComposing, isFalse);

      await h.dispose(tester);
    });

    testWidgets('编辑中切回只读：键盘收起、输入法连接关掉，不能再往里敲', (tester) async {
      final h = _Harness('ab');
      await h.pump(tester);
      h.focusNode.requestFocus();
      await tester.pump();
      expect(tester.testTextInput.hasAnyClients, isTrue);

      // 页面点「查看」/ 保存成功后 readOnly 变 true。
      await h.pump(tester, readOnlyOverride: true);
      expect(h.focusNode.hasFocus, isFalse);
      expect(tester.testTextInput.hasAnyClients, isFalse);

      await h.dispose(tester);
    });

    testWidgets('只读：外接键盘按退格 / 回车不改内容（re_editor 在移动端按键处理里不看 readOnly）', (tester) async {
      const text = 'hello\nworld';
      final h = _Harness(text, readOnly: true);
      await h.pump(tester);

      // 只读时点一下正文也会拿到焦点，外接键盘的按键就送到编辑器上了。
      h.focusNode.requestFocus();
      await tester.pump();
      expect(h.focusNode.hasFocus, isTrue);
      h.controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 5,
      );
      await tester.pump();

      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(h.controller.text, text);

      // 切到可编辑后，同样的按键照常生效（拦截只在只读期间）。
      await h.pump(tester, readOnlyOverride: false);
      h.focusNode.requestFocus();
      await tester.pump();
      h.controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 5,
      );
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(h.controller.text, 'hell\nworld');

      await h.dispose(tester);
    });

    testWidgets('键盘弹起把编辑器压矮：光标行被挡住时自动滚回视口', (tester) async {
      final text = List.generate(80, (i) => 'line $i').join('\n');
      final h = _Harness(text);
      await h.pump(tester);
      h.focusNode.requestFocus();
      await tester.pump();
      // 光标放在屏幕下半部的一行（未弹键盘时看得见，不会触发滚动）。
      h.controller.selection = const CodeLineSelection.collapsed(
        index: 26,
        offset: 0,
      );
      await tester.pump();
      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CodeEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scrollable.position.pixels, 0);
      expect(_paragraphs(tester).map((p) => p.index), contains(26));

      // 键盘弹起：Scaffold 把正文压矮 300，第 27 行落到视口下面。
      tester.view.viewInsets = const FakeViewPadding(bottom: 300);
      await tester.pump();
      await tester.pump();
      expect(scrollable.position.pixels, greaterThan(0));
      final cursorLine = _paragraphs(
        tester,
      ).firstWhere((p) => p.index == 26);
      final viewport = tester.getSize(find.byType(CodeEditor)).height;
      // 光标行整行落在（压矮后的）视口里。
      expect(cursorLine.bottom, lessThanOrEqualTo(viewport + 0.5));

      await h.dispose(tester);
    });

    // ── APP #26：输入法「光标键盘」的方向键 ───────────────────────────────
    // 搜狗 / 百度等输入法的光标键发的是 DPAD 方向键事件；re_editor 在移动端只接退格 / 回车，
    // 由 ScriptCodeEditor 外层的 Focus 接住。以下几条都在 Android 平台下跑，结束时复位。

    testWidgets('APP #26：方向键移动光标、Home / End 到行首行尾；只读时也能移、内容不变', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        const text = 'abc\n  def\nghi';
        for (final readOnly in [false, true]) {
          final h = _Harness(text, readOnly: readOnly);
          await h.pump(tester);
          h.focusNode.requestFocus();
          await tester.pump();
          h.controller.selection = const CodeLineSelection.collapsed(
            index: 1,
            offset: 3,
          );
          await tester.pump();

          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
          await tester.pump();
          expect(_caret(h.controller), (1, 4));

          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
          await tester.pump();
          expect(_caret(h.controller), (1, 2));

          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
          expect(h.controller.selection.isCollapsed, isTrue);
          expect(h.controller.selection.extentIndex, 2);

          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
          await tester.pump();
          expect(h.controller.selection.isCollapsed, isTrue);
          expect(h.controller.selection.extentIndex, 0);

          // 行尾 / 行首（「行首」先到缩进后的第一个字）。
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.sendKeyEvent(LogicalKeyboardKey.end);
          await tester.pump();
          expect(_caret(h.controller), (1, 5));
          await tester.sendKeyEvent(LogicalKeyboardKey.home);
          await tester.pump();
          expect(_caret(h.controller), (1, 2));

          // 移动光标从不改内容（只读、可编辑都一样）。
          expect(h.controller.text, text);
          await h.dispose(tester);
        }
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('APP #26：Shift+方向键扩展选区，起点不动；不带 Shift 再按就收起选区', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final h = _Harness('hello world\nsecond line');
        await h.pump(tester);
        h.focusNode.requestFocus();
        await tester.pump();
        h.controller.selection = const CodeLineSelection.collapsed(
          index: 0,
          offset: 6,
        );
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
        for (var i = 0; i < 5; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        }
        await tester.pump();
        expect(h.controller.selectedText, 'world');
        expect((h.controller.selection.baseIndex, h.controller.selection.baseOffset), (0, 6));

        // Shift+↓：终点挪到下一行，起点仍在第 1 行。
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(h.controller.selection.baseIndex, 0);
        expect(h.controller.selection.baseOffset, 6);
        expect(h.controller.selection.extentIndex, 1);

        // Shift+Home：终点回到这一行的行首。
        await tester.sendKeyEvent(LogicalKeyboardKey.home);
        await tester.pump();
        expect(h.controller.selectedText, 'world\n');
        await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
        await tester.pump();

        // 松开 Shift 再按 →：选区收到末尾，变回光标。
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight);
        await tester.pump();
        expect(h.controller.selection.isCollapsed, isTrue);
        expect(_caret(h.controller), (1, 0));
        expect(h.controller.text, 'hello world\nsecond line');

        await h.dispose(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('APP #26：拼音组字中按方向键不动光标、不打散组合区；上屏后照常移动', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final h = _Harness('ab\ncd');
        await h.pump(tester);
        h.focusNode.requestFocus();
        await tester.pump();
        h.controller.selection = const CodeLineSelection.collapsed(
          index: 0,
          offset: 2,
        );
        await tester.pump();
        final state = tester.testTextInput.editingState!;
        final remote = state['text'] as String;
        final caret = state['selectionBase'] as int;

        // 敲 n：组合中。
        await _sendDelta(
          tester,
          oldText: remote,
          deltaText: 'n',
          start: caret,
          end: caret,
          selection: caret + 1,
          composingBase: caret,
          composingExtent: caret + 1,
        );
        expect(h.controller.isComposing, isTrue);
        final composingSelection = h.controller.selection;

        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        expect(h.controller.selection, composingSelection);
        expect(h.controller.isComposing, isTrue);
        expect(h.controller.text, 'abn\ncd');

        // 选「你」上屏，组合结束：方向键恢复作用。
        await _sendDelta(
          tester,
          oldText: '${remote}n',
          deltaText: '你',
          start: caret,
          end: caret + 1,
          selection: caret + 1,
          composingBase: -1,
          composingExtent: -1,
        );
        expect(h.controller.isComposing, isFalse);
        expect(_caret(h.controller), (0, 3));
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowLeft);
        await tester.pump();
        expect(_caret(h.controller), (0, 2));
        expect(h.controller.text, 'ab你\ncd');

        await h.dispose(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('APP #26：方向键把光标移出视口时自动滚回来', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      try {
        final h = _Harness(List.generate(80, (i) => 'line $i').join('\n'));
        await h.pump(tester);
        h.focusNode.requestFocus();
        await tester.pump();
        h.controller.selection = const CodeLineSelection.collapsed(
          index: 0,
          offset: 0,
        );
        await tester.pump();
        final scrollable = tester.state<ScrollableState>(
          find
              .descendant(
                of: find.byType(CodeEditor),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        expect(scrollable.position.pixels, 0);

        // 一路按 ↓ 到第 61 行，远超一屏（640 高约二三十行）。
        for (var i = 0; i < 60; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        expect(h.controller.selection.extentIndex, 60);
        expect(scrollable.position.pixels, greaterThan(0));
        final cursorLine = _paragraphs(tester).firstWhere((p) => p.index == 60);
        final viewport = tester.getSize(find.byType(CodeEditor)).height;
        expect(cursorLine.top, greaterThanOrEqualTo(-0.5));
        expect(cursorLine.bottom, lessThanOrEqualTo(viewport + 0.5));

        await h.dispose(tester);
      } finally {
        debugDefaultTargetPlatformOverride = null;
      }
    });

    testWidgets('系统「粗体文字」：正文与行号都加粗；关着时不加粗', (tester) async {
      Future<void> check({required bool bold}) async {
        final h = _Harness('echo hi');
        await h.pump(tester, boldText: bold);
        final editor = tester.widget<CodeEditor>(find.byType(CodeEditor));
        // 正文：每一行的 TextSpan 都从 controller.buildTextSpan 出来，再交给段落排版。
        final span = editor.controller!.buildTextSpan(
          context: tester.element(find.byType(CodeEditor)),
          index: 0,
          textSpan: const TextSpan(text: 'echo hi'),
          style: const TextStyle(fontSize: 13),
        );
        expect(span.toPlainText(), 'echo hi');
        expect(
          span.style?.fontWeight,
          bold ? FontWeight.bold : isNull,
        );
        // 行号。
        final gutter = tester.widget<DefaultCodeLineNumber>(
          find.byType(DefaultCodeLineNumber),
        );
        expect(
          gutter.textStyle?.fontWeight,
          bold ? FontWeight.bold : isNull,
        );
        await h.dispose(tester);
      }

      await check(bold: true);
      await check(bold: false);
    });
  });

  group('ScriptEditorFindController：命中下标换成行列', () {
    test('跨行定位；当前命中多叠画一层；越界的命中直接停', () {
      final find = ScriptEditorFindController();
      const text = 'foo\nbar foo\n\nfoo';
      find.updateMatches(
        text: text,
        offsets: const [0, 8, 13],
        current: 1,
        length: 3,
      );
      expect(find.positionForOffset(0), const CodeLinePosition(index: 0, offset: 0));
      expect(find.positionForOffset(8), const CodeLinePosition(index: 1, offset: 4));
      expect(find.positionForOffset(13), const CodeLinePosition(index: 3, offset: 0));
      // 三个命中 + 当前那个（第 2 个）再画一次 = 强高亮。
      final highlights = find.debugHighlights;
      expect(highlights, hasLength(4));
      expect(highlights.last, highlights[1]);
      expect(
        highlights[1],
        const CodeLineSelection(
          baseIndex: 1,
          baseOffset: 4,
          extentIndex: 1,
          extentOffset: 7,
        ),
      );
      // re_editor 不能拿它改选区。
      expect(find.currentMatchSelection, isNull);

      find.updateCurrent(0);
      expect(find.debugHighlights.last, find.debugHighlights.first);

      // 打字之后命中晚一步才重算：越界的那几个直接丢掉，不把编辑器画崩。
      find.updateMatches(
        text: 'foo',
        offsets: const [0, 8],
        current: 1,
        length: 3,
      );
      expect(find.debugHighlights, hasLength(1));

      find.dispose();
    });
  });

  group('两个页面都用上新组件', () {
    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      FlutterSecureStorage.setMockInitialValues({});
      DioClient.instance.setBaseUrl('https://panel.test');
    });

    Future<void> openScriptPage(
      WidgetTester tester,
      String content,
      List<Object?> putBodies,
    ) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.scriptsContent) {
          if (options.method == 'GET') {
            return jsonResponse({
              'data': {'content': content},
            });
          }
          if (options.method == 'PUT') {
            putBodies.add(options.data);
            return jsonResponse({'data': <String, dynamic>{}});
          }
        }
        // 编辑器底色之类的面板配置按老面板 404 处理，用默认值。
        return jsonResponse(<String, dynamic>{}, status: 404);
      });
      await tester.pumpWidget(
        const ProviderScope(
          child: MaterialApp(home: ScriptViewPage(path: 'demo/long.js')),
        ),
      );
      // 响应体超过 50KB 时 dio 在后台 isolate 里解 JSON，FakeAsync 里等不到，
      // 要用 runAsync 让真实时间走一走，再 pump 把回调放进来。
      for (var i = 0; i < 40; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 20)),
        );
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byType(ScriptCodeEditor).evaluate().isNotEmpty) {
          break;
        }
      }
      await tester.pump(const Duration(milliseconds: 20));
    }

    Future<void> closePage(WidgetTester tester) async {
      // 编辑器拿过焦点的话，先把 re_editor 点亮光标的定时器放完再拆（原因见 _Harness.dispose）。
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    }

    CodeEditor editor(WidgetTester tester) =>
        tester.widget<CodeEditor>(find.byType(CodeEditor));

    testWidgets('脚本页：5000 行进编辑器、默认只读；进编辑模式改一个字，保存发出去的是编辑器全文', (tester) async {
      final text = _buildJs(5000);
      final putBodies = <Object?>[];
      await openScriptPage(tester, text, putBodies);

      expect(find.byType(ScriptCodeEditor), findsOneWidget);
      expect(editor(tester).controller!.text, text);
      expect(editor(tester).readOnly, isTrue);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      expect(editor(tester).readOnly, isFalse);

      final controller = editor(tester).controller!;
      controller.selection = const CodeLineSelection.collapsed(
        index: 1,
        offset: 0,
      );
      controller.replaceSelection('// 新加的一行\n');
      await tester.pump();
      final expected = text.replaceFirst('\n', '\n// 新加的一行\n');
      expect(controller.text, expected);

      await tester.tap(find.byIcon(Icons.save_outlined));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(putBodies, hasLength(1));
      expect((putBodies.single as Map)['content'], expected);
      expect(find.text('保存成功'), findsOneWidget);
      // 保存后回到查看模式。
      expect(editor(tester).readOnly, isTrue);

      await closePage(tester);
    });

    testWidgets('脚本页查找：计数、下一个跳到视口外的命中；编辑后命中跟着挪、不越界', (tester) async {
      final lines = List.generate(300, (i) => 'line $i');
      lines[5] = 'const needle = 1;';
      lines[250] = 'use(needle);';
      final putBodies = <Object?>[];
      await openScriptPage(tester, lines.join('\n'), putBodies);

      await tester.tap(find.byTooltip('查找代码'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, '查找代码'), 'needle');
      await tester.pump();
      expect(find.text('1/2'), findsOneWidget);

      final scrollable = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(CodeEditor),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      expect(scrollable.position.pixels, 0);

      // 第 2 个命中在第 251 行，远在视口外：点「下一个」要真的滚过去。
      await tester.tap(find.byTooltip('下一个'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('2/2'), findsOneWidget);
      expect(scrollable.position.pixels, greaterThan(0));
      expect(_paragraphs(tester).map((p) => p.index), contains(250));

      // 再点一次回绕到第 1 个，跳回顶部附近。
      await tester.tap(find.byTooltip('下一个'));
      for (var i = 0; i < 12; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('1/2'), findsOneWidget);
      expect(_paragraphs(tester).map((p) => p.index), contains(5));

      // 进编辑模式在文件开头插入一行：命中整体下移一行，计数不变、序号不跳回别处。
      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      final controller = editor(tester).controller!;
      final highlights = tester
          .widget<ScriptCodeEditor>(find.byType(ScriptCodeEditor))
          .findController;
      controller.selection = const CodeLineSelection.collapsed(
        index: 0,
        offset: 0,
      );
      controller.replaceSelection('// top\n');
      await tester.pump();
      expect(find.text('1/2'), findsOneWidget);
      expect(highlights.debugHighlights.first.baseIndex, 6);
      expect(highlights.debugHighlights[1].baseIndex, 251);

      // 删光全文：命中归零，不抛异常。
      controller.selectAll();
      controller.deleteBackward();
      await tester.pump();
      expect(tester.takeException(), isNull);
      expect(find.text('无结果'), findsOneWidget);

      await closePage(tester);
    });

    testWidgets('脚本页：只读期间缓冲区被意外改了，点「编辑」时用服务端内容重灌，保存不会把误改写回去', (tester) async {
      const text = 'echo one\necho two';
      final putBodies = <Object?>[];
      await openScriptPage(tester, text, putBodies);

      // 模拟只读期间漏进来的改动（拦截之外的兜底）：直接改页面持有的 controller。
      final raw = tester
          .widget<ScriptCodeEditor>(find.byType(ScriptCodeEditor))
          .controller;
      raw.text = 'echo one\n';
      await tester.pump();

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      expect(editor(tester).readOnly, isFalse);
      expect(raw.text, text);

      await tester.tap(find.byIcon(Icons.save_outlined));
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect((putBodies.single as Map)['content'], text);

      await closePage(tester);
    });

    testWidgets('脚本页编辑中点查找条「下一个」：编辑器不失焦（键盘不收、选区不丢）', (tester) async {
      final lines = List.generate(60, (i) => 'line $i');
      lines[3] = 'needle a';
      lines[50] = 'needle b';
      final putBodies = <Object?>[];
      await openScriptPage(tester, lines.join('\n'), putBodies);

      await tester.tap(find.byIcon(Icons.edit_outlined));
      await tester.pump();
      await tester.tap(find.byTooltip('查找代码'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, '查找代码'), 'needle');
      await tester.pump();
      expect(find.text('1/2'), findsOneWidget);

      // 回到编辑器里继续改（点正文拿焦点），这时再去点查找条上的按钮。
      final focusNode = editor(tester).focusNode!;
      focusNode.requestFocus();
      await tester.pump();
      final controller = editor(tester).controller!;
      controller.selection = const CodeLineSelection(
        baseIndex: 0,
        baseOffset: 0,
        extentIndex: 0,
        extentOffset: 4,
      );
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      await tester.tap(find.byTooltip('下一个'));
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }
      expect(find.text('2/2'), findsOneWidget);
      expect(focusNode.hasFocus, isTrue);
      expect(controller.selectedText, 'line');

      await tester.tap(find.byTooltip('上一个'));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      // 点路径行（紧挨编辑器、容易误碰）同样不失焦。
      await tester.tap(find.text('demo/long.js'));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      await closePage(tester);
    });

    testWidgets('重新打开刚看过的脚本：首帧不挂编辑器，等加载完再挂', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.scriptsContent) {
          return jsonResponse({
            'data': {'content': 'echo hi'},
          });
        }
        return jsonResponse(<String, dynamic>{}, status: 404);
      });
      // provider 是全局的：上一次打开同一个脚本已经把它加载好了。
      final container = ProviderContainer();
      addTearDown(container.dispose);
      await tester.runAsync(
        () => container.read(scriptProvider.notifier).loadContent('demo/a.sh'),
      );
      expect(container.read(scriptProvider).selectedPath, 'demo/a.sh');
      expect(container.read(scriptProvider).loadingContent, isFalse);

      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: const MaterialApp(home: ScriptViewPage(path: 'demo/a.sh')),
        ),
      );
      // 首帧：loadContent 还没发出（在 microtask 里），但也按加载中处理，不挂编辑器。
      expect(find.byType(ScriptCodeEditor), findsNothing);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
        if (find.byType(ScriptCodeEditor).evaluate().isNotEmpty) {
          break;
        }
      }
      expect(find.byType(ScriptCodeEditor), findsOneWidget);
      expect(editor(tester).controller!.text, 'echo hi');

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets('配置文件页同样用的是 ScriptCodeEditor，且打开即可编辑', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      DioClient.instance.dio.httpClientAdapter = FakeHttpAdapter((options) {
        if (options.path == ApiEndpoints.configScript) {
          return jsonResponse({
            'data': {'content': 'export A=1\r\nexport B=2\r\n', 'path': 'config.sh'},
          });
        }
        return jsonResponse(<String, dynamic>{}, status: 404);
      });
      await tester.pumpWidget(const MaterialApp(home: ConfigScriptPage()));
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 20));
      }

      expect(find.byType(ScriptCodeEditor), findsOneWidget);
      expect(editor(tester).readOnly, isFalse);
      // CRLF 文件按行载入（与面板网页一致归一成 \n），刚打开不该显示「有未保存的修改」。
      expect(editor(tester).controller!.text, 'export A=1\nexport B=2\n');
      expect(find.text('config.sh'), findsOneWidget);

      // 编辑中点路径行、查找条上的按钮，编辑器不失焦（与脚本页同一处理）。
      final focusNode = editor(tester).focusNode!;
      focusNode.requestFocus();
      await tester.pump();
      await tester.tap(find.text('config.sh'));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);
      await tester.tap(find.byTooltip('查找'));
      await tester.pump();
      focusNode.requestFocus();
      await tester.pump();
      await tester.tap(find.byTooltip('下一个'));
      await tester.pump();
      expect(focusNode.hasFocus, isTrue);

      await closePage(tester);
    });
  });
}
