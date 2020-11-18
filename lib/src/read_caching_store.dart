// ignore_for_file: unawaited_futures
import 'dart:async';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:hive/hive.dart';

import 'auto_renew_stream.dart';
import 'filter.dart';
import 'store.dart';
import 'store_event.dart';

enum ReloadStrategy {
  clear,
  compareKey,
  compareValue,
}

class OfflineException implements Exception {
  @override
  String toString() => 'The operation cannot be executed - device is offline';
}

class ReadCachingStore<T> {
  final FirebaseStore<T> store;
  final Box<T> box;

  bool awaitBoxOperations = false;
  ReloadStrategy reloadStrategy = ReloadStrategy.compareKey;

  ReadCachingStore(this.store, this.box);

  Future<void> reload([Filter filter]) async {
    await _checkOnline();
    final newValues =
        await (filter != null ? store.query(filter) : store.all());
    await _reset(newValues);
  }

  Future<T> fetch(String key) async {
    await _checkOnline();
    final value = await store.read(key);
    await _boxAwait(box.put(key, value));
    return value;
  }

  Future<T> patch(String key, Map<String, dynamic> updateFields) async {
    await _checkOnline();
    final value = await store.update(key, updateFields);
    await _boxAwait(box.put(key, value));
    return value;
  }

  Future<T> transaction(String key, TransactionCallback<T> transaction) async {
    await _checkOnline();
    final value = await store.transaction(key, transaction);
    await _boxAwait(box.put(key, value));
    return value;
  }

  Future<StreamSubscription<void>> stream({
    Filter filter,
    bool clearCache = true,
    Function onError,
    void Function() onDone,
    bool cancelOnError = true,
  }) async {
    if (clearCache) {
      box.clear();
    }
    final stream =
        await (filter != null ? store.streamQuery(filter) : store.streamAll());
    return stream.listen(
      _handleStreamEvent,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  StreamSubscription<void> streamRenewed({
    FutureOr<Filter> Function() onRenewFilter,
    bool clearCache = true,
    Function onError,
    void Function() onDone,
    bool cancelOnError = true,
  }) {
    if (clearCache) {
      box.clear();
    }
    return AutoRenewStream(() async {
      final filter = onRenewFilter != null ? (await onRenewFilter()) : null;
      return filter != null ? store.streamQuery(filter) : store.streamAll();
    }).listen(
      _handleStreamEvent,
      onError: onError,
      onDone: onDone,
      cancelOnError: cancelOnError,
    );
  }

  Future<String> add(T value) async {
    await _checkOnline();
    final key = await store.create(value);
    await box.put(key, value);
    return key;
  }

  Future<int> clear() => box.clear();

  Future<void> close() => box.close();

  Future<void> compact() => box.close();

  bool containsKey(covariant String key) => box.containsKey(key);

  Future<void> delete(covariant String key) async {
    await _checkOnline();
    await store.delete(key, silent: true);
    await _boxAwait(box.delete(key));
  }

  Future<void> deleteFromDisk() => box.deleteFromDisk();

  T get(covariant String key, {T defaultValue}) =>
      box.get(key, defaultValue: defaultValue);

  bool get isEmpty => box.isEmpty;

  bool get isNotEmpty => box.isNotEmpty;

  bool get isOpen => box.isOpen;

  Iterable<String> get keys => box.keys.cast<String>();

  bool get lazy => box.lazy; // TODO enable or remove

  int get length => box.length;

  String get name => box.name;

  String get path => box.path;

  Future<void> put(covariant String key, T value) async {
    await _checkOnline();
    final savedValue = await store.write(key, value);
    await _boxAwait(box.put(key, savedValue));
  }

  Map<String, T> toMap() => box.toMap().cast<String, T>();

  Iterable<T> get values => box.values;

  Iterable<T> valuesBetween({
    covariant String startKey,
    covariant String endKey,
  }) =>
      box.valuesBetween(startKey: startKey, endKey: endKey);

  Stream<BoxEvent> watch({covariant String key}) => box.watch(key: key);

  @protected
  FutureOr<bool> isOnline() => true;

  Future _checkOnline() async {
    if (!await isOnline()) {
      throw OfflineException();
    }
  }

  Future<void> _boxAwait(Future<void> future) =>
      awaitBoxOperations ? future : Future<void>.value();

  Future<void> _reset(Map<String, T> data) async {
    switch (reloadStrategy) {
      case ReloadStrategy.clear:
        final fClear = box.clear();
        final fPut = box.putAll(data);
        await _boxAwait(Future.wait([fClear, fPut]));
        break;
      case ReloadStrategy.compareKey:
        final oldKeys = box.keys.toSet();
        final deletedKeys = oldKeys.difference(data.keys.toSet());
        await _boxAwait(Future.wait([
          box.putAll(data),
          box.deleteAll(deletedKeys),
        ]));
        break;
      case ReloadStrategy.compareValue:
        final oldKeys = box.keys.toSet();
        final deletedKeys = oldKeys.difference(data.keys.toSet());
        data.removeWhere(
          (key, value) => box.get(key) == value,
        );
        await _boxAwait(Future.wait([
          box.putAll(data),
          box.deleteAll(deletedKeys),
        ]));
        break;
    }
  }

  Future<void> _handleStreamEvent(StoreEvent<T> event) => event.when(
        reset: (data) => _reset(data),
        put: (key, value) => _boxAwait(box.put(key, value)),
        delete: (key) => _boxAwait(box.delete(key)),
        patch: (key, value) => _boxAwait(box.put(
          key,
          value.apply(box.get(key)),
        )),
      );
}
