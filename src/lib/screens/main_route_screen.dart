import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_dragmarker/flutter_map_dragmarker.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:gpx/gpx.dart';
import 'package:app_links/app_links.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_route.dart';
import 'saved_routes_screen.dart';

class MainRouteScreen extends StatefulWidget {
  const MainRouteScreen({super.key});

  @override
  State<MainRouteScreen> createState() => _MainRouteScreenState();
}

class _MainRouteScreenState extends State<MainRouteScreen> {
  static const MethodChannel _gpsChannel = MethodChannel(
    'com.example.my_mock_route/gps',
  );
  final MapController _mapController = MapController();

  bool _isControlPanelExpanded = true;

  LatLng _initLocation = LatLng(22.3193, 114.1694);
  bool _isInitializingLocation = true;
  bool _isLocating = false;

  bool _isInsertMode = false;

  final List<LatLng> _routePoints = [];
  LatLng? _currentMockPosition;

  double _speedKmH = SavedRoute.getDefaultSpeedKmH();
  bool _enableNoise = true;
  bool _isPaused = false;
  bool _isSimulating = false;

  bool _enableHealthConnectSteps = false;
  double _stepsPerMeter = 1.1;

  bool _enableLoop = false;
  int _loopTimes = -1; // 1 = run once, >1 = specific count, <= 0  for infinity
  bool _isRoundTrip = true; // default enable: start -> end, end -> start

  @override
  void initState() {
    super.initState();

    const MethodChannel(
      'com.example.my_mock_route/gps_stream',
    ).setMethodCallHandler((call) async {
      if (call.method == 'onStartFailed') {
        final String errorMsg = call.arguments;

        if (mounted) {
          setState(() {
            _isSimulating = false;
            _isPaused = false;
            ScaffoldMessenger.of(
              context,
            ).showSnackBar(SnackBar(content: Text(errorMsg)));
          });
        }
      } else if (call.method == 'onLocationUpdate') {
        final Map<dynamic, dynamic> args = call.arguments;
        double lat = args['lat'];
        double lng = args['lng'];

        if (mounted) {
          setState(() {
            _currentMockPosition = LatLng(lat, lng);
          });
        }
      }
    });

    _checkActiveSimulationState();
    _determinePosition();
  }

  Future<void> _checkActiveSimulationState() async {
    try {
      final Map<dynamic, dynamic>? status = await _gpsChannel.invokeMethod(
        'checkServiceState',
      );
      if (status != null && mounted) {
        final bool isSimulating = status['isSimulating'] ?? false;

        if (isSimulating) {
          final List<dynamic> rawPoints = status['points'] ?? [];
          final List<LatLng> restoredPoints = [];
          for (int i = 0; i < rawPoints.length - 1; i += 2) {
            restoredPoints.add(LatLng(rawPoints[i], rawPoints[i + 1]));
          }

          setState(() {
            _isSimulating = true;
            _isPaused = status['isPaused'] ?? false;
            _routePoints
              ..clear()
              ..addAll(restoredPoints);
            _speedKmH = status['speed'] ?? SavedRoute.getDefaultSpeedKmH();
            _enableNoise = status['noise'] ?? true;
            _enableHealthConnectSteps = status['healthSteps'] ?? false;
            _stepsPerMeter = status['stepsPerMeter'] ?? 1.1;
            _enableLoop = status['enableLoop'] ?? false;
            _loopTimes = status['loopTimes'] ?? -1;
            _isRoundTrip = status['isRoundTrip'] ?? true;
            if (restoredPoints.isNotEmpty) {
              _currentMockPosition = restoredPoints.first;
            }
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _determinePosition() async {
    try {
      bool serviceEnabled;
      LocationPermission permission;

      serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        setState(() => _isInitializingLocation = false);
        return;
      }

      permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          setState(() => _isInitializingLocation = false);
          return;
        }
      }

      if (permission == LocationPermission.deniedForever) {
        setState(() => _isInitializingLocation = false);
        return;
      }

      LocationSettings locationSettings = const LocationSettings(
        accuracy: LocationAccuracy.high,
        distanceFilter: 100,
      );

      Position position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );

      setState(() {
        _initLocation = LatLng(position.latitude, position.longitude);
        _isInitializingLocation = false;
      });
    } catch (_) {
      setState(() => _isInitializingLocation = false);
    }
  }

  Future<void> _handleMapTap(LatLng point) async {
    if (_isSimulating) return;

    if (_routePoints.isEmpty || _routePoints.length == 1 || !_isInsertMode) {
      _addPoint(point);
    } else {
      _insertPointNearSegment(point);
    }

    // final String? action = await showModalBottomSheet<String>(
    //   context: context,
    //   builder: (context) => SafeArea(
    //     child: Wrap(
    //       children: [
    //         ListTile(
    //           leading: const Icon(Icons.add_location_alt, color: Colors.blue),
    //           title: const Text('Add to End of Route'),
    //           onTap: () => Navigator.pop(context, 'end'),
    //         ),
    //         ListTile(
    //           leading: const Icon(Icons.alt_route, color: Colors.orange),
    //           title: const Text('Insert in the Middle'),
    //           subtitle: const Text('Inserts into the closest route segment'),
    //           onTap: () => Navigator.pop(context, 'middle'),
    //         ),
    //       ],
    //     ),
    //   ),
    // );

    // if (action == 'end') {
    //   _addPoint(point);
    // } else if (action == 'middle') {
    //   _insertPointNearSegment(point);
    // }
  }

  void _addPoint(LatLng point) {
    if (_isSimulating) return;
    setState(() {
      _routePoints.add(point);
    });
  }

  void _insertPointNearSegment(LatLng tappedPoint) {
    if (_isSimulating || _routePoints.isEmpty) return;

    if (_routePoints.length == 1) {
      setState(() {
        _routePoints.add(tappedPoint);
      });
      return;
    }

    int bestIndex = 1;
    double minDistance = double.infinity;

    // Find the closest line segment to insert the new point
    for (int i = 0; i < _routePoints.length - 1; i++) {
      final p1 = _routePoints[i];
      final p2 = _routePoints[i + 1];

      final distance = _calculateDistanceToSegment(tappedPoint, p1, p2);
      if (distance < minDistance) {
        minDistance = distance;
        bestIndex = i + 1; // Insert right after segment start point
      }
    }

    setState(() {
      _routePoints.insert(bestIndex, tappedPoint);
    });
  }

  double _calculateDistanceToSegment(LatLng p, LatLng a, LatLng b) {
    // Simple geometric approximation for segment distance lookup
    final double A = p.latitude - a.latitude;
    final double B = p.longitude - a.longitude;
    final double C = b.latitude - a.latitude;
    final double D = b.longitude - a.longitude;

    final double dot = A * C + B * D;
    final double lenSq = C * C + D * D;
    double param = -1;
    if (lenSq != 0) {
      param = dot / lenSq;
    }

    double xx, yy;
    if (param < 0) {
      xx = a.latitude;
      yy = a.longitude;
    } else if (param > 1) {
      xx = b.latitude;
      yy = b.longitude;
    } else {
      xx = a.latitude + param * C;
      yy = a.longitude + param * D;
    }

    final double dx = p.latitude - xx;
    final double dy = p.longitude - yy;
    return dx * dx + dy * dy;
  }

  void _deletePoint(int index) {
    if (_isSimulating) return;
    setState(() {
      _routePoints.removeAt(index);
    });
  }

  void _resetMapToNorth() {
    _mapController.rotate(0.0);
  }

  Future<void> _moveToCurrentLocation() async {
    setState(() => _isLocating = true);

    try {
      Position? position = await Geolocator.getLastKnownPosition();

      position ??= await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.medium,
          timeLimit: Duration(seconds: 5),
        ),
      );

      final currentLatLng = LatLng(position.latitude, position.longitude);
      final currentZoom = _mapController.camera.zoom;

      _mapController.move(currentLatLng, currentZoom);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Failed to get current location: $e')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isLocating = false);
      }
    }
  }

  Future<void> _saveRouteRecord() async {
    if (_routePoints.isEmpty) return;

    final TextEditingController nameController = TextEditingController(
      text: 'Route ${DateTime.now().toString().substring(0, 16)}',
    );

    final String? routeName = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Save Route Record'),
        content: TextField(
          controller: nameController,
          decoration: const InputDecoration(labelText: 'Route Name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, nameController.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (routeName != null && routeName.trim().isNotEmpty) {
      final prefs = await SharedPreferences.getInstance();
      final String? existingData = prefs.getString('saved_routes');
      List<SavedRoute> savedList = [];

      if (existingData != null) {
        final List decoded = jsonDecode(existingData);
        savedList = decoded.map((e) => SavedRoute.fromJson(e)).toList();
      }

      final newRecord = SavedRoute(
        id: DateTime.now().millisecondsSinceEpoch.toString(),
        name: routeName.trim(),
        points: _routePoints,
        speedKmH: _speedKmH,
        createdAt: DateTime.now(),
      );

      savedList.add(newRecord);
      final encoded = jsonEncode(savedList.map((e) => e.toJson()).toList());
      await prefs.setString('saved_routes', encoded);

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Saved "${newRecord.name}" successfully!')),
        );
      }
    }
  }

  Future<void> _showSpeedInputDialog() async {
    final TextEditingController controller = TextEditingController(
      text: _speedKmH.round().toString(),
    );

    final double? newSpeed = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter Speed (km/h)'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter between 1 and 360',
            suffixText: 'km/h',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text);
              if (parsed != null) {
                final clamped = parsed.clamp(1.0, 360.0);
                Navigator.pop(context, clamped);
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );

    if (newSpeed != null) {
      _updateSpeed(newSpeed);
    }
  }

  Future<void> _showStepsPerMeterInputDialog() async {
    final TextEditingController controller = TextEditingController(
      text: _stepsPerMeter.round().toString(),
    );

    final double? newStepsPerMeter = await showDialog<double>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Enter Steps/Meter'),
        content: TextField(
          controller: controller,
          keyboardType: TextInputType.number,
          autofocus: true,
          decoration: const InputDecoration(
            hintText: 'Enter between 0.1 and 5.0',
            suffixText: '',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text);
              if (parsed != null) {
                final clamped = parsed.clamp(0.1, 5.0);
                Navigator.pop(context, clamped);
              } else {
                Navigator.pop(context);
              }
            },
            child: const Text('Set'),
          ),
        ],
      ),
    );

    if (newStepsPerMeter != null) {
      _updateStepsPerMeter(newStepsPerMeter);
    }
  }

  Future<void> _showLoopTimesInputDialog() async {
    final TextEditingController controller = TextEditingController(
      text: _loopTimes <= 0 ? '' : _loopTimes.toString(),
    );

    final int? result = await showDialog<int>(
      context: context,
      builder: (context) {
        bool infinite = _loopTimes <= 0;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Configure Loop Count'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CheckboxListTile(
                    title: const Text('Infinite Loops'),
                    value: infinite,
                    onChanged: (val) {
                      setDialogState(() {
                        infinite = val ?? true;
                      });
                    },
                  ),
                  if (!infinite)
                    TextField(
                      controller: controller,
                      keyboardType: TextInputType.number,
                      autofocus: true,
                      decoration: const InputDecoration(
                        labelText: 'Number of loops',
                        hintText: 'e.g. 3',
                      ),
                    ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text('Cancel'),
                ),
                TextButton(
                  onPressed: () {
                    int count = _loopTimes;
                    if (infinite) {
                      count = -1;
                    } else {
                      count = int.tryParse(controller.text) ?? 1;
                      if (count < 1) count = 1;
                    }
                    Navigator.pop(context, count);
                  },
                  child: const Text('Set'),
                ),
              ],
            );
          },
        );
      },
    );

    if (result != null) {
      setState(() {
        _loopTimes = result;
      });
      await _updateServiceSettings();
    }
  }

  Future<void> _startSimulation() async {
    if (_routePoints.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tap map to add at least 1 point first')),
      );
      return;
    }

    final List<double> flattenedPoints = [];
    for (var point in _routePoints) {
      flattenedPoints.add(point.latitude);
      flattenedPoints.add(point.longitude);
    }

    try {
      await _gpsChannel.invokeMethod('startNativeService', {
        'points': flattenedPoints,
        'speed': _speedKmH,
        'noise': _enableNoise,
        'healthSteps': _enableHealthConnectSteps,
        'stepsPerMeter': _stepsPerMeter,
        'enableLoop': _enableLoop,
        'loopTimes': _loopTimes,
        'isRoundTrip': _isRoundTrip,
      });
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Error starting native service: $e')),
        );
      }
      return;
    }

    setState(() {
      _isSimulating = true;
      _isPaused = false;
    });
  }

  void _stopSimulation() {
    try {
      _gpsChannel.invokeMethod('stopNativeService');
    } catch (_) {}

    setState(() {
      _isSimulating = false;
      _isPaused = false;
    });
  }

  Future<void> _updateServiceSettings() async {
    if (_isSimulating) {
      try {
        await _gpsChannel.invokeMethod('updateServiceSettings', {
          'isPaused': _isPaused,
          'speed': _speedKmH,
          'noise': _enableNoise,
          'healthSteps': _enableHealthConnectSteps,
          'stepsPerMeter': _stepsPerMeter,
          'enableLoop': _enableLoop,
          'loopTimes': _loopTimes,
          'isRoundTrip': _isRoundTrip,
        });
      } catch (_) {}
    }
  }

  Future<void> _togglePauseSimulation() async {
    setState(() {
      _isPaused = !_isPaused;
    });
    await _updateServiceSettings();
  }

  Future<void> _updateSpeed(double newSpeed) async {
    setState(() {
      _speedKmH = newSpeed;
    });

    await _updateServiceSettings();
  }

  Future<void> _updateNoise(bool newNoise) async {
    setState(() {
      _enableNoise = newNoise;
    });

    await _updateServiceSettings();
  }

  Future<void> _updateHealthConnectSteps(bool newHealthConnectSteps) async {
    setState(() {
      _enableHealthConnectSteps = newHealthConnectSteps;
    });

    await _updateServiceSettings();
  }

  Future<void> _updateStepsPerMeter(double newStepsPerMeter) async {
    setState(() {
      _stepsPerMeter = newStepsPerMeter;
    });

    await _updateServiceSettings();
  }

  Future<void> _updateEnableLoop(bool val) async {
    setState(() {
      _enableLoop = val;
    });
    await _updateServiceSettings();
  }

  Future<void> _updateRoundTrip(bool val) async {
    setState(() {
      _isRoundTrip = val;
    });
    await _updateServiceSettings();
  }

  Future<void> _confirmRemoveRoute() async {
    if (_routePoints.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('No route to delete.')));
      return;
    }

    if (_isSimulating) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Stop the simulation before deleting the route.'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Route?'),
        content: const Text('This will delete the current route.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        _routePoints.clear();
      });

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Route deleted.')));
      }
    }
  }

  Future<void> _confirmReverseRoute() async {
    if (_routePoints.length < 2) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'You need at least 2 route points to reverse the route.',
          ),
        ),
      );
      return;
    }

    if (_isSimulating) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Stop the simulation before reversing the route.'),
        ),
      );
      return;
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reverse Route?'),
        content: const Text(
          'This will reverse the direction of the current route. '
          'The route points will be changed from start → end to end → start.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Reverse'),
          ),
        ],
      ),
    );

    if (confirmed == true) {
      setState(() {
        final reversed = _routePoints.reversed.toList();
        _routePoints
          ..clear()
          ..addAll(reversed);
        _currentMockPosition = _routePoints.first;
      });
      _mapController.move(_routePoints.first, 14.0);

      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Route reversed.')));
      }
    }
  }

  @override
  void dispose() {
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (_isInitializingLocation) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Mock Route Engine'),
        actions: [
          IconButton(
            icon: const Icon(Icons.bookmark),
            tooltip: 'Saved Records',
            onPressed: () async {
              final SavedRoute? selected = await Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => const SavedRoutesScreen(),
                ),
              );
              if (selected != null) {
                setState(() {
                  _routePoints.clear();
                  _routePoints.addAll(selected.points);
                  _speedKmH = selected.speedKmH;
                  _currentMockPosition = selected.points.first;
                });
                _mapController.move(selected.points.first, 14.0);
              }
            },
          ),
          IconButton(
            icon: const Icon(Icons.save),
            tooltip: 'Save Record',
            onPressed: _routePoints.isEmpty ? null : _saveRouteRecord,
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: 'Clear Route',
            onPressed: _confirmRemoveRoute,
          ),
        ],
      ),
      body: Column(
        children: [
          Expanded(
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _initLocation,
                    initialZoom: 13.0,
                    onTap: (tapPosition, point) => _handleMapTap(point),
                  ),
                  children: [
                    TileLayer(
                      urlTemplate:
                          'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                      userAgentPackageName: 'com.example.my_mock_route',
                    ),
                    if (_routePoints.isNotEmpty)
                      PolylineLayer(
                        polylines: [
                          Polyline(
                            points: _routePoints,
                            strokeWidth: 4.0,
                            color: Colors.blueAccent,
                          ),
                        ],
                      ),
                    MarkerLayer(
                      markers: [
                        if (_currentMockPosition != null)
                          Marker(
                            point: _currentMockPosition!,
                            width: 32,
                            height: 32,
                            child: const Icon(
                              Icons.navigation,
                              color: Colors.green,
                              size: 32,
                            ),
                          ),
                      ],
                    ),
                    DragMarkers(
                      markers: [
                        ..._routePoints.asMap().entries.map((entry) {
                          final int index = entry.key;
                          final LatLng point = entry.value;

                          return DragMarker(
                            point: point,
                            size: const Size(30, 30),
                            useLongPress: true,
                            builder:
                                (
                                  BuildContext context,
                                  LatLng pos,
                                  bool isDragging,
                                ) {
                                  return GestureDetector(
                                    onTap: () {
                                      if (_isSimulating) return;
                                      showDialog(
                                        context: context,
                                        builder: (context) => AlertDialog(
                                          title: const Text('Delete Point?'),
                                          content: const Text(
                                            'Do you want to remove this route point?',
                                          ),
                                          actions: [
                                            TextButton(
                                              onPressed: () =>
                                                  Navigator.pop(context),
                                              child: const Text('Cancel'),
                                            ),
                                            TextButton(
                                              onPressed: () {
                                                Navigator.pop(context);
                                                _deletePoint(index);
                                              },
                                              child: const Text(
                                                'Delete',
                                                style: TextStyle(
                                                  color: Colors.red,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      );
                                    },
                                    child: Icon(
                                      Icons.location_on,
                                      color: !_isSimulating && isDragging
                                          ? Colors.amber
                                          : Colors.red,
                                      size: !_isSimulating && isDragging
                                          ? 50
                                          : 24,
                                    ),
                                  );
                                },
                            onLongDragUpdate:
                                (details, LatLng transformedPoint) {
                                  if (_isSimulating) return;
                                  setState(() {
                                    _routePoints[index] = transformedPoint;
                                  });
                                },
                            onLongDragEnd: (details, LatLng transformedPoint) {
                              if (_isSimulating) return;
                              setState(() {
                                _routePoints[index] = transformedPoint;
                              });
                            },
                          );
                        }),
                      ],
                    ),
                  ],
                ),
                Positioned(
                  top: 16,
                  right: 16,
                  child: FloatingActionButton.small(
                    heroTag: 'north_btn',
                    onPressed: _resetMapToNorth,
                    tooltip: 'Set Map North',
                    child: const Icon(Icons.explore),
                  ),
                ),
                Positioned(
                  top: 72,
                  right: 16,
                  child: FloatingActionButton.small(
                    heroTag: 'move_to_current_location_btn',
                    onPressed: _isLocating ? null : _moveToCurrentLocation,
                    tooltip: 'Move to current location',
                    child: _isLocating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.my_location),
                  ),
                ),
                Positioned(
                  top: 128,
                  right: 16,
                  child: FloatingActionButton.small(
                    heroTag: 'toggle_tap_mode_btn',
                    backgroundColor: _isInsertMode
                        ? Colors.orange
                        : Colors.blue,
                    onPressed: _isSimulating
                        ? null
                        : () {
                            setState(() {
                              _isInsertMode = !_isInsertMode;
                            });
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(
                                  _isInsertMode
                                      ? 'Mode: Insert in Middle'
                                      : 'Mode: Add to End',
                                ),
                                duration: const Duration(seconds: 1),
                              ),
                            );
                          },
                    tooltip: _isInsertMode
                        ? 'Mode: Insert in Middle'
                        : 'Mode: Add to End',
                    child: Icon(
                      _isInsertMode ? Icons.alt_route : Icons.add_location_alt,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
          SafeArea(
            bottom: true,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
              padding: _isControlPanelExpanded
                  ? const EdgeInsets.all(16.0)
                  : const EdgeInsets.symmetric(vertical: 6.0),
              color: Theme.of(context).cardColor,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      setState(
                        () =>
                            _isControlPanelExpanded = !_isControlPanelExpanded,
                      );
                    },
                    onVerticalDragEnd: (dragDetails) {
                      if (dragDetails.primaryVelocity! < 0) {
                        setState(() => _isControlPanelExpanded = true);
                      } else if (dragDetails.primaryVelocity! > 0) {
                        setState(() => _isControlPanelExpanded = false);
                      }
                    },
                    child: SizedBox(
                      width: double.infinity,
                      height: 28,
                      child: Center(
                        child: Container(
                          width: 50,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Colors.grey.shade500,
                            borderRadius: BorderRadius.circular(10),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: ElevatedButton.icon(
                          icon: Icon(
                            _isSimulating ? Icons.stop : Icons.play_arrow,
                          ),
                          label: Text(
                            _isSimulating
                                ? 'Stop Simulation'
                                : 'Start Simulation',
                          ),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isSimulating
                                ? Colors.redAccent
                                : Colors.green,
                            foregroundColor: Colors.white,
                            minimumSize: const Size.fromHeight(48),
                          ),
                          onPressed: _isSimulating
                              ? _stopSimulation
                              : _startSimulation,
                        ),
                      ),

                      if (_isSimulating) ...[
                        const SizedBox(width: 8),

                        ElevatedButton.icon(
                          icon: Icon(
                            _isPaused ? Icons.play_arrow : Icons.pause,
                          ),
                          label: Text(_isPaused ? 'Continue' : 'Pause'),
                          style: ElevatedButton.styleFrom(
                            backgroundColor: _isPaused
                                ? Colors.green
                                : Colors.orange,
                            foregroundColor: Colors.white,
                            minimumSize: const Size(110, 48),
                          ),
                          onPressed: _togglePauseSimulation,
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 8),
                  if (_isControlPanelExpanded) ...[
                    Row(
                      children: [
                        InkWell(
                          onTap: () => _showSpeedInputDialog(),
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 4.0,
                              vertical: 8.0,
                            ),
                            child: Text('Speed: ${_speedKmH.round()} km/h'),
                          ),
                        ),

                        Expanded(
                          child: Slider(
                            value: _speedKmH,
                            min: 1.0,
                            max: 360.0,
                            divisions: 359,
                            label: '${_speedKmH.round()} km/h',
                            onChanged: (val) => _updateSpeed(val),
                          ),
                        ),
                      ],
                    ),
                    Row(
                      children: [
                        const Icon(
                          Icons.directions_walk,
                          size: 20,
                          color: Colors.blue,
                        ),
                        const SizedBox(width: 8),
                        const Text('Health Connect Steps:'),
                        const Spacer(),
                        Switch(
                          value: _enableHealthConnectSteps,
                          onChanged: (val) => _updateHealthConnectSteps(val),
                        ),
                      ],
                    ),
                    if (_enableHealthConnectSteps) ...[
                      Row(
                        children: [
                          InkWell(
                            onTap: () => _showStepsPerMeterInputDialog(),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 4.0,
                              ),
                              child: Text(
                                'Steps/Meter: ${_stepsPerMeter.toStringAsFixed(2)}',
                              ),
                            ),
                          ),

                          Expanded(
                            child: Slider(
                              value: _stepsPerMeter,
                              min: 0.1,
                              max: 5.0,
                              divisions: 30,
                              label:
                                  '${_stepsPerMeter.toStringAsFixed(2)} steps/m',
                              onChanged: (val) => _updateStepsPerMeter(val),
                            ),
                          ),
                        ],
                      ),
                    ],
                    Row(
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 4.0,
                            vertical: 8.0,
                          ),
                          child: Text('Enable Loop:'),
                        ),
                        Switch(
                          value: _enableLoop,
                          onChanged: _isSimulating
                              ? null
                              : (val) => _updateEnableLoop(val),
                        ),
                        const Spacer(),
                        if (_enableLoop)
                          TextButton(
                            onPressed: _isSimulating
                                ? null
                                : _showLoopTimesInputDialog,
                            child: Text(
                              _loopTimes <= 0
                                  ? 'Loops: Infinite'
                                  : 'Loops: $_loopTimes',
                            ),
                          ),
                      ],
                    ),
                    if (_enableLoop) ...[
                      Row(
                        children: [
                          const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 4.0,
                              vertical: 8.0,
                            ),
                            child: Text('Round-Trip Loop:'),
                          ),
                          const Spacer(),
                          Switch(
                            value: _isRoundTrip,
                            onChanged: _isSimulating
                                ? null
                                : (val) => _updateRoundTrip(val),
                          ),
                        ],
                      ),
                    ],
                    Row(
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(
                            horizontal: 4.0,
                            vertical: 8.0,
                          ),
                          child: Text('GPS/Steps Jitter:'),
                        ),

                        Switch(
                          value: _enableNoise,
                          onChanged: (val) => _updateNoise(val),
                        ),

                        const Spacer(),

                        Text('Points: ${_routePoints.length}'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: OutlinedButton.icon(
                        icon: const Icon(Icons.swap_vert),
                        label: const Text('Reverse Route'),
                        onPressed: _confirmReverseRoute,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
