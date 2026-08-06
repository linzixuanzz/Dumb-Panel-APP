import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../../../core/theme/app_theme.dart';
import '../../../core/theme/design_tokens.dart';

class GeeTestCaptchaDialog extends StatefulWidget {
  final String captchaId;

  const GeeTestCaptchaDialog({super.key, required this.captchaId});

  @override
  State<GeeTestCaptchaDialog> createState() => _GeeTestCaptchaDialogState();
}

class _GeeTestCaptchaDialogState extends State<GeeTestCaptchaDialog> {
  late final WebViewController _controller;
  String _status = '正在加载滑块验证码...';
  bool _loading = true;
  bool _completed = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(Colors.transparent)
      ..addJavaScriptChannel(
        'CaptchaBridge',
        onMessageReceived: _handleBridgeMessage,
      )
      ..loadHtmlString(
        _buildHtml(widget.captchaId),
        baseUrl: 'https://static.geetest.com',
      );
  }

  void _handleBridgeMessage(JavaScriptMessage message) {
    if (!mounted || _completed) {
      return;
    }

    try {
      final decoded = jsonDecode(message.message);
      final data = decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
      final type = data['type']?.toString() ?? '';
      switch (type) {
        case 'ready':
          setState(() {
            _loading = false;
            _status = '请拖动滑块完成验证';
          });
          return;
        case 'success':
          final payload = _normalizePayload(data['payload']);
          if (payload == null) {
            setState(() {
              _loading = false;
              _status = '验证码结果为空，请重试';
            });
            return;
          }
          _completed = true;
          Navigator.of(context).pop(payload);
          return;
        case 'close':
          _completed = true;
          Navigator.of(context).pop();
          return;
        case 'error':
          setState(() {
            _loading = false;
            _status = data['message']?.toString() ?? '验证码加载失败，请重试';
          });
          return;
      }
    } catch (_) {
      setState(() {
        _loading = false;
        _status = '验证码通信异常，请重试';
      });
    }
  }

  Map<String, dynamic>? _normalizePayload(dynamic raw) {
    if (raw is! Map) {
      return null;
    }
    final payload = Map<String, dynamic>.from(raw);
    final result = {
      'lot_number': payload['lot_number']?.toString() ?? '',
      'captcha_output': payload['captcha_output']?.toString() ?? '',
      'pass_token': payload['pass_token']?.toString() ?? '',
      'gen_time': payload['gen_time']?.toString() ?? '',
    };
    if (result.values.any((value) => value.trim().isEmpty)) {
      return null;
    }
    return result;
  }

  String _buildHtml(String captchaId) {
    final encodedCaptchaId = jsonEncode(captchaId);
    return '''
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1">
  <style>
    html, body {
      width: 100%;
      height: 100%;
      margin: 0;
      background: transparent;
      font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif;
      overflow: hidden;
    }
    #stage {
      min-height: 100%;
      display: flex;
      align-items: center;
      justify-content: center;
      color: #64748b;
      font-size: 14px;
      text-align: center;
      padding: 24px;
      box-sizing: border-box;
    }
  </style>
  <script src="https://static.geetest.com/v4/gt4.js"></script>
</head>
<body>
  <div id="stage">正在准备安全验证...</div>
  <script>
    function send(type, payload) {
      if (window.CaptchaBridge) {
        window.CaptchaBridge.postMessage(JSON.stringify({
          type: type,
          payload: payload || null,
          message: payload && payload.message ? payload.message : ''
        }));
      }
    }
    window.onerror = function(message) {
      send('error', { message: String(message || '验证码加载失败') });
    };
    function startCaptcha() {
      if (typeof initGeetest4 !== 'function') {
        send('error', { message: '极验 SDK 加载失败，请检查网络' });
        return;
      }
      initGeetest4({
        captchaId: $encodedCaptchaId,
        https: true,
        product: 'bind',
        language: 'zho'
      }, function(captchaObj) {
        captchaObj
          .onReady(function() {
            send('ready');
            captchaObj.showCaptcha();
          })
          .onSuccess(function() {
            send('success', captchaObj.getValidate());
          })
          .onError(function(error) {
            send('error', { message: error && error.msg ? error.msg : '验证码异常，请重试' });
          });
        if (captchaObj.onClose) {
          captchaObj.onClose(function() {
            send('close');
          });
        }
      });
    }
    if (document.readyState === 'complete') {
      startCaptcha();
    } else {
      window.addEventListener('load', startCaptcha);
    }
  </script>
</body>
</html>
''';
  }

  @override
  Widget build(BuildContext context) {
    final isLight = Theme.of(context).brightness == Brightness.light;
    final textColor = isLight ? AppColors.slate600 : AppColors.slate300;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 18, vertical: 24),
      child: SizedBox(
        width: 420,
        height: 520,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(18, 16, 18, 18),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(
                      color: AppColors.primary.withAlpha(20),
                      // 图标底板一律走 sm，不跟外层弹窗（lg）同档。
                      borderRadius: BorderRadius.circular(AppRadius.sm),
                    ),
                    child: const Icon(
                      Icons.verified_user_outlined,
                      size: 18,
                      color: AppColors.primary,
                    ),
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      '安全验证',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.of(context).pop(),
                    icon: const Icon(Icons.close, size: 20),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(_status, style: TextStyle(fontSize: 13, color: textColor)),
              const SizedBox(height: 12),
              Expanded(
                child: ClipRRect(
                  // ⚠️ 嵌套：外层 Dialog 走 lg(14)。WebView 面板是弹窗里的
                  // 内嵌块，必须比外层小一档，否则内外两个角一样大。
                  borderRadius: BorderRadius.circular(AppRadius.md),
                  child: Stack(
                    children: [
                      WebViewWidget(controller: _controller),
                      if (_loading)
                        const Center(
                          child: CircularProgressIndicator(
                            color: AppColors.primary,
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
