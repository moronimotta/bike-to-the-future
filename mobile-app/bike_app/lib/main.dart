import 'dart:async';
import 'dart:convert';
import 'dart:io';

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

    // Update UI to display route
    setState(() {
      _routePoints = points.map((p) {
        final lat = p['lat'];
        final lng = p['lng'];
        final desc = p['description'] ?? '';
        return '$lat, $lng ${desc.isNotEmpty ? "- $desc" : ""}';
      }).toList();
    });

    // Send route to Pico as JSON
    setState(() => _status = 'Sending ${points.length} waypoints to Pico...');

    // Format the data as JSON matching Pico's expected structure
    final jsonData = json.encode({
      'routes': [
        {
          'points': points
              .map((p) => {
                    'lat': p['lat'],
                    'lng': p['lng'],
                    'description': p['description'] ?? '',
                    'is_down_hill': false,
                  })
              .toList()
        }
      ]
    });

    final payload = utf8.encode(jsonData);
    print('📤 Total JSON payload size: ${payload.length} bytes');

    try {
      // Use smaller chunk size to match actual BLE transfer capacity
      const chunkSize = 20; // Match the observed chunk size from Pico
      int totalChunks = (payload.length / chunkSize).ceil();

      setState(() => _status = 'Sending ${totalChunks} chunks to Pico...');

      for (var offset = 0; offset < payload.length; offset += chunkSize) {
        final end = (offset + chunkSize < payload.length)
            ? offset + chunkSize
            : payload.length;
        final chunk = payload.sublist(offset, end);

        int chunkNumber = (offset / chunkSize).floor() + 1;
        print(
            '📤 Sending chunk $chunkNumber/$totalChunks (${chunk.length} bytes)');

        // Use withoutResponse: false because Pico UART requires write with response
        await _rxChar!.write(chunk, withoutResponse: false);

        // Update status with progress
        setState(() => _status = 'Sending chunk $chunkNumber/$totalChunks...');

        // Longer delay between chunks to ensure Pico can process
        await Future.delayed(const Duration(milliseconds: 150));
      }

      setState(() => _status =
          'Route sent! ${points.length} waypoints in ${totalChunks} chunks.');

      print('✅ All chunks sent successfully');
    } catch (e) {
      setState(() => _status = 'Send failed: $e');
      print('❌ Send error: $e');
    }
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
