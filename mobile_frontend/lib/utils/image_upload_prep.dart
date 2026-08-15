import 'dart:typed_data';

import 'package:flutter/foundation.dart' show compute;
import 'package:image/image.dart' as img;

/// Prepares picked photos for upload without destroying their metadata.
///
/// image_picker's own `imageQuality` option looks like the obvious way to
/// shrink an upload, but it re-encodes the JPEG in native code and drops the
/// EXIF, XMP and C2PA blocks along the way. The backend uses exactly those
/// blocks to tell a genuine camera photo from an AI-generated or edited one, so
/// the app must pick the original untouched and do its own resizing here.
///
/// Callers send two things: the downscaled image (for the model and the
/// dataset) and [metadataBlobBytes] from the head of the original (for
/// forensics). Provenance metadata lives at the front of the file, so a partial
/// copy is enough and there is no need to upload a multi-megabyte original.
class ImageUploadPrep {
  ImageUploadPrep._();

  /// How much of the original to keep for metadata analysis.
  static const int metadataBlobBytes = 512 * 1024;

  /// Uploads above this size get downscaled.
  static const int maxUploadBytes = 2 * 1024 * 1024;

  /// Longest edge of a downscaled upload. The model only ever sees 224x224.
  static const int maxUploadDimension = 1600;

  /// Return the leading slice of [original] that carries its metadata.
  static Uint8List metadataBlob(Uint8List original) {
    return original.length > metadataBlobBytes
        ? Uint8List.sublistView(original, 0, metadataBlobBytes)
        : original;
  }

  /// Shrink [original] for upload, decoding on a background isolate.
  ///
  /// Returns the input unchanged if it is already small enough or if decoding
  /// fails — an oversized upload the server can reject is better than a crash
  /// in the middle of filing a report.
  static Future<Uint8List> downscaleForUpload(Uint8List original) async {
    if (original.lengthInBytes <= maxUploadBytes) return original;
    try {
      return await compute(_resizeIsolate, original);
    } catch (_) {
      return original;
    }
  }

  static Uint8List _resizeIsolate(Uint8List data) {
    final decoded = img.decodeImage(data);
    if (decoded == null) return data;

    final needsResize =
        decoded.width > maxUploadDimension || decoded.height > maxUploadDimension;

    final resized = needsResize
        ? img.copyResize(
            decoded,
            width: decoded.width >= decoded.height ? maxUploadDimension : null,
            height: decoded.height > decoded.width ? maxUploadDimension : null,
            interpolation: img.Interpolation.average,
          )
        : decoded;

    return Uint8List.fromList(img.encodeJpg(resized, quality: 85));
  }
}
