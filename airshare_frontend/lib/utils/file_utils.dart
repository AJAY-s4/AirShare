import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

// Universal import pattern to safely reference dart:html on web only
import 'file_utils_web.dart' if (dart.library.io) 'file_utils_stub.dart';

class FileUtils {
  /// Converts bytes into a formatted string (e.g., 1024 bytes -> 1.00 KB)
  static String formatBytes(int bytes, [int decimals = 2]) {
    if (bytes <= 0) return "0 B";
    const suffixes = ["B", "KB", "MB", "GB", "TB"];
    var i = (log(bytes) / log(1024)).floor();
    return '${(bytes / pow(1024, i)).toStringAsFixed(decimals)} ${suffixes[i]}';
  }

  /// Returns a matching Material Icon based on file extension
  static IconData getFileIcon(String? fileName) {
    if (fileName == null || !fileName.contains('.')) {
      return Icons.insert_drive_file;
    }

    final ext = fileName.split('.').last.toLowerCase();

    switch (ext) {
      // Images
      case 'jpg':
      case 'jpeg':
      case 'png':
      case 'gif':
      case 'webp':
      case 'svg':
        return Icons.image;

      // Documents
      case 'pdf':
        return Icons.picture_as_pdf;
      case 'doc':
      case 'docx':
      case 'txt':
        return Icons.description;

      // Audio
      case 'mp3':
      case 'wav':
      case 'aac':
      case 'flac':
        return Icons.audiotrack;

      // Video
      case 'mp4':
      case 'mkv':
      case 'avi':
      case 'mov':
        return Icons.movie;

      // Archives
      case 'zip':
      case 'rar':
      case '7z':
      case 'tar':
      case 'gz':
        return Icons.folder_zip;

      // Code
      case 'dart':
      case 'js':
      case 'html':
      case 'css':
      case 'py':
      case 'json':
        return Icons.code;

      default:
        return Icons.insert_drive_file;
    }
  }

  /// Save an in-memory Web file
  static Future<String?> saveWebFile(Uint8List bytes, String fileName) async {
    if (kIsWeb) {
      downloadWebFile(bytes, fileName);
      return null;
    }
    throw UnsupportedError('saveWebFile called on native platform');
  }

  /// Get a temporary file path for native streaming
  static Future<File> createTempFile(String fileName) async {
    if (kIsWeb) throw UnsupportedError('createTempFile not supported on web');
    final directory = await getTemporaryDirectory();
    return File('${directory.path}/$fileName');
  }

  /// Move a downloaded temporary file to the public Downloads folder (Native only)
  static Future<String?> moveToDownloads(File tempFile, String fileName) async {
    if (kIsWeb) return null;

    try {
      Directory? downloadsDir;
      if (Platform.isAndroid) {
        downloadsDir = Directory('/storage/emulated/0/Download');
        if (!await downloadsDir.exists()) {
          downloadsDir = await getExternalStorageDirectory();
        }
      } else if (Platform.isIOS || Platform.isMacOS || Platform.isWindows || Platform.isLinux) {
        downloadsDir = await getDownloadsDirectory();
      }

      if (downloadsDir != null) {
        // Handle name collision
        String finalName = fileName;
        File destFile = File('${downloadsDir.path}/$finalName');
        int counter = 1;
        while (await destFile.exists()) {
          final extIndex = fileName.lastIndexOf('.');
          if (extIndex != -1) {
            finalName = '${fileName.substring(0, extIndex)} ($counter)${fileName.substring(extIndex)}';
          } else {
            finalName = '$fileName ($counter)';
          }
          destFile = File('${downloadsDir.path}/$finalName');
          counter++;
        }

        await tempFile.copy(destFile.path);
        await tempFile.delete();
        return destFile.path;
      }
    } catch (e) {
      debugPrint("Error moving file to downloads: $e");
      // Fallback to app documents if downloads directory fails
      final docDir = await getApplicationDocumentsDirectory();
      final fallbackPath = '${docDir.path}/$fileName';
      await tempFile.copy(fallbackPath);
      await tempFile.delete();
      return fallbackPath;
    }
    return null;
  }
}