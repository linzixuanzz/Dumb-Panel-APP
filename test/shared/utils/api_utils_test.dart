import 'dart:typed_data';

import 'package:daidai_app/shared/utils/api_utils.dart';
import 'package:flutter_test/flutter_test.dart';

/// `extractResponseBytes` 的纯函数单测。
///
/// 它是从 `backup_page` / `script_list_page` 两份逐字相同的私有实现合并出来的，
/// 现在又多了「下载原始日志」这个调用方 —— 三处共用一份，行为必须被钉住。
void main() {
  group('extractResponseBytes', () {
    test('dio 正常给的 Uint8List 原样返回（不复制一份）', () {
      final bytes = Uint8List.fromList([1, 2, 3]);

      expect(identical(extractResponseBytes(bytes), bytes), isTrue);
    });

    test('List<int> 转成 Uint8List', () {
      expect(extractResponseBytes(<int>[10, 20]), Uint8List.fromList([10, 20]));
    });

    test('List<dynamic>（JSON 解出来的数字数组）也能吃下', () {
      expect(
        extractResponseBytes(<dynamic>[65, 66, 67]),
        Uint8List.fromList([65, 66, 67]),
      );
    });

    test('非字节内容返回 null，让调用方自己决定报什么错', () {
      expect(extractResponseBytes(null), isNull);
      expect(extractResponseBytes('not bytes'), isNull);
      expect(extractResponseBytes(<String, dynamic>{'error': 'x'}), isNull);
    });

    test('空响应体返回空列表而不是 null —— 「空文件」和「压根不是字节」是两回事', () {
      expect(extractResponseBytes(<int>[]), isEmpty);
      expect(extractResponseBytes(<int>[]), isNotNull);
    });
  });
}
