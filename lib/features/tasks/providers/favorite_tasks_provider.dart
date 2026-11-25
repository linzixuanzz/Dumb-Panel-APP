import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/network/dio_client.dart';
import '../../../core/storage/secure_storage.dart';
import '../../../shared/models/task.dart';

/// 常用任务（APP v2.0 · A1）：任务页顶部那几张缺口卡片，最多 [maxCount] 个。
///
/// - state 就是任务 id 列表，顺序 = 卡片顺序；
/// - 只存在本机，**按面板区分**：同一个 id 在两台面板上是两条不相干的任务，
///   键是 `tasks.favorites::<面板 scope>`（scope 同 token 用的 `SecureStorage.scopeOf`），
///   实际落在 SharedPreferences 的 `ui_state_tasks.favorites::<scope>`；
/// - 切面板后由 [syncScope] / [prune] 发现「当前面板变了」并重新读一份
///   （`invalidateServerScopedProviders` 也应当把本 provider 一起作废，见交接说明）。
///
/// 写操作都是同步改 state、后台落盘：调用方（详情弹层、长按菜单）不用 await。
class FavoriteTasksNotifier extends StateNotifier<List<int>> {
  FavoriteTasksNotifier() : super(const []) {
    _scope = _currentScope();
    _loading = _load(_scope);
  }

  static const int maxCount = 5;
  static const String storageKey = 'tasks.favorites';

  /// 当前这份 state 属于哪台面板。
  late String _scope;

  /// 读盘还没回来时用户就点了「加入常用」：读回来时要合并，不能直接覆盖。
  bool _touchedBeforeLoaded = false;
  bool _loaded = false;
  late Future<void> _loading;

  /// 最近一次在列表里见过的任务快照（不进 state、不落盘）。
  ///
  /// 任务列表带着筛选时，常用任务可能不在 `taskProvider.tasks` 里；卡片和
  /// 快捷方式靠这里拿名字和状态。切面板时清空。
  final Map<int, Task> _snapshots = <int, Task>{};

  static String _currentScope() {
    final url = DioClient.instance.baseUrl.trim();
    return url.isEmpty ? 'default' : SecureStorage.scopeOf(url);
  }

  static String _keyOf(String scope) => '$storageKey::$scope';

  Future<void> _load(String scope) async {
    final raw = await SecureStorage.getUiStateList(_keyOf(scope));
    // 读盘期间面板又换了：这份已经过期，交给新的那次读
    if (!mounted || scope != _scope) {
      return;
    }
    final loaded = <int>[];
    for (final item in raw) {
      final id = int.tryParse(item.trim());
      if (id != null && id > 0 && !loaded.contains(id)) {
        loaded.add(id);
      }
    }
    if (_touchedBeforeLoaded) {
      // 读盘前已经改过：以刚才的改动为准，再把盘上原有的补在后面
      final merged = [...state];
      for (final id in loaded) {
        if (!merged.contains(id)) merged.add(id);
      }
      state = merged.take(maxCount).toList();
      _save();
    } else {
      state = loaded.take(maxCount).toList();
    }
    _loaded = true;
  }

  void _save() {
    SecureStorage.saveUiStateList(
      _keyOf(_scope),
      state.map((id) => '$id').toList(),
    );
  }

  void _set(List<int> next) {
    state = next;
    if (!_loaded) {
      // 读盘还没回来：这时写盘会抢在读之前把盘上原有的覆盖掉，留给 _load 合并后统一写
      _touchedBeforeLoaded = true;
      return;
    }
    _save();
  }

  /// 面板换了就丢掉旧面板的 id 和快照，重新读当前面板那一份。返回是否换过。
  bool syncScope() {
    final scope = _currentScope();
    if (scope == _scope) {
      return false;
    }
    _scope = scope;
    _loaded = false;
    _touchedBeforeLoaded = false;
    _snapshots.clear();
    state = const [];
    _loading = _load(scope);
    return true;
  }

  /// 这份 state 是不是当前面板的。切完面板、还没 [syncScope] 之前是 false：
  /// 这时 state 里还是上一台面板的 id，页面应当先当作没有常用任务。
  bool get isCurrentScope => _scope == _currentScope();

  bool isFavorite(int id) => state.contains(id);

  /// 加入 / 移出常用。已满 [maxCount] 个时不加、返回 false；其余情况（加入或移出成功）返回 true。
  bool toggle(int id) {
    if (state.contains(id)) {
      _set([...state]..remove(id));
      return true;
    }
    if (state.length >= maxCount) {
      return false;
    }
    _set([...state, id]);
    return true;
  }

  void remove(int id) {
    if (!state.contains(id)) {
      return;
    }
    _set([...state]..remove(id));
  }

  /// 调整卡片顺序。下标口径同 `ReorderableListView.onReorder`：
  /// [newIndex] 是「移除之前」的位置，往后拖时这里会先减一。
  void reorder(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= state.length) {
      return;
    }
    if (newIndex > oldIndex) {
      newIndex--;
    }
    newIndex = newIndex.clamp(0, state.length - 1);
    if (newIndex == oldIndex) {
      return;
    }
    final next = [...state];
    final id = next.removeAt(oldIndex);
    next.insert(newIndex, id);
    _set(next);
  }

  /// 剔除已经不存在的任务（被删了）。
  ///
  /// [existingIds] 必须是**没加任何筛选**时拿到的全量任务 id，否则会把只是被筛掉的任务误删。
  /// 调用前先确认当前面板：面板换了就先换成新面板的那份，再按新面板的任务剔除。
  Future<void> prune(Set<int> existingIds) async {
    syncScope();
    await _loading;
    if (!mounted) {
      return;
    }
    final next = state.where(existingIds.contains).toList();
    _snapshots.removeWhere((id, _) => !existingIds.contains(id));
    if (next.length != state.length) {
      _set(next);
    }
  }

  /// 记下列表里出现的常用任务（见 [_snapshots]）。不改 state，不触发重建。
  void remember(Iterable<Task> tasks) {
    for (final task in tasks) {
      if (state.contains(task.id)) {
        _snapshots[task.id] = task;
      }
    }
  }

  /// 最近一次见过的任务快照；从没见过返回 null。
  Task? snapshotOf(int id) => _snapshots[id];
}

final favoriteTasksProvider =
    StateNotifierProvider<FavoriteTasksNotifier, List<int>>(
      (ref) => FavoriteTasksNotifier(),
    );
