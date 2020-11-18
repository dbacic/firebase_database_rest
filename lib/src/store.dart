import 'dart:async';

import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:logging/logging.dart';

import 'auth_revoked_exception.dart';
import 'filter.dart';
import 'models/post_response.dart';
import 'models/stream_event.dart';
import 'rest_api.dart';
import 'store_event.dart';
import 'transaction_result.dart';

class PatchOnNullError extends Error {
  final String key;

  PatchOnNullError([this.key]);

  @override
  String toString() => key != null
      ? 'Cannot patch a non existant entry, '
          'no value with key: ${Error.safeToString(key)}'
      : 'Cannot patch a non existant entry';
}

typedef TransactionCallback<T> = FutureOr<TransactionResult<T>> Function(
  T value,
);

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

  final Logger _logger;

  @protected
  FirebaseStore({
    @required FirebaseStore<dynamic> parent,
    @required String path,
    String loggingCategory = loggingTag,
  })  : restApi = parent.restApi,
        subPaths = [...parent.subPaths, path],
        _logger = loggingCategory != null ? Logger(loggingCategory) : null;

  @protected
  FirebaseStore.api({
    @required this.restApi,
    @required this.subPaths,
    String loggingCategory = loggingTag,
  }) : _logger = loggingCategory != null ? Logger(loggingCategory) : null;

  factory FirebaseStore.create({
    @required FirebaseStore<dynamic> parent,
    @required String path,
    @required DataFromJsonCallback<T> onDataFromJson,
    @required DataToJsonCallback<T> onDataToJson,
    @required PatchDataCallback<T> onPatchData,
    String loggingCategory,
  }) = _CallbackFirebaseStore;

  factory FirebaseStore.apiCreate({
    @required RestApi restApi,
    @required List<String> subPaths,
    @required DataFromJsonCallback<T> onDataFromJson,
    @required DataToJsonCallback<T> onDataToJson,
    @required PatchDataCallback<T> onPatchData,
    String loggingCategory,
  }) = _CallbackFirebaseStore.api;

  FirebaseStore<U> subStore<U>({
    @required String path,
    @required DataFromJsonCallback<U> onDataFromJson,
    @required DataToJsonCallback<U> onDataToJson,
    @required PatchDataCallback<U> onPatchData,
    String loggingCategory = loggingTag,
  }) =>
      FirebaseStore.create(
        parent: this,
        path: path,
        onDataFromJson: onDataFromJson,
        onDataToJson: onDataToJson,
        onPatchData: onPatchData,
        loggingCategory: loggingCategory,
      );

  Future<List<String>> keys() async {
    final response = await restApi.get(
      path: _path(),
      shallow: true,
    );
    return (response.data as Map<String, dynamic>).keys.toList();
  }

  Future<Map<String, T>> all() async {
    final response = await restApi.get(
      path: _path(),
    );
    return _mapTransform(response.data);
  }

  Future<T> read(String key) async {
    final response = await restApi.get(
      path: _path(key),
    );
    return dataFromJson(response.data);
  }

  Future<T> write(String key, T data, {bool silent = false}) async {
    final response = await restApi.put(
      dataToJson(data),
      path: _path(key),
      printMode: silent ? PrintMode.silent : null,
    );
    return silent ? null : dataFromJson(response.data);
  }

  Future<String> create(T data) async {
    final response = await restApi.post(
      dataToJson(data),
      path: _path(),
    );
    final result = PostResponse.fromJson(response.data as Map<String, dynamic>);
    return result.name;
  }

  Future<T> update(
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

  Future<T> delete(String key, {bool silent = false}) async {
    final response = await restApi.delete(
      path: _path(key),
      printMode: silent ? PrintMode.silent : null,
    );
    return silent ? null : dataFromJson(response.data);
  }

  Future<Map<String, T>> query(Filter filter) async {
    final response = await restApi.get(
      path: _path(),
      filter: filter,
    );
    return _mapTransform(response.data);
  }

  Future<T> transaction(
    String key,
    TransactionCallback<T> transaction, {
    bool silent = false,
  }) async {
    final getResponse = await restApi.get(
      path: _path(key),
      eTag: true,
    );
    final result = await transaction(dataFromJson(getResponse.data));
    return result.when(
      update: (data) async {
        final putResponse = await restApi.put(
          dataToJson(data),
          path: _path(key),
          printMode: silent ? PrintMode.silent : null,
          ifMatch: getResponse.eTag,
        );
        return silent ? null : dataFromJson(putResponse.data);
      },
      delete: () async {
        final deleteResponse = await restApi.delete(
          path: _path(key),
          printMode: silent ? PrintMode.silent : null,
          ifMatch: getResponse.eTag,
        );
        return silent ? null : dataFromJson(deleteResponse.data);
      },
      abort: () => null,
    );
  }

  Future<Stream<StoreEvent<T>>> streamAll() async {
    final stream = await restApi.stream(
      path: _path(),
    );
    return _transformKeyValuePairs(stream);
  }

  Future<Stream<T>> streamEntry(String key) async {
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

  @protected
  T dataFromJson(dynamic json);

  @protected
  dynamic dataToJson(T data);

  @protected
  T patchData(T data, Map<String, dynamic> updatedFields);

  String _path([String key]) =>
      (key != null ? [...subPaths, key] : subPaths).join('/');

  Map<String, T> _mapTransform(dynamic data) =>
      (data as Map<String, dynamic>).map(
        (key, dynamic value) => MapEntry(
          key,
          dataFromJson(value),
        ),
      );

  Stream<StoreEvent<T>> _transformKeyValuePairs(
      Stream<StreamEvent> stream) async* {
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
                yield StoreEvent.put(match[1], dataFromJson(data));
              } else {
                yield StoreEvent.delete(match[1]);
              }
            } else {
              _logPathTooDeep(path);
            }
          }
        },
        patch: (path, dynamic data) async* {
          final match = subPathRegexp.firstMatch(path);
          if (match != null) {
            yield StoreEvent.patch(
              match[1],
              _StorePatchSet(
                this,
                data as Map<String, dynamic>,
              ),
            );
          } else {
            _logPathTooDeep(path);
          }
        },
        authRevoked: () => throw AuthRevokedException(),
      );
    }
  }

  Stream<T> _transformValues(Stream<StreamEvent> stream) async* {
    T currentValue;
    await for (final event in stream) {
      final updatedValue = event.when(
        put: (path, dynamic data) {
          if (path == '/') {
            return dataFromJson(data);
          } else {
            _logPathTooDeep(path);
            return null;
          }
        },
        patch: (path, dynamic data) {
          if (path == '/') {
            if (currentValue == null) {
              throw PatchOnNullError();
            }
            return patchData(currentValue, data as Map<String, dynamic>);
          } else {
            _logPathTooDeep(path);
            return null;
          }
        },
        authRevoked: () => throw AuthRevokedException(),
      );
      if (updatedValue != null) {
        yield currentValue = updatedValue;
      }
    }
  }

  void _logPathTooDeep(String path) => _logger?.warning(
        'Skipping stream event with path "$path", path is too deep',
      );
}

class _CallbackFirebaseStore<T> extends FirebaseStore<T> {
  final DataFromJsonCallback<T> onDataFromJson;
  final DataToJsonCallback<T> onDataToJson;
  final PatchDataCallback<T> onPatchData;

  _CallbackFirebaseStore({
    @required FirebaseStore<dynamic> parent,
    @required String path,
    @required this.onDataFromJson,
    @required this.onDataToJson,
    @required this.onPatchData,
    String loggingCategory = FirebaseStore.loggingTag,
  }) : super(
          parent: parent,
          path: path,
          loggingCategory: loggingCategory,
        );

  _CallbackFirebaseStore.api({
    @required RestApi restApi,
    @required List<String> subPaths,
    @required this.onDataFromJson,
    @required this.onDataToJson,
    @required this.onPatchData,
    String loggingCategory = FirebaseStore.loggingTag,
  }) : super.api(
          restApi: restApi,
          subPaths: subPaths,
          loggingCategory: loggingCategory,
        );

  @override
  T dataFromJson(dynamic json) => onDataFromJson(json);

  @override
  dynamic dataToJson(T data) => onDataToJson(data);

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
