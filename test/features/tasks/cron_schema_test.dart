import 'package:daidai_app/features/tasks/utils/cron_schema.dart';
import 'package:flutter_test/flutter_test.dart';

/// Cron 模板与解析结果的回归保护。
///
/// 两个必须守住的点：
/// 1. **响应是裸的**。`pkg/response.Success` 就是 `c.JSON(200, data)`，
///    `/tasks/cron/templates` 直接返回数组、`/tasks/cron/parse` 直接返回对象，
///    都没有 `{"data": ...}` 信封。按信封解析会拿到空列表，表现为
///    「模板按钮一个都不出来」，而且不报任何错。
/// 2. **老面板必须能降级**。拿不到模板就回落到冻结的 3 条，
///    拿不到解析结果就整块不显示 —— 不能弹一个「表达式无效」吓人。
void main() {
  group('parseCronTemplates', () {
    test('认裸数组 —— 这才是面板的真实形状', () {
      final templates = parseCronTemplates(_panelTemplatesPayload());
      expect(templates.length, 4);
      expect(templates.first.name, '每分钟');
      expect(templates.first.expression, '0 * * * * *');
      expect(templates.first.category, '高频');
    });

    test('也认 {"data": [...]} 信封，面板响应形态本来就不统一', () {
      final templates = parseCronTemplates(<String, dynamic>{
        'data': _panelTemplatesPayload(),
      });
      expect(templates.length, 4);
    });

    test('拿不到列表返回空，由调用方决定回落', () {
      expect(parseCronTemplates(null), isEmpty);
      expect(parseCronTemplates('route not found'), isEmpty);
      expect(parseCronTemplates(<String, dynamic>{'error': 'x'}), isEmpty);
    });

    test('没有 expression 的条目直接丢掉，不渲染成点了没反应的按钮', () {
      final templates = parseCronTemplates(<dynamic>[
        <String, dynamic>{'name': '坏模板', 'expression': '  '},
        <String, dynamic>{'name': '好模板', 'expression': '0 0 * * * *'},
      ]);
      expect(templates.length, 1);
      expect(templates.single.name, '好模板');
    });

    test('缺 name 时退回表达式本身，按钮上至少有字', () {
      final templates = parseCronTemplates(<dynamic>[
        <String, dynamic>{'expression': '0 0 * * * *'},
      ]);
      expect(templates.single.name, '0 0 * * * *');
    });
  });

  group('groupCronTemplates', () {
    test('按 category 分组，且保持面板给的顺序', () {
      // 面板 GetTemplates() 是一个手写有序数组，顺序表达「常用程度」。
      // 按字典序重排会把「秒级」排到「常用」前面。
      final groups = groupCronTemplates(
        parseCronTemplates(_panelTemplatesPayload()),
      );
      expect(groups.map((g) => g.category).toList(), ['高频', '常用', '每天']);
      expect(groups.first.templates.map((t) => t.name).toList(), [
        '每分钟',
        '每5分钟',
      ]);
    });

    test('没有 category 的条目归到最后一组', () {
      final groups = groupCronTemplates(
        parseCronTemplates(<dynamic>[
          <String, dynamic>{'name': 'A', 'expression': '1 * * * * *'},
          <String, dynamic>{
            'name': 'B',
            'expression': '2 * * * * *',
            'category': '常用',
          },
        ]),
      );
      expect(groups.last.category, '');
      expect(groups.first.category, '常用');
    });
  });

  group('kFallbackCronTemplates', () {
    test('就是改动前那三条，一条不多一条不少', () {
      expect(kFallbackCronTemplates.map((t) => t.expression).toList(), [
        '0 0 * * * *',
        '0 0 0 * * *',
        '0 0 9 * * *',
      ]);
    });
  });

  group('splitCronExpressions', () {
    test('与面板 pkg/cron.SplitExpressions 对齐：按行拆、去空白、丢空行', () {
      expect(splitCronExpressions('0 0 * * *\n\n  0 9 * * *  \r\n'), [
        '0 0 * * *',
        '0 9 * * *',
      ]);
    });

    test('全空白返回空列表', () {
      expect(splitCronExpressions('   \n\n'), isEmpty);
    });

    test('单条也走同一条路径', () {
      expect(splitCronExpressions(' 0 0 * * * '), ['0 0 * * *']);
    });
  });

  group('CronParseResult', () {
    test('合法表达式带描述与未来执行时间', () {
      final result = CronParseResult.fromJson(<String, dynamic>{
        'is_valid': true,
        'description': '每天 09:00 执行',
        'format': '扩展格式 (6位含秒)',
        'next_run_times': ['2026-08-07T09:00:00+08:00', '2026-08-08T09:00:00+08:00'],
      });
      expect(result, isNotNull);
      expect(result!.isValid, isTrue);
      expect(result.description, '每天 09:00 执行');
      expect(result.nextRunTimes.length, 2);
      expect(result.nextRunTime, isNotNull);
    });

    test('非法表达式给出面板的原始报错', () {
      final result = CronParseResult.fromJson(<String, dynamic>{
        'is_valid': false,
        'error': 'expected exactly 5 fields, found 3: [1 2 3]',
      });
      expect(result!.isValid, isFalse);
      expect(result.error, contains('expected exactly 5 fields'));
      expect(result.nextRunTimes, isEmpty);
    });

    test('没有 is_valid 就返回 null —— 老面板 404 页面不该被读成「表达式无效」', () {
      expect(CronParseResult.fromJson(null), isNull);
      expect(
        CronParseResult.fromJson(<String, dynamic>{'error': 'route not found'}),
        isNull,
      );
      expect(CronParseResult.fromJson('<html>404</html>'), isNull);
    });

    test('时间串解析不了就跳过，不整条作废', () {
      final result = CronParseResult.fromJson(<String, dynamic>{
        'is_valid': true,
        'next_run_times': ['not-a-time', '2026-08-07T09:00:00Z'],
      });
      expect(result!.nextRunTimes.length, 1);
    });
  });
}

/// 面板 `pkg/cron.GetTemplates()` 前四条的原样切片。
List<dynamic> _panelTemplatesPayload() => <dynamic>[
  <String, dynamic>{
    'name': '每分钟',
    'expression': '0 * * * * *',
    'description': '每分钟执行一次',
    'category': '高频',
  },
  <String, dynamic>{
    'name': '每5分钟',
    'expression': '0 */5 * * * *',
    'description': '每5分钟执行一次',
    'category': '高频',
  },
  <String, dynamic>{
    'name': '每30分钟',
    'expression': '0 */30 * * * *',
    'description': '每30分钟执行一次',
    'category': '常用',
  },
  <String, dynamic>{
    'name': '每天0点',
    'expression': '0 0 0 * * *',
    'description': '每天凌晨0点执行',
    'category': '每天',
  },
];
