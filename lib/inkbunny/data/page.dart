class InkbunnyPage {
  const InkbunnyPage({
    required this.submissionId,
    required this.fileId,
    required this.order,
    required this.url,
    required this.previewUrl,
    required this.width,
    required this.height,
    required this.isPrivate,
  });

  final int submissionId;
  final int fileId;
  final int order;
  final String url;
  final String? previewUrl;
  final int width;
  final int height;
  final bool isPrivate;

  double get aspectRatio => width > 0 && height > 0 ? width / height : 1;
}
