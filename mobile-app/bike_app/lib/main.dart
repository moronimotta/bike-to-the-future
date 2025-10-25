import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:permission_handler/permission_handler.dart';
import 'package:google_places_flutter/google_places_flutter.dart';
import 'package:google_places_flutter/model/prediction.dart';

void main() {
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

  static const String _nusbService = '6E400001-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String _nusbTx = '6E400003-B5A3-F393-E0A9-E50E24DCCA9E';
  static const String _nusbRx = '6E400002-B5A3-F393-E0A9-E50E24DCCA9E';

  static const String _routeApiUrl =
      'https://google-maps-route-api.onrender.com/routes';

  // Replace with your actual Google Maps API key
  static const kGoogleApiKey = 'AIzaSyBaC0kLKREARMroxBoEU6u5nFzjgoijML4';

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

    // Start scanning
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    // Listen to scan results
    _scanSub = FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        final advName = r.device.platformName;
        final advLocalName = r.advertisementData.advName;
        final name = advName.isNotEmpty ? advName : advLocalName;

        print('Found device: "$name" (${r.device.remoteId})'); // Debug log

        // Check if device name matches your Pico (case-insensitive)
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

    // Handle scan completion
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

    // Find UART service characteristics
    for (var s in services) {
      if (s.uuid.toString().toUpperCase() == _nusbService.toUpperCase()) {
        for (var c in s.characteristics) {
          final id = c.uuid.toString().toUpperCase();
          if (id == _nusbRx.toUpperCase()) rx = c;
          if (id == _nusbTx.toUpperCase()) tx = c;
        }
      }
    }

    // Fallback: search by partial UUID
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

    // Subscribe to TX characteristic for receiving data from Pico
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

  // This method is called when destination field is tapped
  // The actual autocomplete is handled inline in the TextField widget
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

    setState(() => _status = 'Requesting route from server...');
    final body = json.encode({
      'Origin': {'lat': pos.latitude, 'lng': pos.longitude},
      'Destination': dest,
    });

    http.Response resp;
    try {
      resp = await http
          .post(Uri.parse(_routeApiUrl),
              headers: {'Content-Type': 'application/json'}, body: body)
          .timeout(const Duration(seconds: 20));
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
    final routes = decoded['Routes'] ?? decoded['routes'] ?? [];
    if (routes.isEmpty) {
      setState(() => _status = 'No routes returned from server');
      return;
    }

    final firstRoute = routes[0];
    final points = firstRoute['points'] as List<dynamic>;
    final buffer = StringBuffer();
    for (var p in points) {
      final lat = p['lat'];
      final lng = p['lng'];
      final desc = p['description'] ?? '';
      buffer.writeln('$lat,$lng,$desc');
    }

    setState(() => _status = 'Sending ${points.length} waypoints to Pico...');
    final payload = utf8.encode(buffer.toString());

    try {
      const chunkSize = 150;
      for (var offset = 0; offset < payload.length; offset += chunkSize) {
        final end = (offset + chunkSize < payload.length)
            ? offset + chunkSize
            : payload.length;
        final chunk = payload.sublist(offset, end);
        await _rxChar!.write(chunk, withoutResponse: true);
        await Future.delayed(const Duration(milliseconds: 60));
      }
      setState(() =>
          _status = 'Route sent! ${points.length} waypoints transferred.');
    } catch (e) {
      setState(() => _status = 'Send failed: $e');
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
                    googleAPIKey: kGoogleApiKey,
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
