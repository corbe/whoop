/// Chat attachment service (Phase 6, spec §19, §77).
///
/// pickImage/pickFile/validate — no S3/upload logic in chat widgets. Upload
/// itself is handled natively by the JuggleIM SDK (sendMediaMessage); this
/// service only picks + validates + prepares local paths.
library;

import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:image_picker/image_picker.dart';

import '../shared/models/chat.dart';

class AttachmentValidationException implements Exception {
  const AttachmentValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Allowed mime types (spec §17, §77 — no executables).
const allowedMimeTypes = <String, String>{
  'pdf': 'application/pdf',
  'jpg': 'image/jpeg',
  'jpeg': 'image/jpeg',
  'png': 'image/png',
  'gif': 'image/gif',
  'webp': 'image/webp',
  'txt': 'text/plain',
  'md': 'text/markdown',
  'csv': 'text/csv',
  'doc': 'application/msword',
  'docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  'xls': 'application/vnd.ms-excel',
  'xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  'ppt': 'application/vnd.ms-powerpoint',
  'pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
};

const maxImageSizeBytes = 10 * 1024 * 1024; // 10 MB
const maxFileSizeBytes = 25 * 1024 * 1024; // 25 MB

class ChatAttachmentService {
  final ImagePicker _picker = ImagePicker();

  /// Pick + validate an image (camera or gallery — spec §13).
  Future<ChatAttachment?> pickImage({bool fromCamera = false}) async {
    final source = fromCamera ? ImageSource.camera : ImageSource.gallery;
    final file = await _picker.pickImage(source: source, maxWidth: 2048);
    if (file == null) return null;

    final bytes = File(file.path).lengthSync();
    if (bytes > maxImageSizeBytes) {
      throw const AttachmentValidationException(
          'Imagem muito grande (máx. 10 MB).');
    }
    return ChatAttachment(
      name: file.name,
      mimeType: 'image/jpeg',
      size: bytes,
      localPath: file.path,
    );
  }

  /// Pick + validate a file (spec §17 — allowlist de tipos, sem executáveis).
  Future<ChatAttachment?> pickFile() async {
    final typeGroup = XTypeGroup(
      label: 'documentos',
      extensions: allowedMimeTypes.keys.toList(),
    );
    final file = await openFile(acceptedTypeGroups: [typeGroup]);
    if (file == null) return null;
    final path = file.path;

    final ext = path.split('.').last.toLowerCase();
    final mime = allowedMimeTypes[ext];
    if (mime == null) {
      throw const AttachmentValidationException(
          'Tipo de arquivo não permitido.');
    }
    final bytes = File(path).lengthSync();
    if (bytes > maxFileSizeBytes) {
      throw const AttachmentValidationException(
          'Arquivo muito grande (máx. 25 MB).');
    }
    return ChatAttachment(
      name: file.name,
      mimeType: mime,
      size: bytes,
      localPath: path,
    );
  }
}

