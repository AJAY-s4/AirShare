// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use
import 'dart:html' as html;
import 'dart:typed_data';

void downloadWebFile(Uint8List bytes, String fileName) {
  final blob = html.Blob([bytes], 'application/octet-stream');
  final url = html.Url.createObjectUrlFromBlob(blob);
  
  final anchor = html.AnchorElement(href: url)
    ..style.display = 'none'
    ..download = fileName;
    
  html.document.body?.children.add(anchor);
  anchor.click();
  
  // Delay cleanup to ensure Chrome reads the download attribute
  Future.delayed(const Duration(seconds: 2), () {
    anchor.remove();
    html.Url.revokeObjectUrl(url);
  });
}