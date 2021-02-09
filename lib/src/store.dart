import 'dart:async';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:meta/meta.dart';

import '../firebase_database_rest.dart';
import 'auth_revoked_exception.dart';
import 'models/api_constants.dart';
import 'models/db_response.dart';
import 'models/filter.dart';
import 'models/post_response.dart';
import 'models/stream_event.dart';
import 'patch_on_null_error.dart';
import 'rest_api.dart';
import 'store_event.dart';
import 'transaction.dart';

class ETagReceiver {
  String? _eTag;

  String? get eTag => _eTag;

  @override
  String toString() => 'ETag: $eTag';

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) {
      return true;
    }

    return other is ETagReceiver && eTag == other.eTag;
  }

  @override
  int get hashCode => runtimeType.hashCode ^ (eTag?.hashCode ?? 0);
}

typedef DataFromJsonCallback<T> = T Function(dynamic json);

typedef DataToJsonCallback<T> = dynamic Function(T data);

typedef PatchDataCallback<T> = T Function(
  T data,
  Map<String, dynamic> updatedFields,
);

abstract class FirebaseStore<T> {
  static const loggingTag = 'firebase_database_rest.FirebaseStore';

  final RestApi restApi;
  final List<String> subPaths;
  String get path => _path();

  @protected
  FirebaseStore({
    required FirebaseStore<dynamic> parent,
    required String path,
  })   : restApi = parent.restApi,
        subPaths = [...parent.subPaths, path];

  @protected
  FirebaseStore.api({
    required this.restApi,
    required this.subPaths,
  });

  factory FirebaseStore.create({
    required FirebaseStore<dynamic> parent,
    required String path,
    required DataFromJsonCallback<T> onDataFromJson,
    required DataToJsonCallback<T> onDataToJson,
    required PatchDataCallback<T> onPatchData,
  }) = _CallbackFirebaseStore;

  factory FirebaseStore.apiCreate({
    required RestApi restApi,
    required List<String> subPaths,
    required DataFromJsonCallback<T> onDataFromJson,
    required DataToJsonCallback<T> onDataToJson,
    required PatchDataCallback<T> onPatchData,
  }) = _CallbackFirebaseStore.api;

  FirebaseStore<U> subStore<U>({
    required String path,
    required DataFromJsonCallback<U> onDataFromJson,
    required DataToJsonCallback<U> onDataToJson,
    required PatchDataCallback<U> onPatchData,
  }) =>
      FirebaseStore.create(
        parent: this,
        path: path,
        onDataFromJson: onDataFromJson,
        onDataToJson: onDataToJson,
        onPatchData: onPatchData,
      );

  Future<List<String>> keys({ETagReceiver? eTagReceiver}) async {
    final response = await restApi.get(
      path: _path(),
      shallow: true,
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return (response.data as Map<String, dynamic>?)?.keys.toList() ?? [];
  }

  Future<Map<String, T>> all({ETagReceiver? eTagReceiver}) async {
    final response = await restApi.get(
      path: _path(),
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return _mapTransform(response.data);
  }

  Future<T?> read(String key, {ETagReceiver? eTagReceiver}) async {
    final response = await restApi.get(
      path: _path(key),
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return dataFromJson(response.data);
  }

  Future<T?> write(
    String key,
    T data, {
    bool silent = false,
    String? eTag,
    ETagReceiver? eTagReceiver,
  }) async {
    final response = await restApi.put(
      dataToJson(data),
      path: _path(key),
      printMode: silent ? PrintMode.silent : null,
      ifMatch: eTag,
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return silent ? null : dataFromJson(response.data);
  }

  Future<String> create(T data, {ETagReceiver? eTagReceiver}) async {
    final response = await restApi.post(
      dataToJson(data),
      path: _path(),
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    final result = PostResponse.fromJson(response.data as Map<String, dynamic>);
    return result.name;
  }

  Future<T?> update(
    String key,
    Map<String, dynamic> updateFields, {
    bool silent = false,
  }) async {
    final response = await restApi.patch(
      updateFields,
      path: _path(key),
      printMode: silent ? PrintMode.silent : null,
    );
    return silent ? null : dataFromJson(response.data);
  }

  Future<T?> delete(
    String key, {
    bool silent = false,
    String? eTag,
    ETagReceiver? eTagReceiver,
  }) async {
    final response = await restApi.delete(
      path: _path(key),
      printMode: silent ? PrintMode.silent : null,
      ifMatch: eTag,
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return silent ? null : dataFromJson(response.data);
  }

  Future<Map<String, T>> query(
    Filter filter, {
    ETagReceiver? eTagReceiver,
  }) async {
    final response = await restApi.get(
      path: _path(),
      filter: filter,
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return _mapTransform(response.data);
  }

  Future<List<String>> queryKeys(
    Filter filter, {
    ETagReceiver? eTagReceiver,
  }) async {
    final response = await restApi.get(
      path: _path(),
      filter: filter,
      shallow: true,
      eTag: eTagReceiver != null,
    );
    _applyETag(eTagReceiver, response);
    return (response.data as Map<String, dynamic>?)?.keys.toList() ?? [];
  }

  Future<FirebaseTransaction<T>> transaction(
    String key, {
    bool silent = false,
    ETagReceiver? eTagReceiver,
  }) async {
    final response = await restApi.get(
      path: _path(key),
      eTag: true,
    );
    return _StoreTransaction(
      store: this,
      key: key,
      value: dataFromJson(response.data),
      eTag: response.eTag!,
      silent: silent,
      eTagReceiver: eTagReceiver,
    );
  }

  Future<Stream<StoreEvent<T>>> streamAll() async {
    final stream = await restApi.stream(
      path: _path(),
    );
    return _transformKeyValuePairs(stream);
  }

  Future<Stream<DataEvent<String>>> streamKeys() async {
    final stream = await restApi.stream(
      path: _path(),
      shallow: true,
    );
    return _transformKeys(stream);
  }

  Future<Stream<DataEvent<T>>> streamEntry(String key) async {
    final stream = await restApi.stream(
      path: _path(key),
    );
    return _transformValues(stream);
  }

  Future<Stream<StoreEvent<T>>> streamQuery(Filter filter) async {
    final stream = await restApi.stream(
      path: _path(),
      filter: filter,
    );
    return _transformKeyValuePairs(stream);
  }

  Future<Stream<DataEvent<String>>> streamQueryKeys(Filter filter) async {
    final stream = await restApi.stream(
      path: _path(),
      filter: filter,
      shallow: true,
    );
    return _transformKeys(stream);
  }

  @protected
  T dataFromJson(dynamic? json); // can be null

  @protected
  dynamic? dataToJson(T data); // can be null

  @protected
  T patchData(T data, Map<String, dynamic> updatedFields);

  String _path([String? key]) =>
      (key != null ? [...subPaths, key] : subPaths).join('/');

  void _applyETag(ETagReceiver? eTagReceiver, DbResponse response) {
    if (eTagReceiver != null) {
      assert(
        response.eTag != null,
        'ETag-Header must not be null when an ETag has been requested',
      );
      eTagReceiver._eTag = response.eTag;
    }
  }

  Map<String, T> _mapTransform(dynamic data) =>
      (data as Map<String, dynamic>?)?.map(
        (key, dynamic value) => MapEntry(
          key,
          dataFromJson(value),
        ),
      ) ??
      {};

  Stream<StoreEvent<T>> _transformKeyValuePairs(
    Stream<StreamEvent> stream,
  ) async* {
    final subPathRegexp = RegExp(r'^\/([^\/]+)$');

    await for (final event in stream) {
      yield* event.when(
        put: (path, dynamic data) async* {
          if (path == '/') {
            yield StoreEvent.reset(_mapTransform(data));
          } else {
            final match = subPathRegexp.firstMatch(path);
            if (match != null) {
              if (data != null) {
                yield StoreEvent.put(match[1]!, dataFromJson(data));
              } else {
                yield StoreEvent.delete(match[1]!);
              }
            } else {
              yield StoreEvent.invalid(_pathTooDeepMsg(path));
            }
          }
        },
        patch: (path, dynamic data) async* {
          final match = subPathRegexp.firstMatch(path);
          if (match != null) {
            yield StoreEvent.patch(
              match[1]!,
              _StorePatchSet(
                this,
                data as Map<String, dynamic>? ?? const <String, dynamic>{},
              ),
            );
          } else {
            yield StoreEvent.invalid(_pathTooDeepMsg(path));
          }
        },
        authRevoked: () => throw AuthRevokedException(),
        unknown: (event, data) async* {
          yield StoreEvent.invalid(_unknownEventMsg(event, data));
        },
      );
    }
  }

  Stream<DataEvent<String>> _transformKeys(Stream<StreamEvent> stream) async* {
    final subPathRegexp = RegExp(r'^\/([^\/]+)$');

    await for (final event in stream) {
      yield* event.when(
        put: (path, dynamic data) async* {
          if (path == '/') {
            yield const DataEvent.clear();
          } else {
            final match = subPathRegexp.firstMatch(path);
            if (match != null) {
              yield DataEvent.value(match[1]!);
            } else {
              yield DataEvent.invalid(_pathTooDeepMsg(path));
            }
          }
        },
        patch: (path, dynamic data) async* {
          final match = subPathRegexp.firstMatch(path);
          if (match != null) {
            yield DataEvent.value(match[1]!);
          } else {
            yield DataEvent.invalid(_pathTooDeepMsg(path));
          }
        },
        authRevoked: () => throw AuthRevokedException(),
        unknown: (event, data) async* {
          yield DataEvent.invalid(_unknownEventMsg(event, data));
        },
      );
    }
  }

  Stream<DataEvent<T>> _transformValues(Stream<StreamEvent> stream) async* {
    T? currentValue;
    await for (final event in stream) {
      final streamEvent = event.when<DataEvent<T>>(
        put: (path, dynamic data) {
          if (path == '/') {
            return DataEvent.value(dataFromJson(data));
          } else {
            return DataEvent.invalid(_pathTooDeepMsg(path));
          }
        },
        patch: (path, dynamic data) {
          if (path == '/') {
            if (currentValue == null) {
              throw PatchOnNullError();
            }
            return DataEvent.value(patchData(
              currentValue,
              data as Map<String, dynamic>? ?? const <String, dynamic>{},
            ));
          } else {
            return DataEvent.invalid(_pathTooDeepMsg(path));
          }
        },
        authRevoked: () => throw AuthRevokedException(),
        unknown: (event, data) =>
            DataEvent.invalid(_unknownEventMsg(event, data)),
      );
      currentValue = streamEvent.when(
        clear: () => null,
        value: (value) => value,
        invalid: (_) => currentValue,
      );
      yield streamEvent;
    }
  }

  String _pathTooDeepMsg(String path) =>
      'Skipping stream event with path "$path", path is too deep';

  String _unknownEventMsg(String event, String data) =>
      'Received unknown server event "$event" with data: $data';
}

class _CallbackFirebaseStore<T> extends FirebaseStore<T> {
  final DataFromJsonCallback<T> onDataFromJson;
  final DataToJsonCallback<T> onDataToJson;
  final PatchDataCallback<T> onPatchData;

  _CallbackFirebaseStore({
    required FirebaseStore<dynamic> parent,
    required String path,
    required this.onDataFromJson,
    required this.onDataToJson,
    required this.onPatchData,
  }) : super(
          parent: parent,
          path: path,
        );

  _CallbackFirebaseStore.api({
    required RestApi restApi,
    required List<String> subPaths,
    required this.onDataFromJson,
    required this.onDataToJson,
    required this.onPatchData,
  }) : super.api(
          restApi: restApi,
          subPaths: subPaths,
        );

  @override
  T dataFromJson(dynamic? json) => onDataFromJson(json);

  @override
  dynamic? dataToJson(T data) => onDataToJson(data);

  @override
  T patchData(T data, Map<String, dynamic> updatedFields) =>
      onPatchData(data, updatedFields);
}

class _StorePatchSet<T> implements PatchSet<T> {
  final FirebaseStore<T> store;
  final Map<String, dynamic> data;

  const _StorePatchSet(this.store, this.data);

  @override
  T apply(T value) => store.patchData(value, data);

  @override
  String toString() => 'PatchSet($data)';

  @override
  bool operator ==(dynamic other) {
    if (identical(this, other)) {
      return true;
    }
    if (other is! _StorePatchSet<T>) {
      return false;
    }
    return store == other.store &&
        (identical(data, other.data) ||
            const DeepCollectionEquality().equals(data, other.data));
  }

  @override
  int get hashCode =>
      runtimeType.hashCode ^
      store.hashCode ^
      const DeepCollectionEquality().hash(data);
}

class _StoreTransaction<T> extends SingleCommitTransaction<T> {
  final FirebaseStore<T> store;

  @override
  final String key;

  @override
  final T value;

  @override
  final String eTag;

  final bool silent;
  final ETagReceiver? eTagReceiver;

  _StoreTransaction({
    required this.store,
    required this.key,
    required this.value,
    required this.eTag,
    required this.silent,
    required this.eTagReceiver,
  });

  @override
  Future<T?> commitUpdateImpl(T data) async {
    final response = await store.restApi.put(
      store.dataToJson(data),
      path: store._path(key),
      printMode: silent ? PrintMode.silent : null,
      ifMatch: eTag,
      eTag: eTagReceiver != null,
    );
    store._applyETag(eTagReceiver, response);
    return silent ? null : store.dataFromJson(response.data);
  }

  @override
  Future<void> commitDeleteImpl() async {
    final response = await store.restApi.delete(
      path: store._path(key),
      printMode: PrintMode.silent,
      ifMatch: eTag,
      eTag: eTagReceiver != null,
    );
    store._applyETag(eTagReceiver, response);
  }
}
