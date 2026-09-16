import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:e1547/inkbunny/data/model.dart';

class InkbunnyApiException implements Exception {
  const InkbunnyApiException(this.message, {this.code});

  final String message;
  final int? code;

  @override
  String toString() => code == null ? message : 'Inkbunny error $code: $message';
}

class InkbunnyClient {
  InkbunnyClient()
      : _dio = Dio(
          BaseOptions(
            baseUrl: 'https://inkbunny.net',
            connectTimeout: const Duration(seconds: 20),
            receiveTimeout: const Duration(seconds: 30),
          ),
        );

  final Dio _dio;
  String? _sid;
  String? _username;

  String? get sid => _sid;
  String? get username => _username;
  bool get hasSession => _sid != null;

  Map<String, String> get assetHeaders => const {
        'Referer': 'https://inkbunny.net/',
      };

  Future<void> login({String username = 'guest', String? password}) async {
    final normalized = username.trim().isEmpty ? 'guest' : username.trim();
    final fields = <String, dynamic>{
      'username': normalized,
      if (normalized.toLowerCase() != 'guest') 'password': password ?? '',
    };

    final response = await _post('/api_login.php', fields, includeSid: false);
    final nextSid = response['sid']?.toString();
    if (nextSid == null || nextSid.isEmpty) {
      throw const InkbunnyApiException('Login did not return a session ID.');
    }

    _sid = nextSid;
    _username = normalized;
  }

  Future<InkbunnyComicData> load(String input) async {
    final target = InkbunnyTarget.parse(input);
    return loadTarget(target);
  }

  Future<InkbunnyComicData> loadTarget(InkbunnyTarget target) async {
    if (!hasSession) await login();

    switch (target.type) {
      case InkbunnyTargetType.submission:
        final submissions = await _fetchSubmissionDetails([target.id]);
        if (submissions.isEmpty) {
          throw InkbunnyApiException(
            'Submission #${target.id} was not found or is not visible to this account.',
          );
        }
        final submission = submissions.first;
        return InkbunnyComicData(
          target: target,
          title: submission.title.isEmpty
              ? 'Inkbunny submission #${target.id}'
              : submission.title,
          submissions: submissions,
        );
      case InkbunnyTargetType.pool:
        final ids = await _fetchPoolSubmissionIds(target.id);
        if (ids.isEmpty) {
          throw InkbunnyApiException(
            'Pool #${target.id} was not found, is empty, or is not visible to this account.',
          );
        }

        final details = await _fetchSubmissionDetails(ids);
        final byId = {for (final submission in details) submission.id: submission};
        final ordered = [
          for (final id in ids)
            if (byId[id] case final submission?) submission,
        ];

        return InkbunnyComicData(
          target: target,
          title: 'Inkbunny pool #${target.id}',
          submissions: ordered,
        );
    }
  }

  String assetUrl(String url) {
    final currentSid = _sid;
    if (currentSid == null ||
        (!url.contains('/private_files/') &&
            !url.contains('/private_thumbnails/'))) {
      return url;
    }

    final uri = Uri.parse(url);
    return uri
        .replace(
          queryParameters: {
            ...uri.queryParameters,
            'sid': currentSid,
          },
        )
        .toString();
  }

  Future<List<int>> _fetchPoolSubmissionIds(int poolId) async {
    final result = <int>[];
    var page = 1;
    var pages = 1;

    do {
      final response = await _post('/api_search.php', {
        'pool_id': poolId,
        'orderby': 'pool_order',
        'submissions_per_page': 100,
        'page': page,
        'keywords_list': 'no',
      });

      for (final item in _asList(response['submissions'])) {
        if (item is! Map) continue;
        final id = int.tryParse('${item['submission_id'] ?? ''}');
        if (id != null) result.add(id);
      }

      pages = int.tryParse('${response['pages_count'] ?? 1}') ?? 1;
      page++;
    } while (page <= pages);

    return result;
  }

  Future<List<InkbunnySubmissionData>> _fetchSubmissionDetails(
    List<int> ids,
  ) async {
    final result = <InkbunnySubmissionData>[];

    for (var start = 0; start < ids.length; start += 100) {
      final end = (start + 100 < ids.length) ? start + 100 : ids.length;
      final chunk = ids.sublist(start, end);
      final response = await _post('/api_submissions.php', {
        'submission_ids': chunk.join(','),
        'show_pools': 'yes',
      });

      for (final item in _asList(response['submissions'])) {
        if (item is! Map) continue;
        final submission = InkbunnySubmissionData.fromJson(
          Map<String, dynamic>.from(item),
        );
        if (submission.id != 0 && submission.pages.isNotEmpty) {
          result.add(submission);
        }
      }
    }

    return result;
  }

  Future<Map<String, dynamic>> _post(
    String path,
    Map<String, dynamic> fields, {
    bool includeSid = true,
  }) async {
    final data = <String, dynamic>{
      if (includeSid) 'sid': _requireSid(),
      ...fields,
    };

    try {
      final response = await _dio.post<dynamic>(
        path,
        data: FormData.fromMap(data),
      );
      final json = _asMap(response.data);
      final errorCode = int.tryParse('${json['error_code'] ?? ''}');
      if (errorCode != null) {
        if (errorCode == 2) {
          _sid = null;
          _username = null;
        }
        throw InkbunnyApiException(
          '${json['error_message'] ?? 'Unknown API error'}',
          code: errorCode,
        );
      }
      return json;
    } on DioException catch (error) {
      final status = error.response?.statusCode;
      final message = error.message ?? 'Network request failed.';
      throw InkbunnyApiException(
        status == null ? message : 'HTTP $status: $message',
      );
    }
  }

  String _requireSid() {
    final value = _sid;
    if (value == null) {
      throw const InkbunnyApiException('No active Inkbunny session.');
    }
    return value;
  }

  Map<String, dynamic> _asMap(dynamic value) {
    dynamic decoded = value;
    if (decoded is String) decoded = jsonDecode(decoded);
    if (decoded is Map) return Map<String, dynamic>.from(decoded);
    throw const InkbunnyApiException('Inkbunny returned an invalid response.');
  }
}

List<dynamic> _asList(dynamic value) {
  if (value is List) return value;
  if (value is Map) {
    for (final key in ['submission', 'item']) {
      final nested = value[key];
      if (nested is List) return nested;
      if (nested is Map) return [nested];
    }
    return [value];
  }
  return const [];
}
