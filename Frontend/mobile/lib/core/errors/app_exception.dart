class AppException implements Exception {
  const AppException(
    this.message, {
    this.code,
    this.statusCode,
    this.details = const {},
  });

  final String message;
  final String? code;
  final int? statusCode;
  final Map<String, dynamic> details;

  @override
  String toString() => message;
}
