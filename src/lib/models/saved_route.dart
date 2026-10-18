import 'package:latlong2/latlong.dart';
import 'package:xml/xml.dart' as xml;

class SavedRoute {
  final String id;
  final String name;
  final List<LatLng> points;
  final double speedKmH;
  final DateTime createdAt;

  SavedRoute({
    required this.id,
    required this.name,
    required this.points,
    required this.speedKmH,
    required this.createdAt,
  });

  static String getNewId() {
    return DateTime.now().millisecondsSinceEpoch.toString();
  }

  static double getDefaultSpeedKmH() {
    return 15.0;
  }

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'created_at': createdAt.toUtc().toIso8601String(),
    'speed_kmh': speedKmH.toString(),
    'points': points
        .map((p) => {'latitude': p.latitude, 'longitude': p.longitude})
        .toList(),
  };

  factory SavedRoute.fromJson(Map<String, dynamic> json, {String? fileName}) {
    final speedVal = json['speed_kmh'];
    double speed = getDefaultSpeedKmH();
    if (speedVal is num) {
      speed = speedVal.toDouble();
    } else if (speedVal is String) {
      speed = double.tryParse(speedVal) ?? getDefaultSpeedKmH();
    }

    final dateStr = json['created_at'] ?? DateTime.now().toIso8601String();
    final createdAtParsed = DateTime.parse(dateStr);

    final rawPoints = (json['points'] as List?) ?? [];
    final parsedPoints = rawPoints.map((p) {
      if (p is Map) {
        final lat = (p['latitude'] as num?)?.toDouble() ?? 0.0;
        final lng = (p['longitude'] as num?)?.toDouble() ?? 0.0;
        return LatLng(lat, lng);
      }
      throw const FormatException('Invalid point format in JSON.');
    }).toList();

    String? routeName = json['name'];
    if (routeName == null || routeName.isEmpty) {
      if (fileName != null && fileName.isNotEmpty) {
        routeName = fileName.replaceAll(RegExp(r'\.[^/.]+$'), '');
      } else {
        routeName = 'Unnamed Route';
      }
    }

    return SavedRoute(
      id: json['id'] ?? getNewId(),
      name: routeName,
      speedKmH: speed,
      createdAt: createdAtParsed,
      points: parsedPoints,
    );
  }

  String toGpx() {
    final builder = xml.XmlBuilder();
    builder.processing('xml', 'version="1.0" encoding="UTF-8"');

    builder.element(
      'gpx',
      attributes: {
        'version': '1.1',
        'creator': 'MockLocationApp',
        'xmlns': 'http://www.topografix.com/GPX/1/1',
      },
      namespaceUris: {'': 'http://www.topografix.com/GPX/1/1'},
      nest: () {
        builder.element(
          'trk',
          nest: () {
            builder.element('name', nest: () => builder.text(name));

            builder.element(
              'extensions',
              nest: () {
                builder.element('id', nest: () => builder.text(id));
                builder.element(
                  'created_at',
                  nest: () => builder.text(createdAt.toUtc().toIso8601String()),
                );
                builder.element(
                  'speed_kmh',
                  nest: () => builder.text(speedKmH.toString()),
                );
              },
            );

            builder.element(
              'trkseg',
              nest: () {
                for (final pt in points) {
                  builder.element(
                    'trkpt',
                    attributes: {
                      'lat': pt.latitude.toString(),
                      'lon': pt.longitude.toString(),
                    },
                  );
                }
              },
            );
          },
        );
      },
    );

    final document = builder.buildDocument();
    return document.toXmlString(pretty: true, indent: '  ');
  }

  factory SavedRoute.fromGpx(String gpxContent, {String? fileName}) {
    final document = xml.XmlDocument.parse(gpxContent);

    final trkEl = document.findAllElements('trk').firstOrNull;
    if (trkEl == null) {
      throw const FormatException('Invalid GPX format: Missing <trk> element.');
    }

    String? routeName;
    final nameEl = trkEl.findElements('name').firstOrNull;
    routeName = nameEl?.value;

    if (routeName == null || routeName.isEmpty) {
      final metadataEl = document.findAllElements('metadata').firstOrNull;
      if (metadataEl != null) {
        final metaNameEl = metadataEl.findElements('name').firstOrNull;
        routeName = metaNameEl?.value;
      }
    }

    if (routeName == null || routeName.isEmpty) {
      if (fileName != null && fileName.isNotEmpty) {
        routeName = fileName.replaceAll(RegExp(r'\.[^/.]+$'), '');
      } else {
        routeName = 'Unnamed Route';
      }
    }

    String id = getNewId();
    DateTime createdAt = DateTime.now().toUtc();
    double speedKmH = getDefaultSpeedKmH();

    final extensionsEl = trkEl.findElements('extensions').firstOrNull;
    if (extensionsEl != null) {
      final idEl = extensionsEl.findElements('id').firstOrNull;
      if (idEl != null) id = idEl.value ?? '';

      final createdAtEl = extensionsEl.findElements('created_at').firstOrNull;
      if (createdAtEl != null && createdAtEl.value != null) {
        createdAt = DateTime.parse(createdAtEl.value!);
      }

      final speedEl = extensionsEl.findElements('speed_kmh').firstOrNull;
      if (speedEl != null && speedEl.value != null) {
        speedKmH = double.tryParse(speedEl.value!) ?? getDefaultSpeedKmH();
      }
    }

    final List<LatLng> points = [];
    final trkPts = document.findAllElements('trkpt');
    for (final pt in trkPts) {
      final latStr = pt.getAttribute('lat');
      final lonStr = pt.getAttribute('lon');

      if (latStr != null && lonStr != null) {
        final lat = double.tryParse(latStr) ?? 0.0;
        final lon = double.tryParse(lonStr) ?? 0.0;
        points.add(LatLng(lat, lon));
      }
    }

    return SavedRoute(
      id: id,
      name: routeName,
      points: points,
      speedKmH: speedKmH,
      createdAt: createdAt,
    );
  }
}
