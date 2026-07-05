import '../config/app_config.dart';
import '../errors/app_exception.dart';

class ApiClient {
  const ApiClient({this.baseUrl = AppConfig.apiBaseUrl});

  final String baseUrl;

  Future<T> get<T>(String path) {
    throw const AppException('ApiClient is not connected yet.');
  }
}
