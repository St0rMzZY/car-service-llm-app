import 'package:amplify_flutter/amplify_flutter.dart';
import 'package:flutter/foundation.dart';

class S3Service {
  static Future<String?> uploadFile(String filePath, String fileName) async {
    try {
      final awsFile = AWSFile.fromPath(filePath);
      final path = StoragePath.fromString('uploads/$fileName');

      final result = await Amplify.Storage.uploadFile(
        localFile: awsFile,
        path: path,
      ).result;

      final getUrlResult = await Amplify.Storage.getUrl(
        path: StoragePath.fromString(result.uploadedItem.path),
      ).result;

      final s3Url = getUrlResult.url.toString();
      debugPrint('✅ File uploaded successfully: $s3Url');

      return s3Url;
    } on StorageException catch (e) {
      debugPrint('S3 StorageException: ${e.message}');
      return null;
    } catch (e) {
      debugPrint('Unexpected error: $e');
      return null;
    }
  }
}
