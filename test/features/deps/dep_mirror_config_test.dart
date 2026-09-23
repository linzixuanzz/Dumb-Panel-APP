import 'package:daidai_app/features/deps/views/dep_list_page.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../support/fake_http_adapter.dart';

/// 镜像源「只提交改过的字段」的回归保护（面板 #146 的 400 修复在 APP 侧的另一半，#150）。
///
/// 以前恒提交 pip / npm / linux 三个键：dnf 系统上空的 linux_mirror 必报 400，
/// 只改 npm 也会把「旧默认源一次性迁移」永久关掉。守门条件就是 payload 里**没改的键不出现**。
void main() {
  const initial = DepMirrorConfig(
    pipMirror: 'https://mirrors.cloud.tencent.com/pypi/simple',
    npmMirror: 'https://registry.npmmirror.com',
    linuxMirror: 'https://mirrors.aliyun.com/debian',
    linuxPackageManager: 'apt',
    linuxDistribution: 'debian',
    linuxMirrorSupported: true,
  );

  group('DepMirrorConfig.changedRequestJson', () {
    test('什么都没改：payload 为空，页面据此提示「镜像源未变更」、不发请求', () {
      expect(initial.copyWith().changedRequestJson(initial), isEmpty);
    });

    test('只改 pip：只有 pip_mirror 一个键，Linux 源不跟着提交', () {
      final payload = initial
          .copyWith(pipMirror: 'https://pypi.tuna.tsinghua.edu.cn/simple')
          .changedRequestJson(initial);

      expect(payload, {
        'pip_mirror': 'https://pypi.tuna.tsinghua.edu.cn/simple',
      });
      expect(
        payload.containsKey('linux_mirror'),
        isFalse,
        reason: '带上 linux_mirror 就会在 dnf 系统上 400、并关掉旧默认源迁移',
      );
    });

    test('Linux 点「恢复默认」清空：空串也算改动，否则「恢复默认」永远发不出去', () {
      final payload = initial
          .copyWith(linuxMirror: '')
          .changedRequestJson(initial);

      expect(payload, {'linux_mirror': ''});
    });

    test('只差首尾空格：不算改动', () {
      final payload = initial
          .copyWith(
            pipMirror: '  ${initial.pipMirror}  ',
            linuxMirror: '${initial.linuxMirror}\n',
          )
          .changedRequestJson(initial);

      expect(payload, isEmpty);
    });
  });

  test('setMirrors 原样 PUT 传入的 payload：body 的键就是改过的那几个', () async {
    String? method;
    String? path;
    Object? body;
    final adapter = FakeHttpAdapter((options) {
      method = options.method;
      path = options.path;
      body = options.data;
      return jsonResponse({'message': '镜像源设置成功'});
    });
    final notifier = DepListNotifier(dio: dioWithAdapter(adapter));

    // 只改了 npm（点了「恢复默认」）：pip 与 linux 都不能出现在请求体里。
    await notifier.setMirrors(
      initial.copyWith(npmMirror: '').changedRequestJson(initial),
    );

    expect(method, 'PUT');
    expect(path, '/api/deps/mirrors');
    expect(body, isA<Map>());
    expect((body as Map).keys.toSet(), {'npm_mirror'});
    expect(body, {'npm_mirror': ''});
  });
}
