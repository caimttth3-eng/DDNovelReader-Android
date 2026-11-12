import 'package:flutter/painting.dart';
import 'package:flutter/services.dart';
import 'reader_header_layout.dart';

class DisplayCutoutService {
  static const channel = MethodChannel('com.ddnovelreader/display_cutout');

  static Future<DisplayCutoutGeometry?> read() async {
    try {
      final data = await channel.invokeMapMethod<String, dynamic>('getDisplayCutout');
      if (data == null) return null;
      double value(Map source, String key) {
        final number = source[key];
        return number is num && number.isFinite ? number.toDouble().clamp(0.0, double.infinity).toDouble() : 0;
      }
      final size = Size(value(data, 'width'), value(data, 'height'));
      if (size.isEmpty) return null;
      final insets = data['safeInsets'] is Map ? data['safeInsets'] as Map : const {};
      final cutouts = <Rect>[];
      if (data['cutouts'] is List) {
        for (final item in data['cutouts'] as List) {
          if (item is! Map) continue;
          final r = Rect.fromLTRB(value(item, 'left'), value(item, 'top'), value(item, 'right'), value(item, 'bottom'));
          if (!r.isEmpty) cutouts.add(r);
        }
      }
      return DisplayCutoutGeometry(viewport: size, cutouts: cutouts,
        safeInsets: EdgeInsets.fromLTRB(value(insets, 'left'), value(insets, 'top'), value(insets, 'right'), value(insets, 'bottom')),
        topLeftRadius: value(data, 'topLeftRadius'), topRightRadius: value(data, 'topRightRadius'),
        statusBarTop: value(data, 'statusBarTop'), statusBarVisible: data['statusBarVisible'] == true);
    } on PlatformException { return null; }
    on MissingPluginException { return null; }
  }
}
