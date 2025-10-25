import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:google_places_flutter/google_places_flutter.dart';
import 'package:google_places_flutter/model/prediction.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  try {
    await dotenv.load(fileName: "assets/.env");
    print('✅ Environment variables loaded successfully');
  } catch (e) {
    print('⚠️ Failed to load environment variables: $e');
  }

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Bike App (BLE + Routing)',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.deepPurple),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  StreamSubscription<List<ScanResult>>? _scanSub;
  StreamSubscription<Position>? _posSub;
  BluetoothDevice? _connectedDevice;
  BluetoothCharacteristic? _rxChar;
  BluetoothCharacteristic? _txChar;
  bool _isScanning = false;
  String _status = 'idle';
  final TextEditingController _destinationCtrl = TextEditingController();
  List<String> _routePoints = [];

  // Environment variables
  String _googleApiKey = '';
  String _routeApiUrl = '';

  // Route navigation state
  List<Map<String, dynamic>> _waypoints = [];
  int _currentWaypointIdx = 0;

  static const String _nusbService = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String _nusbTx = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String _nusbRx = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';

  @override
  void initState() {
    super.initState();
    _loadEnvironmentVariables();
  }

  Future<void> _loadEnvironmentVariables() async {
    try {
      setState(() {
        _googleApiKey = dotenv.env['GOOGLE_API_KEY'] ?? '';
        _routeApiUrl = dotenv.env['ROUTE_API_URL'] ??
            'https://google-maps-route-api.onrender.com/route';

        if (_googleApiKey.isEmpty) {
          _status = 'Warning: GOOGLE_API_KEY not found in environment file';
        } else {
          _status = 'Environment variables loaded successfully';
        }
      });
    } catch (e) {
      setState(() {
        _status = 'Error loading environment variables: $e';
      });
    }
  }

  @override
  void dispose() {
    _scanSub?.cancel();
    _posSub?.cancel();
    _destinationCtrl.dispose();
    _connectedDevice?.disconnect();
    super.dispose();
  }

  Future<void> _requestPermissions() async {
    if (await Permission.locationWhenInUse.request().isDenied) {
      throw Exception("Location permission denied");
    }
    if (await Permission.bluetoothScan.request().isDenied) {
      throw Exception("Bluetooth scan permission denied");
    }
    if (await Permission.bluetoothConnect.request().isDenied) {
      throw Exception("Bluetooth connect permission denied");
    }
  }

  void _startScan() async {
    try {
      await _requestPermissions();
    } catch (e) {
      setState(() => _status = 'Permission error: $e');
      return;
    }

    setState(() {
      _isScanning = true;
      _status = 'scanning for Pico...';
    });

    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        final advName = r.device.platformName;
        final advLocalName = r.advertisementData.advName;
        final name = advName.isNotEmpty ? advName : advLocalName;

        print('Found device: "$name" (${r.device.remoteId})');

        if (name.toLowerCase().contains('pico') ||
            name.contains('28:CD:C1:0C:8B:F3') ||
            r.device.remoteId.str.contains('28:CD:C1:0C:8B:F3')) {
          FlutterBluePlus.stopScan();
          setState(() {
            _status = 'found: $name (${r.device.remoteId})';
          });
          _connectToDevice(r.device);
          return;
        }
      }
    });

    await Future.delayed(const Duration(seconds: 10));
    if (_connectedDevice == null) {
      setState(() {
        _isScanning = false;
        _status = 'Pico not found. Make sure it is powered on and advertising.';
      });
    }
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    setState(() => _status = 'connecting to ${device.remoteId}...');

    try {
      await device.connect(timeout: const Duration(seconds: 15));
    } catch (e) {
      setState(() => _status = 'connection failed: $e');
      return;
    }

    setState(() => _status = 'discovering services...');

    final services = await device.discoverServices();
    BluetoothCharacteristic? rx;
    BluetoothCharacteristic? tx;

    for (var s in services) {
      if (s.uuid.toString().toUpperCase() == _nusbService.toUpperCase()) {
        for (var c in s.characteristics) {
          final id = c.uuid.toString().toUpperCase();
          if (id == _nusbRx.toUpperCase()) rx = c;
          if (id == _nusbTx.toUpperCase()) tx = c;
        }
      }
    }

    if (rx == null || tx == null) {
      for (var s in services) {
        for (var c in s.characteristics) {
          final uuid = c.uuid.toString().toUpperCase();
          if (uuid.contains('6E400002')) rx = c;
          if (uuid.contains('6E400003')) tx = c;
        }
      }
    }

    _rxChar = rx;
    _txChar = tx;

    if (_txChar != null) {
      await _txChar!.setNotifyValue(true);
      _txChar!.lastValueStream.listen((data) {
        if (data.isNotEmpty) {
          final s = utf8.decode(data);
          setState(() => _status = 'Pico says: $s');
        }
      });
    }

    setState(() {
      _connectedDevice = device;
      _isScanning = false;
      _status = rx != null && tx != null
          ? 'Connected to ${device.remoteId.str}'
          : 'Connected but UART characteristics not found';
    });
  }

  double _haversineDistance(
      double lat1, double lon1, double lat2, double lon2) {
    const R = 6371000.0; // Earth radius in meters
    final lat1Rad = lat1 * math.pi / 180.0;
    final lat2Rad = lat2 * math.pi / 180.0;
    final dLat = (lat2 - lat1) * math.pi / 180.0;
    final dLon = (lon2 - lon1) * math.pi / 180.0;
    final a = math.sin(dLat / 2) * math.sin(dLat / 2) +
        math.cos(lat1Rad) *
            math.cos(lat2Rad) *
            math.sin(dLon / 2) *
            math.sin(dLon / 2);
    final c = 2 * math.atan2(math.sqrt(a), math.sqrt(1 - a));
    return R * c;
  }

  double _bearingDegrees(double lat1, double lon1, double lat2, double lon2) {
    final lat1Rad = lat1 * math.pi / 180.0;
    final lat2Rad = lat2 * math.pi / 180.0;
    final dLon = (lon2 - lon1) * math.pi / 180.0;
    final x = math.sin(dLon) * math.cos(lat2Rad);
    final y = math.cos(lat1Rad) * math.sin(lat2Rad) -
        math.sin(lat1Rad) * math.cos(lat2Rad) * math.cos(dLon);
    final brng = math.atan2(x, y) * 180.0 / math.pi;
    return (brng + 360) % 360;
  }

  String _classifyTurn(Map<String, dynamic> prev, Map<String, dynamic> curr,
      Map<String, dynamic> next) {
    try {
      final inB =
          _bearingDegrees(prev['lat'], prev['lng'], curr['lat'], curr['lng']);
      final outB =
          _bearingDegrees(curr['lat'], curr['lng'], next['lat'], next['lng']);
      double diff = (outB - inB + 540) % 360 - 180;
      if (diff.abs() <= 15) return 'STRAIGHT';
      return diff > 0 ? 'RIGHT' : 'LEFT';
    } catch (_) {
      return 'STRAIGHT';
    }
  }

  String _extractStreet(String? desc) {
    if (desc == null || desc.isEmpty) return 'Unknown';
    final d = desc.toLowerCase();
    if (d.contains(' on ')) {
      final parts = d.split(' on ');
      if (parts.length > 1) return parts[1].split(' ')[0];
    }
    if (d.contains(' onto ')) {
      final parts = d.split(' onto ');
      if (parts.length > 1) return parts[1].split(' ')[0];
    }
    final words = desc.split(' ');
    return words.length > 1 ? '${words[0]} ${words[1]}' : words[0];
  }

  Future<void> _startLocationStreaming() async {
    // cancel any previous stream
    await _posSub?.cancel();
    const locSettings = LocationSettings(
      accuracy: LocationAccuracy.high,
      distanceFilter: 1, // meters - update every meter
      timeLimit: Duration(seconds: 1), // force update every second
    );
    _posSub = Geolocator.getPositionStream(locationSettings: locSettings)
        .listen((pos) async {
      if (_connectedDevice == null || _rxChar == null) return;

      // Advance through waypoints within 20m
      while (_currentWaypointIdx < _waypoints.length) {
        final wp = _waypoints[_currentWaypointIdx];
        final d = _haversineDistance(
            pos.latitude, pos.longitude, wp['lat'], wp['lng']);
        if (d <= 20) {
          _currentWaypointIdx++;
        } else {
          break;
        }
      }

      // Reached destination
      if (_currentWaypointIdx >= _waypoints.length) {
        try {
          final msg = 'NAV:DESTINATION|0m|ARRIVED|REACHED\n';
          await _rxChar!.write(utf8.encode(msg), withoutResponse: false);
          setState(() => _status = 'Destination reached!');
        } catch (_) {}
        return;
      }

      // Compute navigation message
      final curr = _waypoints[_currentWaypointIdx];
      final dist = _haversineDistance(
          pos.latitude, pos.longitude, curr['lat'], curr['lng']);
      final distText = dist > 1000
          ? '${(dist / 1000).toStringAsFixed(1)}km'
          : '${dist.toInt()}m';

      String currentStreet = _currentWaypointIdx > 0
          ? _extractStreet(_waypoints[_currentWaypointIdx - 1]['description'])
          : 'Start';
      String nextStreet = _extractStreet(curr['description']);
      String turnLabel = 'STRAIGHT';

      if (_currentWaypointIdx > 0 &&
          _currentWaypointIdx < _waypoints.length - 1) {
        turnLabel = _classifyTurn(
          _waypoints[_currentWaypointIdx - 1],
          curr,
          _waypoints[_currentWaypointIdx + 1],
        );
      }

      // Send: NAV:currentStreet|dist|turn|nextStreet
      final navMsg = 'NAV:$currentStreet|$distText|$turnLabel|$nextStreet\n';
      try {
        await _rxChar!.write(utf8.encode(navMsg), withoutResponse: false);
        setState(() => _status = 'ON $currentStreet | IN $distText $turnLabel');
      } catch (e) {
        // occasional failure OK
      }
    });
  }

  Future<Position> _getCurrentLocation() async {
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        throw Exception('Location permission denied');
      }
    }
    if (permission == LocationPermission.deniedForever) {
      throw Exception('Location permission permanently denied');
    }
    return await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high);
  }

  Future<void> _handlePlaceSelection(Prediction prediction) async {
    setState(() {
      _destinationCtrl.text = prediction.description ?? '';
    });
  }

  Future<void> _requestRouteAndSend() async {
    if (_connectedDevice == null || _rxChar == null) {
      setState(() => _status = 'Not connected to Pico');
      return;
    }

    final dest = _destinationCtrl.text.trim();
    if (dest.isEmpty) {
      setState(() => _status = 'Please select a destination');
      return;
    }

    setState(() => _status = 'Getting current location...');
    Position pos;
    try {
      pos = await _getCurrentLocation();
    } catch (e) {
      setState(() => _status = 'Location error: $e');
      return;
    }

    final body = json.encode({
      'origin': {'lat': pos.latitude, 'lng': pos.longitude},
      'destination': dest,
    });

    http.Response resp;
    try {
      setState(() => _status = 'Connecting to route server...');
      resp = await http
          .post(Uri.parse(_routeApiUrl),
              headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 20));
    } on SocketException catch (e) {
      setState(() => _status =
          'Network error: Cannot reach route server. Check internet connection.\nDetails: ${e.message}');
      return;
    } on TimeoutException catch (_) {
      setState(() => _status = 'Route request timed out. Server may be down.');
      return;
    } catch (e) {
      setState(() => _status = 'Route request failed: $e');
      return;
    }

    if (resp.statusCode < 200 || resp.statusCode >= 300) {
      setState(
          () => _status = 'Route API error ${resp.statusCode}: ${resp.body}');
      return;
    }

    final decoded = json.decode(resp.body);
    final routes = decoded['routes'] ?? [];
    if (routes.isEmpty) {
      setState(() => _status = 'No routes returned from server');
      return;
    }

    final firstRoute = routes[0];
    final points = firstRoute['points'] as List<dynamic>;

    // Store waypoints for local navigation processing
    setState(() {
      _waypoints = points
          .map((p) => {
                'lat': p['lat'] as double,
                'lng': p['lng'] as double,
                'description': p['description'] ?? '',
              })
          .toList();
      _currentWaypointIdx = 0;
      _routePoints = points.map((p) {
        final lat = p['lat'];
        final lng = p['lng'];
        final desc = p['description'] ?? '';
        return '$lat, $lng ${desc.isNotEmpty ? "- $desc" : ""}';
      }).toList();
      _status =
          'Route loaded: ${_waypoints.length} waypoints. Starting live navigation...';
    });

    // Begin streaming live location and computing nav updates locally
    await _startLocationStreaming();
    print('✅ Route loaded and navigation started');
  }

  Widget _buildConnectionCard() {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Status: $_status', style: const TextStyle(fontSize: 14)),
            const SizedBox(height: 12),
            Row(children: [
              ElevatedButton(
                onPressed: _isScanning ? null : _startScan,
                child: Text(_isScanning ? 'Scanning...' : 'Scan & Connect'),
              ),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _connectedDevice != null
                    ? () async {
                        await _connectedDevice!.disconnect();
                        setState(() {
                          _connectedDevice = null;
                          _rxChar = null;
                          _txChar = null;
                          _status = 'Disconnected';
                          _routePoints = [];
                        });
                        await _posSub?.cancel();
                      }
                    : null,
                child: const Text('Disconnect'),
              ),
            ])
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Bike Navigation'),
        backgroundColor: Theme.of(context).colorScheme.inversePrimary,
      ),
      body: Padding(
        padding: const EdgeInsets.all(12.0),
        child: ListView(children: [
          _buildConnectionCard(),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Destination',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  GooglePlaceAutoCompleteTextField(
                    textEditingController: _destinationCtrl,
                    googleAPIKey: _googleApiKey,
                    inputDecoration: const InputDecoration(
                      hintText: 'Search for a place',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.search),
                    ),
                    debounceTime: 400,
                    countries: const ["us"],
                    isLatLngRequired: true,
                    getPlaceDetailWithLatLng: (prediction) {
                      _handlePlaceSelection(prediction);
                    },
                    itemClick: (prediction) {
                      _destinationCtrl.text = prediction.description ?? '';
                      _destinationCtrl.selection = TextSelection.fromPosition(
                        TextPosition(
                            offset: prediction.description?.length ?? 0),
                      );
                    },
                    seperatedBuilder: const Divider(),
                    containerHorizontalPadding: 10,
                    itemBuilder: (context, index, prediction) {
                      return Container(
                        padding: const EdgeInsets.all(10),
                        child: Row(
                          children: [
                            const Icon(Icons.location_on),
                            const SizedBox(width: 7),
                            Expanded(
                              child: Text(prediction.description ?? ''),
                            )
                          ],
                        ),
                      );
                    },
                    isCrossBtnShown: true,
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton.icon(
                      onPressed: _connectedDevice != null &&
                              _destinationCtrl.text.isNotEmpty
                          ? _requestRouteAndSend
                          : null,
                      icon: const Icon(Icons.navigation),
                      label: const Text('Get Route & Send to Pico'),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          if (_routePoints.isNotEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('Route Points',
                        style: TextStyle(
                            fontSize: 16, fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    ..._routePoints.map((p) => Text(p)).toList(),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 8),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Device Info',
                      style:
                          TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                  const SizedBox(height: 8),
                  Text(
                    _connectedDevice != null
                        ? 'Connected: ${_connectedDevice!.remoteId.str}'
                        : 'Not connected',
                    style: TextStyle(
                      color:
                          _connectedDevice != null ? Colors.green : Colors.grey,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ]),
      ),
    );
  }
}
