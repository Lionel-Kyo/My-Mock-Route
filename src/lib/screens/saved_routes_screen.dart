import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/saved_route.dart';

class SavedRoutesScreen extends StatefulWidget {
  const SavedRoutesScreen({super.key});

  @override
  State<SavedRoutesScreen> createState() => _SavedRoutesScreenState();
}

class _SavedRoutesScreenState extends State<SavedRoutesScreen> {
  List<SavedRoute> _records = [];

  @override
  void initState() {
    super.initState();
    _loadRecords();
  }

  Future<void> _loadRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final String? data = prefs.getString('saved_routes');
    if (data != null) {
      final List decoded = jsonDecode(data);
      setState(() {
        _records = decoded.map((e) => SavedRoute.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveAllRecords() async {
    final prefs = await SharedPreferences.getInstance();
    final encoded = jsonEncode(_records.map((e) => e.toJson()).toList());
    await prefs.setString('saved_routes', encoded);
  }

  Future<void> _deleteRecord(int index) async {
    final bool? confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Delete Route'),
        content: const Text('Are you sure you want to delete this route?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirm == true) {
      setState(() {
        _records.removeAt(index);
      });
      await _saveAllRecords();
    }
  }

  Future<void> _editRecord(int index) async {
    final record = _records[index];
    final nameController = TextEditingController(text: record.name);
    final speedController = TextEditingController(text: record.speedKmH.toString());

    final bool? updated = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Modify Route'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                labelText: 'Route Name',
                border: OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: speedController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(
                labelText: 'Speed (km/h)',
                border: OutlineInputBorder(),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (updated == true) {
      final newName = nameController.text.trim();
      final newSpeed = double.tryParse(speedController.text.trim()) ?? record.speedKmH;

      if (newName.isNotEmpty) {
        setState(() {
          _records[index] = SavedRoute(
            id: record.id,
            name: newName,
            points: record.points,
            speedKmH: newSpeed,
            createdAt: record.createdAt,
          );
        });
        await _saveAllRecords();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Route updated successfully!')),
          );
        }
      }
    }
  }

  Future<void> _importRoute() async {
    try {
      final List<PlatformFile> result = await FilePicker.pickFiles(
        type: Platform.isAndroid ? FileType.any : FileType.custom,
        allowedExtensions: Platform.isAndroid ? null : ['gpx', 'json'],
      );

      if (result.isEmpty) return;

      final fileItem = result.first;
      String content;

      if (fileItem.path != null && fileItem.path!.isNotEmpty) {
        final file = File(fileItem.path!);
        content = await file.readAsString();
      } else {
        final Uint8List bytes = await fileItem.readAsBytes();
        content = utf8.decode(bytes);
      }

      List<LatLng> importedPoints = [];
      String routeName = fileItem.name;
      double speedKmH = SavedRoute.getDefaultSpeedKmH();
      DateTime createdAt = DateTime.now();

      if (routeName.toLowerCase().endsWith('.gpx')) {
        final route = SavedRoute.fromGpx(content, fileName: routeName);
        importedPoints = route.points;
        routeName = route.name;
        speedKmH = route.speedKmH;
        createdAt = route.createdAt;
      } else if (routeName.toLowerCase().endsWith('.json')) {
        final Map<String, dynamic> json = jsonDecode(content);
        final route = SavedRoute.fromJson(json, fileName: routeName);
        importedPoints = route.points;
        routeName = route.name;
        speedKmH = route.speedKmH;
        createdAt = route.createdAt;
      }

      if (importedPoints.isEmpty) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('No valid coordinates found in file.'),
            ),
          );
        }
        return;
      }

      final newRecord = SavedRoute(
        id: SavedRoute.getNewId(),
        name: routeName.replaceAll(
          RegExp(r'\.(gpx|json)$', caseSensitive: false),
          '',
        ),
        points: importedPoints,
        speedKmH: speedKmH,
        createdAt: createdAt,
      );

      setState(() {
        _records.add(newRecord);
      });
      await _saveAllRecords();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Imported "${newRecord.name}" successfully!')),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to import file: $e')));
      }
    }
  }

  Future<void> _exportRecord(SavedRoute record) async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.code),
              title: const Text('Export as GPX'),
              onTap: () => Navigator.pop(context, 'gpx'),
            ),
            ListTile(
              leading: const Icon(Icons.data_object),
              title: const Text('Export as JSON'),
              onTap: () => Navigator.pop(context, 'json'),
            ),
          ],
        ),
      ),
    );

    if (choice == null) return;

    try {
      final String content = choice == 'gpx'
          ? record.toGpx()
          : jsonEncode(record.toJson());
      final Uint8List bytes = Uint8List.fromList(utf8.encode(content));
      final String sanitizedName = record.name.replaceAll(
        RegExp(r'[^\w\s-]'),
        '_',
      );
      final String fileName = '$sanitizedName.$choice';

      Uri? outputFile = await FilePicker.saveFile(
        dialogTitle: 'Export Route Record',
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: [choice],
        bytes: bytes,
      );

      if (outputFile != null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Exported successfully: $fileName')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Export failed: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Saved Route Records'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload),
            tooltip: 'Import Route',
            onPressed: _importRoute,
          ),
        ],
      ),
      body: _records.isEmpty
          ? const Center(child: Text('No saved routes found.'))
          : ListView.builder(
              itemCount: _records.length,
              itemBuilder: (context, index) {
                final record = _records[index];
                return ListTile(
                  title: Text(record.name),
                  subtitle: Text(
                    '${record.points.length} points • ${record.speedKmH.round()} km/h\nCreated: ${record.createdAt.toString().substring(0, 16)}',
                  ),
                  isThreeLine: true,
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.download, color: Colors.blueAccent),
                        tooltip: 'Export Route',
                        onPressed: () => _exportRecord(record),
                      ),
                      IconButton(
                        icon: const Icon(Icons.delete, color: Colors.redAccent),
                        tooltip: 'Delete Route',
                        onPressed: () => _deleteRecord(index),
                      ),
                    ],
                  ),
                  onTap: () {
                    Navigator.pop(context, record);
                  },
                  onLongPress: () => _editRecord(index),
                );
              },
            ),
    );
  }
}