import 'package:daidai_app/shared/utils/sse_replay_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

/// 面板四条 SSE 流都不支持 Last-Event-ID，重连必定从头重放整段历史。
/// 这个缓冲区是「重连后用户不会看到日志翻倍」的唯一保障，
/// 而它是纯函数，属于最该有单测的那一类。
void main() {
  test('没有重连过：原样放行，一行都不吞', () {
    final buffer = SseReplayBuffer();

    expect(buffer.consume(['a', 'b']), ['a', 'b']);
  });

  test('重放的行被抵扣掉，只有真正的新行会显示', () {
    final buffer = SseReplayBuffer()..reset(['a', 'b']);

    expect(buffer.consume(['a', 'b']), isEmpty, reason: '这两行界面上已经有了');
    expect(buffer.consume(['c']), ['c'], reason: '抵扣完之后必须恢复原样放行');
  });

  test('重放分多个事件到达也能逐条抵扣', () {
    final buffer = SseReplayBuffer()..reset(['a', 'b', 'c']);

    expect(buffer.consume(['a']), isEmpty);
    expect(buffer.consume(['b', 'c', 'd']), ['d']);
  });

  test('对不上就整段放弃去重：宁可重复也不能吞掉真实日志', () {
    // 突变验证锚点：把 consume 里的 `_pending.clear()` 删掉，
    // 下面的 'a' 会被后面的比对继续吃掉，这条用例必须红。
    final buffer = SseReplayBuffer()..reset(['a', 'b']);

    expect(
      buffer.consume(['x', 'a', 'b']),
      ['x', 'a', 'b'],
      reason: '第一行就对不上，说明服务端重放的不是同一段历史，之后一律照原样显示',
    );
    expect(buffer.isEmpty, isTrue);
  });

  test('服务端重放的历史比本地少：多出来的新行照常显示', () {
    // 本地有 3 行，服务端只重放了前 2 行（例如日志被截断）。
    final buffer = SseReplayBuffer()..reset(['a', 'b', 'c']);

    expect(buffer.consume(['a', 'b']), isEmpty);
    expect(buffer.consume(['d']), ['d'], reason: '对不上就清空缓冲，d 是真新行');
  });

  test('reset 会覆盖上一轮残留，不会越攒越多', () {
    final buffer = SseReplayBuffer()
      ..reset(['a'])
      ..reset(['b', 'c']);

    expect(buffer.consume(['b', 'c']), isEmpty);
    expect(buffer.isEmpty, isTrue);
  });

  // issue #10：日志页超长时只在内存里保留最近一部分，前面的行已经没有原文了，
  // 但服务端重连照样从第一行开始重放。
  group('skipLeading：前面的行已因超长被丢掉', () {
    test('先按行数跳过丢掉的那段，再逐条抵扣留着的行', () {
      // 界面上只剩 c、d，a、b 早已被截断丢掉。
      final buffer = SseReplayBuffer()..reset(['c', 'd'], skipLeading: 2);

      expect(buffer.consume(['a', 'b', 'c']), isEmpty);
      expect(
        buffer.consume(['d', 'e']),
        ['e'],
        reason: '不跳过的话第一行 a 就对不上，整段历史会被重复追加一遍',
      );
      expect(buffer.isEmpty, isTrue);
    });

    test('跳过之后对不上，照样整段放弃去重、原样放行', () {
      final buffer = SseReplayBuffer()..reset(['c'], skipLeading: 1);

      expect(buffer.consume(['a', 'x', 'c']), ['x', 'c']);
      expect(buffer.isEmpty, isTrue);
    });

    test('界面上一行都没留时也要先跳过', () {
      final buffer = SseReplayBuffer()..reset(const [], skipLeading: 2);

      expect(buffer.isEmpty, isFalse);
      expect(buffer.consume(['a', 'b', 'c']), ['c']);
    });
  });
}
