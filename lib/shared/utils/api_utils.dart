/// 从 API 响应中提取 data 字段
/// 后端格式：response.Success() 直接输出，某些接口用 gin.H{"data": ...} 包了一层
dynamic extractData(dynamic responseData) {
  if (responseData is Map<String, dynamic> &&
      responseData.containsKey('data')) {
    return responseData['data'];
  }
  return responseData;
}

/// 从分页响应中提取列表和总数
/// 后端 response.Paginated() 格式: {data: [...], total: N, page: N, page_size: N}
({List<Map<String, dynamic>> items, int total}) extractPaginated(
  dynamic responseData,
) {
  if (responseData is Map<String, dynamic>) {
    final dataField = responseData['data'];
    // {data: [...], total: N} — 标准分页格式
    if (dataField is List) {
      final items = dataField.whereType<Map<String, dynamic>>().toList();
      final total = _toInt(responseData['total']) ?? items.length;
      return (items: items, total: total);
    }
    // 兜底：{data: {data: [...], total: N}}
    if (dataField is Map<String, dynamic>) {
      final innerList = dataField['data'];
      if (innerList is List) {
        final items = innerList.whereType<Map<String, dynamic>>().toList();
        final total = _toInt(dataField['total']) ?? items.length;
        return (items: items, total: total);
      }
    }
  }
  // 直接是列表
  if (responseData is List) {
    final items = responseData.whereType<Map<String, dynamic>>().toList();
    return (items: items, total: items.length);
  }
  return (items: <Map<String, dynamic>>[], total: 0);
}

/// 从 API 错误响应中提取可读的错误信息
/// 兼容 Dio 异常和一般异常，优先返回后端返回的 error/message 字段
String extractErrorMessage(dynamic error, String fallback) {
  try {
    final data = (error as dynamic).response?.data;
    if (data is Map) {
      final msg = data['error'] ?? data['message'];
      if (msg != null && msg.toString().trim().isNotEmpty) {
        return msg.toString().trim();
      }
    }
  } catch (_) {}
  try {
    final message = (error as dynamic).message;
    if (message is String && message.trim().isNotEmpty) {
      return message.trim();
    }
  } catch (_) {}
  return fallback;
}

/// 列表页加载失败时用的错误文案。
///
/// 与 [extractErrorMessage] 的区别：后者在没有后端 error/message 字段时会退回
/// `DioException.message`，那是一串英文（"The connection errored: Failed host
/// lookup..." / "The request returned an invalid status code of 500."）。
/// 列表页的错误态是直接摊在屏幕中央给用户看的，断网时不能甩一句英文。
///
/// 优先级：后端返回的 error/message 原文 > 按 DioException 类型给中文说明 > [fallback]。
String extractListErrorMessage(dynamic error, String fallback) {
  final backendMessage = _extractBackendMessage(error);
  if (backendMessage != null) {
    return backendMessage;
  }

  final status = _statusCode(error);
  switch (_dioExceptionType(error)) {
    case 'connectionTimeout':
    case 'sendTimeout':
    case 'receiveTimeout':
      return '连接面板超时，请检查网络或面板地址';
    case 'connectionError':
      // dio 5.x 把断网的 SocketException 归到这一类。
      return '无法连接到面板，请检查网络或面板是否在线';
    case 'badCertificate':
      return '面板证书校验失败，请检查 HTTPS 配置';
    case 'cancel':
      return '请求已取消';
    case 'badResponse':
      return status == null ? fallback : '面板返回错误（HTTP $status）';
    default:
      return fallback;
  }
}

String? _extractBackendMessage(dynamic error) {
  try {
    final data = (error as dynamic).response?.data;
    if (data is Map) {
      final msg = data['error'] ?? data['message'];
      if (msg != null && msg.toString().trim().isNotEmpty) {
        return msg.toString().trim();
      }
    }
  } catch (_) {}
  return null;
}

String? _dioExceptionType(dynamic error) {
  try {
    final type = (error as dynamic).type;
    if (type == null) return null;
    // 不 import dio，按名字比对即可（DioExceptionType.connectionError 之类）。
    final text = type.toString();
    final dot = text.lastIndexOf('.');
    return dot >= 0 ? text.substring(dot + 1) : text;
  } catch (_) {
    return null;
  }
}

int? _statusCode(dynamic error) {
  try {
    final status = (error as dynamic).response?.statusCode;
    return status is int ? status : null;
  } catch (_) {
    return null;
  }
}

String extractScriptSaveErrorMessage(dynamic error, String fallback) {
  final raw = extractErrorMessage(error, fallback).trim();
  if (raw.isEmpty) {
    return fallback;
  }

  if (raw.contains('当前路径是目录')) {
    return '当前选中的是目录，不是可编辑脚本文件';
  }
  if (raw.contains('文件不存在')) {
    return '脚本不存在，可能已被删除、重命名或移动';
  }
  if (raw.contains('不允许路径穿越') ||
      raw.contains('检测到路径穿越') ||
      raw.contains('路径包含非法字符')) {
    return '脚本路径无效，请刷新脚本树后重试';
  }
  if (raw.contains('二进制') || raw.contains('binary')) {
    return '当前文件是二进制内容，暂不支持在线保存';
  }
  if (raw.contains('写入文件失败') || raw.contains('创建目标目录失败')) {
    return '$raw，请检查面板数据目录挂载和写入权限';
  }
  if (raw.contains('ERR_REQUIRE_ESM') ||
      (raw.contains('ES Module') && raw.contains('require()'))) {
    return '依赖已安装，但当前模块是 ESM 格式，脚本仍在使用 require() 加载，请改用 import() 或安装兼容旧写法的版本';
  }

  return raw;
}

/// 安全转 int
int? _toInt(dynamic v) {
  if (v == null) return null;
  if (v is int) return v;
  if (v is num) return v.toInt();
  return int.tryParse(v.toString());
}
