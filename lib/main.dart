import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart' as ble;
import 'package:flutter_bluetooth_serial_plus/flutter_bluetooth_serial_plus.dart';

void main() => runApp(const GDashApp());

class GDashApp extends StatelessWidget {
  const GDashApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'GDash',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      brightness: Brightness.dark,
      scaffoldBackgroundColor: const Color(0xFF0A0D12),
      colorScheme: ColorScheme.fromSeed(
        seedColor: const Color(0xFF43E2B2),
        brightness: Brightness.dark,
        surface: const Color(0xFF121821),
      ),
      useMaterial3: true,
      fontFamily: 'Roboto',
    ),
    home: const DashboardPage(),
  );
}

class VehicleData {
  int? rpm;
  int? coolant;
  int? fuel;
  double? ignition;
  double? maf;
  int? speed;
  int? accelerator;
  double? manifoldPressureKpa;
  double? barometricPressureKpa;

  double? get turboPressureBar {
    if (manifoldPressureKpa == null || barometricPressureKpa == null) {
      return null;
    }
    return (manifoldPressureKpa! - barometricPressureKpa!) / 100;
  }

  double? get consumption {
    if (maf == null || speed == null || speed == 0) return null;
    // Estimate gasoline consumption, converting L/100 km into km/L.
    final litersPer100Km = 100 * maf! * 3600 / (14.7 * 745 * speed!);
    if (litersPer100Km <= 0) return null;
    return 100 / litersPer100Km;
  }
}

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _AdapterCandidate {
  _AdapterCandidate.classic(BluetoothDevice device)
    : name = device.name,
      address = device.address,
      classicDevice = device,
      bleDevice = null;

  _AdapterCandidate.ble(ble.BluetoothDevice device, String name)
    : name = name.isNotEmpty ? name : null,
      address = device.remoteId.str,
      classicDevice = null,
      bleDevice = device;

  final String? name;
  final String address;
  final BluetoothDevice? classicDevice;
  final ble.BluetoothDevice? bleDevice;

  bool get isBle => bleDevice != null;
}

class _DashboardPageState extends State<DashboardPage>
    with SingleTickerProviderStateMixin {
  late final AnimationController _shiftLightController = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 350),
  );
  final _bluetooth = FlutterBluetoothSerial.instance;
  final _data = VehicleData();
  final List<String> _log = [];
  List<BluetoothDevice> _devices = [];
  BluetoothConnection? _connection;
  StreamSubscription<Uint8List>? _input;
  StreamSubscription<List<int>>? _bleInput;
  StreamSubscription<ble.BluetoothConnectionState>? _bleState;
  ble.BluetoothDevice? _bleDevice;
  ble.BluetoothCharacteristic? _bleWriteCharacteristic;
  bool _busy = false;
  bool _connected = false;
  String _status = 'Pronto para conectar';
  String _vehicleName = 'Nenhum scanner conectado';
  Completer<String>? _pendingResponse;
  final StringBuffer _responseBuffer = StringBuffer();

  @override
  void dispose() {
    _input?.cancel();
    _bleInput?.cancel();
    _bleState?.cancel();
    _connection?.dispose();
    _bleDevice?.disconnect();
    _shiftLightController.dispose();
    super.dispose();
  }

  void _syncShiftLights() {
    final shouldBlink = (_data.rpm ?? 0) >= 6000;
    if (shouldBlink && !_shiftLightController.isAnimating) {
      _shiftLightController.repeat(reverse: true);
    } else if (!shouldBlink && _shiftLightController.isAnimating) {
      _shiftLightController.stop();
      _shiftLightController.value = 1;
    }
  }

  Future<bool> _ensureBluetoothPermission() async {
    try {
      return await _bluetooth.ensurePermissions();
    } catch (_) {
      return true; // Older plugin builds request permission while listing devices.
    }
  }

  Future<void> _loadDevices() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _status = 'Procurando dispositivos pareados…';
    });
    try {
      final granted = await _ensureBluetoothPermission();
      if (!granted) throw Exception('Permissão de Bluetooth não concedida.');
      final enabled = await _bluetooth.isEnabled ?? false;
      if (!enabled) {
        await _bluetooth.requestEnable();
      }
      final devices = await _bluetooth.getBondedDevices();
      if (!mounted) return;
      setState(() {
        _devices = devices;
        _status = 'Buscando scanners Bluetooth próximos…';
      });
      await _chooseDevice();
    } catch (e) {
      if (mounted) setState(() => _status = 'Bluetooth indisponível: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _chooseDevice() async {
    if (!mounted) return;
    final devices = ValueNotifier<List<_AdapterCandidate>>(
      _devices.map(_AdapterCandidate.classic).toList(),
    );
    final knownAddresses = devices.value
        .map((device) => 'classic:${device.address}')
        .toSet();
    final classicScan = _bluetooth.startDiscovery().listen((result) {
      final candidate = _AdapterCandidate.classic(result.device);
      if (knownAddresses.add('classic:${candidate.address}')) {
        devices.value = [...devices.value, candidate];
      }
    }, onError: (_) {});
    final bleScan = ble.FlutterBluePlus.scanResults.listen((results) {
      for (final result in results) {
        final device = result.device;
        final name = result.advertisementData.advName.isNotEmpty
            ? result.advertisementData.advName
            : device.platformName;
        final candidate = _AdapterCandidate.ble(device, name);
        if (knownAddresses.add('ble:${candidate.address}')) {
          devices.value = [...devices.value, candidate];
        }
      }
    }, onError: (_) {});
    unawaited(
      ble.FlutterBluePlus.startScan(timeout: const Duration(seconds: 20))
          .catchError((_) {}),
    );

    _AdapterCandidate? selected;
    try {
      selected = await showModalBottomSheet<_AdapterCandidate>(
        context: context,
        isScrollControlled: true,
        backgroundColor: const Color(0xFF151D27),
        builder: (context) => SafeArea(
          child: SizedBox(
            height: MediaQuery.sizeOf(context).height * 0.65,
            child: Column(
              children: [
                const Padding(
                  padding: EdgeInsets.all(20),
                  child: Text(
                    'Scanners Bluetooth próximos',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                ),
                Expanded(
                  child: ValueListenableBuilder<List<_AdapterCandidate>>(
                    valueListenable: devices,
                    builder: (context, foundDevices, _) {
                      if (foundDevices.isEmpty) {
                        return const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(),
                              SizedBox(height: 14),
                              Text('Procurando dispositivos…'),
                            ],
                          ),
                        );
                      }
                      return ListView.builder(
                        itemCount: foundDevices.length,
                        itemBuilder: (context, index) {
                          final device = foundDevices[index];
                          return ListTile(
                            leading: Icon(
                              device.isBle
                                  ? Icons.bluetooth_connected
                                  : Icons.bluetooth,
                              color: Color(0xFF43E2B2),
                            ),
                            title: Text(
                              device.name?.isNotEmpty == true
                                  ? device.name!
                                  : 'Dispositivo Bluetooth',
                            ),
                            subtitle: Text(
                              '${device.isBle ? 'Bluetooth LE' : (device.classicDevice!.isBonded ? 'Bluetooth clássico · pareado' : 'Bluetooth clássico · encontrado')} · ${device.address}',
                            ),
                            onTap: () => Navigator.pop(context, device),
                          );
                        },
                      );
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(12),
                  child: TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancelar busca'),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    } finally {
      await classicScan.cancel();
      await _bluetooth.cancelDiscovery();
      await bleScan.cancel();
      await ble.FlutterBluePlus.stopScan().catchError((_) {});
      devices.dispose();
    }
    if (selected != null) {
      final candidate = selected;
      if (candidate.bleDevice != null) {
        await _connectBle(candidate.bleDevice!, candidate.name);
      } else {
        await _connect(candidate.classicDevice!);
      }
    }
  }

  Future<void> _connect(BluetoothDevice device) async {
    setState(() {
      _busy = true;
      _status = 'Conectando ao scanner…';
    });
    try {
      final connection = await BluetoothConnection.toAddress(device.address);
      _connection = connection;
      _input = connection.input.listen((bytes) {
        _receive(ascii.decode(bytes, allowInvalid: true));
      }, onDone: _disconnected);
      if (!mounted) return;
      setState(() {
        _connected = true;
        _vehicleName = device.name?.isNotEmpty == true
            ? device.name!
            : 'ELM327';
        _status = 'Inicializando comunicação OBD-II…';
      });
      await _initializeElm();
      if (!mounted) return;
      setState(() => _status = 'Conectado · lendo dados do veículo');
      _poll();
    } catch (e) {
      if (mounted) {
        setState(() {
          _connected = false;
          _status = 'Falha ao conectar. Confirme que o adaptador usa Bluetooth clássico SPP e tente novamente.';
        });
      }
      _addLog('Conexão: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _connectBle(ble.BluetoothDevice device, String? name) async {
    setState(() {
      _busy = true;
      _status = 'Conectando ao scanner BLE…';
    });
    try {
      await device.connect(
        license: ble.License.free,
        timeout: const Duration(seconds: 15),
      );
      final services = await device.discoverServices();
      final characteristics = services
          .expand((service) => service.characteristics)
          .toList();
      final notifiable = characteristics
          .where((c) => c.properties.notify || c.properties.indicate)
          .toList();
      final writable = characteristics
          .where((c) => c.properties.write || c.properties.writeWithoutResponse)
          .toList();
      if (notifiable.isEmpty || writable.isEmpty) {
        throw StateError('O scanner BLE não expõe um canal serial compatível.');
      }
      notifiable.sort((a, b) {
        final aPreferred = a.characteristicUuid.str.toLowerCase().endsWith(
          'ffe1',
        );
        final bPreferred = b.characteristicUuid.str.toLowerCase().endsWith(
          'ffe1',
        );
        return (bPreferred ? 1 : 0).compareTo(aPreferred ? 1 : 0);
      });
      writable.sort((a, b) {
        final aPreferred = a.characteristicUuid.str.toLowerCase().endsWith(
          'ffe1',
        );
        final bPreferred = b.characteristicUuid.str.toLowerCase().endsWith(
          'ffe1',
        );
        return (bPreferred ? 1 : 0).compareTo(aPreferred ? 1 : 0);
      });
      final readCharacteristic = notifiable.first;
      final writeCharacteristic = writable.first;
      _bleDevice = device;
      _bleWriteCharacteristic = writeCharacteristic;
      await readCharacteristic.setNotifyValue(true);
      _bleInput = readCharacteristic.onValueReceived.listen((bytes) {
        _receive(ascii.decode(bytes, allowInvalid: true));
      });
      _bleState = device.connectionState.listen((state) {
        if (state == ble.BluetoothConnectionState.disconnected) {
          _bleDevice = null;
          _bleWriteCharacteristic = null;
          _disconnected();
        }
      });
      if (!mounted) return;
      setState(() {
        _connected = true;
        _vehicleName = name?.isNotEmpty == true ? name! : 'ELM327 BLE';
        _status = 'Inicializando comunicação OBD-II…';
      });
      await _initializeElm();
      if (!mounted) return;
      setState(() => _status = 'Conectado · lendo dados do veículo');
      _poll();
    } catch (e) {
      await _bleInput?.cancel();
      await _bleState?.cancel();
      await device.disconnect();
      _bleDevice = null;
      _bleInput = null;
      _bleState = null;
      _bleWriteCharacteristic = null;
      if (mounted) {
        setState(() {
          _connected = false;
          _status = 'Falha ao abrir a conexão BLE serial do scanner.';
        });
      }
      _addLog('Conexão BLE: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _initializeElm() async {
    for (final command in ['ATZ', 'ATE0', 'ATL0', 'ATS0', 'ATH0', 'ATSP0']) {
      await _send(command, waitForResponse: true);
    }
  }

  Future<String> _send(String command, {bool waitForResponse = false}) async {
    final connection = _connection;
    final bleCharacteristic = _bleWriteCharacteristic;
    if ((connection == null || !connection.isConnected) &&
        (_bleDevice == null || bleCharacteristic == null)) {
      return '';
    }
    _responseBuffer.clear();
    final completer = Completer<String>();
    if (waitForResponse) _pendingResponse = completer;
    final bytes = ascii.encode('$command\r');
    if (connection != null && connection.isConnected) {
      connection.output.add(bytes);
      await connection.output.allSent;
    } else {
      await bleCharacteristic!.write(
        bytes,
        withoutResponse:
            !bleCharacteristic.properties.write &&
            bleCharacteristic.properties.writeWithoutResponse,
      );
    }
    if (!waitForResponse) return '';
    try {
      final result = await completer.future.timeout(
        const Duration(seconds: 3),
        onTimeout: () => _responseBuffer.toString(),
      );
      return result;
    } finally {
      _pendingResponse = null;
    }
  }

  void _receive(String text) {
    _responseBuffer.write(text);
    if (text.contains('>') &&
        _pendingResponse != null &&
        !_pendingResponse!.isCompleted) {
      _pendingResponse!.complete(_responseBuffer.toString());
    }
    final clean = text.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), '');
    // The OBD stream also arrives through the permanent listener; parse supported replies.
    _parseReply(clean);
  }

  void _parseReply(String hex) {
    final match = RegExp(r'41([0-9A-F]{2})([0-9A-F]{2,})').firstMatch(hex);
    if (match == null) return;
    final pid = match.group(1)!;
    final payload = match.group(2)!;
    final bytes = <int>[];
    for (var i = 0; i + 1 < payload.length; i += 2) {
      final byte = int.tryParse(payload.substring(i, i + 2), radix: 16);
      if (byte != null) bytes.add(byte);
    }
    if (bytes.isEmpty) return;
    setState(() {
      switch (pid) {
        case '0C':
          if (bytes.length >= 2) _data.rpm = ((bytes[0] * 256 + bytes[1]) ~/ 4);
          _syncShiftLights();
          break;
        case '05':
          _data.coolant = bytes[0] - 40;
          break;
        case '2F':
          _data.fuel = (bytes[0] * 100 / 255).round();
          break;
        case '0E':
          _data.ignition = bytes[0] / 2 - 64;
          break;
        case '10':
          if (bytes.length >= 2) _data.maf = (bytes[0] * 256 + bytes[1]) / 100;
          break;
        case '0D':
          _data.speed = bytes[0];
          break;
        case '0B':
          _data.manifoldPressureKpa = bytes[0].toDouble();
          break;
        case '33':
          _data.barometricPressureKpa = bytes[0].toDouble();
          break;
        case '49':
          _data.accelerator = (bytes[0] * 100 / 255).round();
          break;
        case '11':
          _data.accelerator ??= (bytes[0] * 100 / 255).round();
          break;
      }
    });
  }

  Future<void> _poll() async {
    if (!_connected || !mounted) return;
    const pids = [
      '010C',
      '0105',
      '012F',
      '010E',
      '0110',
      '010D',
      '010B',
      '0133',
      '0149',
      '0111',
    ];
    for (final pid in pids) {
      if (!_connected || !mounted) break;
      final response = await _send(pid, waitForResponse: true);
      _parseReply(response.toUpperCase().replaceAll(RegExp(r'[^0-9A-F]'), ''));
    }
    if (_connected && mounted) {
      Future.delayed(const Duration(milliseconds: 50), _poll);
    }
  }

  void _disconnected() {
    if (!mounted) return;
    setState(() {
      _connected = false;
      _status = 'Scanner desconectado';
    });
  }

  Future<void> _disconnect() async {
    _connected = false;
    await _input?.cancel();
    await _bleInput?.cancel();
    await _bleState?.cancel();
    if (_connection != null) await _connection!.finish();
    if (_bleDevice != null) await _bleDevice!.disconnect();
    _connection = null;
    _bleDevice = null;
    _bleInput = null;
    _bleState = null;
    _bleWriteCharacteristic = null;
    if (mounted) {
      setState(() {
        _status = 'Desconectado';
        _vehicleName = 'Nenhum scanner conectado';
      });
    }
  }

  void _addLog(String line) {
    if (!mounted) return;
    setState(() {
      _log.insert(0, line);
      if (_log.length > 4) _log.removeLast();
    });
  }

  @override
  Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 390;
    return Scaffold(
      appBar: AppBar(
        title: const Row(
          children: [
            Icon(Icons.speed_rounded, color: Color(0xFF43E2B2)),
            SizedBox(width: 10),
            Text(
              'GDASH',
              style: TextStyle(letterSpacing: 2.4, fontWeight: FontWeight.w800),
            ),
          ],
        ),
        actions: [
          IconButton(
            tooltip: _connected ? 'Desconectar' : 'Conectar scanner',
            onPressed: _busy ? null : (_connected ? _disconnect : _loadDevices),
            icon: Icon(
              _connected
                  ? Icons.bluetooth_connected
                  : Icons.bluetooth_searching,
              color: _connected ? const Color(0xFF43E2B2) : Colors.white70,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(18, 4, 18, 24),
          children: [
            _connectionCard(),
            const SizedBox(height: 20),
            Row(
              children: [
                const Text(
                  'DADOS DO MOTOR',
                  style: TextStyle(
                    fontSize: 11,
                    letterSpacing: 1.8,
                    color: Colors.white54,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_connected) const _LiveDot(),
                if (_connected) const SizedBox(width: 6),
                Text(
                  _connected ? 'AO VIVO' : 'AGUARDANDO',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 1.2,
                    color: _connected
                        ? const Color(0xFF43E2B2)
                        : Colors.white38,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 12),
            _rpmCard(),
            const SizedBox(height: 12),
            GridView.count(
              crossAxisCount: 2,
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: compact ? 1.25 : 1.38,
              children: [
                _metricCard(
                  'TEMPERATURA',
                  _data.coolant?.toString() ?? '--',
                  '°C',
                  Icons.thermostat,
                  color: _tempColor(),
                ),
                _metricCard(
                  'CONSUMO',
                  _data.consumption?.toStringAsFixed(1) ?? '--',
                  'km/L*',
                  Icons.local_gas_station,
                ),
                _metricCard(
                  'PONTO DE IGNIÇÃO',
                  _data.ignition?.toStringAsFixed(1) ?? '--',
                  '°',
                  Icons.bolt,
                ),
                _metricCard(
                  'COMBUSTÍVEL',
                  _data.fuel?.toString() ?? '--',
                  '%',
                  Icons.oil_barrel_outlined,
                  progress: _data.fuel == null ? null : _data.fuel! / 100,
                ),
                _metricCard(
                  'PRESSÃO TURBO',
                  _data.turboPressureBar?.toStringAsFixed(2) ?? '--',
                  'bar',
                  Icons.speed,
                  color: const Color(0xFFFFB454),
                ),
                _metricCard(
                  'ACELERADOR',
                  _data.accelerator?.toString() ?? '--',
                  '%',
                  Icons.sports_motorsports,
                  progress: _data.accelerator == null
                      ? null
                      : _data.accelerator! / 100,
                ),
              ],
            ),
            const SizedBox(height: 14),
            _speedCard(),
            const SizedBox(height: 18),
            _infoCard(),
          ],
        ),
      ),
    );
  }

  Widget _connectionCard() => Container(
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      gradient: const LinearGradient(
        colors: [Color(0xFF17232B), Color(0xFF121821)],
      ),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(
        color: _connected ? const Color(0x5543E2B2) : const Color(0xFF25303C),
      ),
    ),
    child: Row(
      children: [
        Container(
          width: 44,
          height: 44,
          decoration: BoxDecoration(
            color: const Color(0x2243E2B2),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Icon(
            _connected ? Icons.bluetooth_connected : Icons.bluetooth,
            color: const Color(0xFF43E2B2),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _connected ? _vehicleName : 'Conectar ao veículo',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 3),
              Text(
                _status,
                style: const TextStyle(color: Colors.white54, fontSize: 11),
                maxLines: 2,
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        FilledButton(
          onPressed: _busy ? null : (_connected ? _disconnect : _loadDevices),
          style: FilledButton.styleFrom(
            backgroundColor: const Color(0xFF43E2B2),
            foregroundColor: const Color(0xFF07120F),
            padding: const EdgeInsets.symmetric(horizontal: 14),
          ),
          child: _busy
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_connected ? 'Parar' : 'Conectar'),
        ),
      ],
    ),
  );

  Widget _shiftLights() => AnimatedBuilder(
    animation: _shiftLightController,
    builder: (context, _) {
      final rpm = _data.rpm ?? 0;
      final blinking = rpm >= 6000;
      final lights = <(int, Color)>[
        (1000, Colors.green),
        (2000, Colors.yellow),
        (3000, Colors.yellow),
        (4000, Colors.orange),
        (5000, Colors.red),
      ];
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final (threshold, color) in lights)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 1.5),
              child: Opacity(
                opacity: blinking && _shiftLightController.value < 0.5
                    ? 0.15
                    : 1,
                child: Icon(
                  Icons.circle,
                  size: 12,
                  color: rpm >= threshold ? color : Colors.white12,
                ),
              ),
            ),
        ],
      );
    },
  );

  Widget _rpmCard() => Container(
    padding: const EdgeInsets.fromLTRB(20, 18, 20, 14),
    decoration: BoxDecoration(
      color: const Color(0xFF121821),
      borderRadius: BorderRadius.circular(20),
      border: Border.all(color: const Color(0xFF25303C)),
    ),
    child: Column(
      children: [
        Row(
          children: [
            const Icon(Icons.rotate_right, size: 18, color: Color(0xFF43E2B2)),
            const SizedBox(width: 8),
            const Text(
              'ROTAÇÃO DO MOTOR',
              style: TextStyle(
                fontSize: 11,
                letterSpacing: 1.5,
                color: Colors.white60,
              ),
            ),
            const SizedBox(width: 10),
            _shiftLights(),
            const Spacer(),
            Text('rpm', style: TextStyle(color: Colors.white38, fontSize: 12)),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          _data.rpm?.toString() ?? '---',
          style: const TextStyle(
            fontSize: 58,
            height: 1.1,
            fontWeight: FontWeight.w300,
            letterSpacing: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(20),
          child: LinearProgressIndicator(
            value: math.min((_data.rpm ?? 0) / 7000, 1),
            minHeight: 6,
            backgroundColor: const Color(0xFF28333F),
            color: const Color(0xFF43E2B2),
          ),
        ),
        const SizedBox(height: 7),
        const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text('0', style: TextStyle(color: Colors.white30, fontSize: 10)),
            Text(
              '7.000 rpm',
              style: TextStyle(color: Colors.white30, fontSize: 10),
            ),
          ],
        ),
      ],
    ),
  );

  Widget _metricCard(
    String label,
    String value,
    String unit,
    IconData icon, {
    Color color = const Color(0xFF43E2B2),
    double? progress,
  }) => Container(
    padding: const EdgeInsets.all(15),
    decoration: BoxDecoration(
      color: const Color(0xFF121821),
      borderRadius: BorderRadius.circular(18),
      border: Border.all(color: const Color(0xFF202A35)),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(icon, size: 16, color: color),
            const SizedBox(width: 7),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(
                  fontSize: 9,
                  letterSpacing: 1.1,
                  color: Colors.white54,
                  fontWeight: FontWeight.w700,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
        const Spacer(),
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              value,
              style: const TextStyle(
                fontSize: 32,
                height: 1,
                fontWeight: FontWeight.w400,
              ),
            ),
            const SizedBox(width: 5),
            Padding(
              padding: const EdgeInsets.only(bottom: 3),
              child: Text(
                unit,
                style: const TextStyle(fontSize: 10, color: Colors.white54),
              ),
            ),
          ],
        ),
        if (progress != null) ...[
          const SizedBox(height: 12),
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: LinearProgressIndicator(
              value: progress,
              minHeight: 4,
              backgroundColor: const Color(0xFF28333F),
              color: color,
            ),
          ),
        ],
      ],
    ),
  );

  Widget _speedCard() => Container(
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
    decoration: BoxDecoration(
      color: const Color(0xFF121821),
      borderRadius: BorderRadius.circular(16),
      border: Border.all(color: const Color(0xFF202A35)),
    ),
    child: Row(
      children: [
        const Icon(Icons.speed, size: 19, color: Color(0xFF43E2B2)),
        const SizedBox(width: 10),
        const Text(
          'VELOCIDADE',
          style: TextStyle(
            fontSize: 10,
            letterSpacing: 1.2,
            color: Colors.white60,
          ),
        ),
        const Spacer(),
        Text(
          _data.speed?.toString() ?? '--',
          style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w500),
        ),
        const SizedBox(width: 5),
        const Text(
          'km/h',
          style: TextStyle(color: Colors.white54, fontSize: 11),
        ),
      ],
    ),
  );

  Widget _infoCard() => Container(
    padding: const EdgeInsets.all(13),
    decoration: BoxDecoration(
      color: const Color(0xFF111820),
      borderRadius: BorderRadius.circular(14),
    ),
    child: const Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.info_outline, size: 16, color: Colors.white38),
        SizedBox(width: 9),
        Expanded(
          child: Text(
            'Os dados disponíveis variam conforme o veículo. Pressão turbo é calculada por MAP menos pressão atmosférica. Acelerador usa o PID do pedal, com posição da borboleta como alternativa. Consumo em km/L é estimado (*gasolina). “--” indica PID indisponível.',
            style: TextStyle(color: Colors.white54, fontSize: 10, height: 1.45),
          ),
        ),
      ],
    ),
  );

  Color _tempColor() => (_data.coolant ?? 0) > 105
      ? const Color(0xFFFF755E)
      : const Color(0xFF43E2B2);
}

class _LiveDot extends StatelessWidget {
  const _LiveDot();
  @override
  Widget build(BuildContext context) => Container(
    width: 6,
    height: 6,
    decoration: const BoxDecoration(
      color: Color(0xFF43E2B2),
      shape: BoxShape.circle,
    ),
  );
}
