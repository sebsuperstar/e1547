enum InkbunnyTargetType { submission, pool }

enum InkbunnyReaderOrder { poolOrder, oldestFirst, newestFirst }

class InkbunnyTarget {
  const InkbunnyTarget({required this.type, required this.id});

  final InkbunnyTargetType type;
  final int id;

  static InkbunnyTarget parse(String input) {
    final raw = input.trim();
    if (raw.isEmpty) {
      throw const FormatException('Paste an Inkbunny submission or pool URL.');
    }

    final explicit = RegExp(
      r'^\s*(submission|s|pool)\s*[:#]?\s*(\d+)\s*$',
      caseSensitive: false,
    ).firstMatch(raw);
    if (explicit != null) {
      final kind = explicit.group(1)!.toLowerCase();
      final id = int.parse(explicit.group(2)!);
      return InkbunnyTarget(
        type: kind == 'pool'
            ? InkbunnyTargetType.pool
            : InkbunnyTargetType.submission,
        id: id,
      );
    }

    final uri = Uri.tryParse(raw);
    if (uri != null) {
      final poolId = int.tryParse(uri.queryParameters['pool_id'] ?? '');
      if (poolId != null) {
        return InkbunnyTarget(type: InkbunnyTargetType.pool, id: poolId);
      }

      final submissionId = int.tryParse(
        uri.queryParameters['submission_id'] ??
            (uri.path.contains('submissionview.php')
                ? uri.queryParameters['id'] ?? ''
                : ''),
      );
      if (submissionId != null) {
        return InkbunnyTarget(
          type: InkbunnyTargetType.submission,
          id: submissionId,
        );
      }

      final shortSubmission = RegExp(r'(?:^|/)s/(\d+)(?:[/?#]|$)')
          .firstMatch(uri.path);
      if (shortSubmission != null) {
        return InkbunnyTarget(
          type: InkbunnyTargetType.submission,
          id: int.parse(shortSubmission.group(1)!),
        );
      }

      final poolPath = RegExp(r'(?:^|/)pool(?:view)?/(\d+)(?:[/?#]|$)')
          .firstMatch(uri.path);
      if (poolPath != null) {
        return InkbunnyTarget(
          type: InkbunnyTargetType.pool,
          id: int.parse(poolPath.group(1)!),
        );
      }
    }

    final bareId = int.tryParse(raw);
    if (bareId != null) {
      return InkbunnyTarget(
        type: InkbunnyTargetType.submission,
        id: bareId,
      );
    }

    throw const FormatException(
      'Could not find an Inkbunny submission or pool ID in that text.',
    );
  }
}

class InkbunnyPageData {
  const InkbunnyPageData({
    required this.submissionId,
    required this.fileId,
    required this.fileOrder,
    required this.imageUrl,
    required this.width,
    required this.height,
    required this.mimeType,
    this.previewUrl,
  });

  final int submissionId;
  final int fileId;
  final int fileOrder;
  final String imageUrl;
  final String? previewUrl;
  final int width;
  final int height;
  final String mimeType;

  double get aspectRatio => width > 0 && height > 0 ? width / height : 1;

  factory InkbunnyPageData.fromJson(Map<String, dynamic> json) {
    String? firstString(List<String> keys) {
      for (final key in keys) {
        final value = json[key];
        if (value != null && value.toString().isNotEmpty) {
          return value.toString();
        }
      }
      return null;
    }

    int firstInt(List<String> keys) {
      for (final key in keys) {
        final value = int.tryParse('${json[key] ?? ''}');
        if (value != null) return value;
      }
      return 0;
    }

    final imageUrl = firstString([
      'file_url_full',
      'file_url_screen',
      'file_url_preview',
    ]);
    if (imageUrl == null) {
      throw const FormatException('Inkbunny file has no usable image URL.');
    }

    return InkbunnyPageData(
      submissionId: firstInt(['submission_id']),
      fileId: firstInt(['file_id']),
      fileOrder: firstInt(['submission_file_order']),
      imageUrl: imageUrl,
      previewUrl: firstString([
        'file_url_preview',
        'thumbnail_url_huge',
        'thumbnail_url_large',
        'thumbnail_url_medium',
      ]),
      width: firstInt(['full_size_x', 'screen_size_x', 'preview_size_x']),
      height: firstInt(['full_size_y', 'screen_size_y', 'preview_size_y']),
      mimeType: firstString(['mimetype']) ?? 'image/unknown',
    );
  }
}

class InkbunnySubmissionData {
  const InkbunnySubmissionData({
    required this.id,
    required this.title,
    required this.createdAt,
    required this.pages,
  });

  final int id;
  final String title;
  final DateTime? createdAt;
  final List<InkbunnyPageData> pages;

  factory InkbunnySubmissionData.fromJson(Map<String, dynamic> json) {
    final files = _listFromJson(json['files'])
        .whereType<Map>()
        .map((item) => Map<String, dynamic>.from(item))
        .where((item) {
          final mime = '${item['mimetype'] ?? ''}';
          return mime.isEmpty || mime.startsWith('image/');
        })
        .map(InkbunnyPageData.fromJson)
        .toList()
      ..sort((a, b) => a.fileOrder.compareTo(b.fileOrder));

    return InkbunnySubmissionData(
      id: int.tryParse('${json['submission_id'] ?? ''}') ?? 0,
      title: '${json['title'] ?? ''}'.trim(),
      createdAt: DateTime.tryParse('${json['create_datetime'] ?? ''}'),
      pages: files,
    );
  }
}

class InkbunnyComicData {
  const InkbunnyComicData({
    required this.target,
    required this.title,
    required this.submissions,
  });

  final InkbunnyTarget target;
  final String title;
  final List<InkbunnySubmissionData> submissions;

  List<InkbunnyPageData> pagesFor(InkbunnyReaderOrder order) {
    final ordered = List<InkbunnySubmissionData>.from(submissions);

    int compareCreated(InkbunnySubmissionData a, InkbunnySubmissionData b) {
      final aDate = a.createdAt;
      final bDate = b.createdAt;
      if (aDate != null && bDate != null) return aDate.compareTo(bDate);
      if (aDate != null) return -1;
      if (bDate != null) return 1;
      return a.id.compareTo(b.id);
    }

    switch (order) {
      case InkbunnyReaderOrder.poolOrder:
        break;
      case InkbunnyReaderOrder.oldestFirst:
        ordered.sort(compareCreated);
      case InkbunnyReaderOrder.newestFirst:
        ordered.sort((a, b) => compareCreated(b, a));
    }

    return ordered.expand((submission) => submission.pages).toList();
  }
}

List<dynamic> _listFromJson(dynamic value) {
  if (value is List) return value;
  if (value is Map) {
    for (final key in ['submission', 'file', 'item']) {
      final nested = value[key];
      if (nested is List) return nested;
      if (nested is Map) return [nested];
    }
    return [value];
  }
  return const [];
}
