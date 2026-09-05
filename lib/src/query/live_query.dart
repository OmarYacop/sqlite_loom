import 'dart:async';

import '../model/table.dart';
import 'change.dart';

/// Coalesces dependency invalidations while asynchronously reloading a value.
final class DbLiveQuery<T> {
  DbLiveQuery({
    required Stream<DbChangeSet> changes,
    required Set<DbTableId> dependencies,
    Set<Object?>? keys,
    required Future<T> Function() load,
    required bool Function(T left, T right) equals,
  }) : _changes = changes,
       _dependencies = Set.unmodifiable(dependencies),
       _keys = keys == null ? null : Set.unmodifiable(keys),
       _load = load,
       _equals = equals;

  final Stream<DbChangeSet> _changes;
  final Set<DbTableId> _dependencies;
  final Set<Object?>? _keys;
  final Future<T> Function() _load;
  final bool Function(T left, T right) _equals;

  Stream<T> get stream {
    late StreamController<T> controller;
    StreamSubscription<DbChangeSet>? subscription;
    var active = true;
    var dirty = false;
    var running = false;
    var hasValue = false;
    T? lastValue;

    Future<void> pump() async {
      if (running || !active) {
        dirty = true;
        return;
      }
      running = true;
      dirty = true;
      try {
        while (dirty && active) {
          dirty = false;
          final next = await _load();
          if (!active) {
            return;
          }
          final shouldEmit = !hasValue || !_equals(lastValue as T, next);
          if (shouldEmit) {
            hasValue = true;
            lastValue = next;
            controller.add(next);
          }
        }
      } catch (error, stackTrace) {
        if (active) {
          controller.addError(error, stackTrace);
        }
      } finally {
        running = false;
        if (dirty && active) {
          unawaited(pump());
        }
      }
    }

    controller = StreamController<T>(
      onListen: () {
        subscription = _changes.listen((changeSet) {
          if (_isAffected(changeSet)) {
            dirty = true;
            unawaited(pump());
          }
        }, onError: controller.addError);
        unawaited(pump());
      },
      onCancel: () async {
        active = false;
        await subscription?.cancel();
      },
    );

    return controller.stream;
  }

  bool _isAffected(DbChangeSet changeSet) {
    if (!changeSet.affects(_dependencies)) return false;
    final keys = _keys;
    if (keys == null) return true;
    for (final table in _dependencies) {
      final change = changeSet[table];
      if (change == null) continue;
      if (change.keys == null || change.keys!.any(keys.contains)) return true;
    }
    return false;
  }
}
