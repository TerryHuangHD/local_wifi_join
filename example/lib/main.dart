import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:local_wifi_join/local_wifi_join.dart';

/// Must match `NSBonjourServices` in `ios/Runner/Info.plist`.
const _bonjourServiceType = '_lwj-probe._tcp';

void main() => runApp(const ExampleApp());

/// Demonstrates the full join → verify → leave flow.
class ExampleApp extends StatelessWidget {
  /// Creates the example app.
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      title: 'local_wifi_join example',
      home: JoinPage(),
    );
  }
}

/// Form for joining an access point and probing a TCP peer behind it.
class JoinPage extends StatefulWidget {
  /// Creates the page.
  const JoinPage({super.key});

  @override
  State<JoinPage> createState() => _JoinPageState();
}

class _JoinPageState extends State<JoinPage> {
  final _ssid = TextEditingController();
  final _passphrase = TextEditingController();
  final _host = TextEditingController(text: '192.168.1.1');
  final _port = TextEditingController(text: '80');
  final _log = <String>[];
  bool _busy = false;

  /// SSID of the last [LocalWifiJoin.join] attempt, pending or joined, until
  /// [LocalWifiJoin.leave]. Editing the form must not change what is left.
  String? _activeSsid;

  @override
  void dispose() {
    final ssid = _activeSsid;
    if (ssid != null) unawaited(LocalWifiJoin.leave(ssid));
    _ssid.dispose();
    _passphrase.dispose();
    _host.dispose();
    _port.dispose();
    super.dispose();
  }

  void _append(String line) {
    // Also on the console, so `flutter run` / device logs keep a record.
    debugPrint('[local_wifi_join_example] $line');
    if (!mounted) return;
    final time = TimeOfDay.now().format(context);
    setState(() => _log.insert(0, '$time  $line'));
  }

  /// Runs [action], disabling the other actions meanwhile if [exclusive].
  Future<void> _run(
    Future<void> Function() action, {
    bool exclusive = true,
  }) async {
    if (exclusive) setState(() => _busy = true);
    try {
      await action();
    } catch (e) {
      _append('error: $e');
    } finally {
      if (exclusive && mounted) setState(() => _busy = false);
    }
  }

  Future<void> _checkWifi() async {
    _append('isWifiEnabled: ${await LocalWifiJoin.isWifiEnabled()}');
  }

  Future<void> _requestPermission() async {
    final permission = await LocalWifiJoin.requestLocalNetworkPermission(
      bonjourServiceType: _bonjourServiceType,
    );
    _append('local network permission: ${permission.name}');
  }

  Future<void> _join() async {
    final ssid = _ssid.text;
    _activeSsid = ssid;
    _append('joining $ssid…');
    final result = await LocalWifiJoin.join(
      ssid: ssid,
      passphrase: _passphrase.text,
    );
    _append('join: $result');
  }

  /// Also cancels a pending join. Without a join it leaves the SSID in the
  /// form, which is a no-op.
  Future<void> _leave() async {
    final ssid = _activeSsid ?? _ssid.text;
    _activeSsid = null;
    await LocalWifiJoin.leave(ssid);
    _append('left $ssid');
  }

  /// `joined` is not proof of connectivity on iOS; a TCP connection is.
  Future<void> _probe() async {
    final host = _host.text;
    final port = int.tryParse(_port.text);
    if (port == null) {
      _append('invalid port');
      return;
    }
    final deadline = DateTime.now().add(const Duration(seconds: 30));
    var attempts = 0;
    while (DateTime.now().isBefore(deadline)) {
      attempts++;
      try {
        final socket = await Socket.connect(
          host,
          port,
          timeout: const Duration(seconds: 2),
        );
        socket.destroy();
        _append('TCP $host:$port reachable after $attempts attempt(s)');
        return;
      } on SocketException {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      }
    }
    _append('TCP $host:$port unreachable after $attempts attempts');
  }

  @override
  Widget build(BuildContext context) {
    // Leave stays available during a pending join, to cancel it.
    final buttons = <(String, Future<void> Function(), bool)>[
      ('Wi-Fi enabled?', _checkWifi, true),
      ('Local network permission', _requestPermission, true),
      ('Join', _join, true),
      ('Probe TCP', _probe, true),
      ('Leave', _leave, false),
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('local_wifi_join')),
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                children: [
                  TextField(
                    controller: _ssid,
                    decoration: const InputDecoration(labelText: 'SSID'),
                  ),
                  TextField(
                    controller: _passphrase,
                    decoration: const InputDecoration(
                      labelText: 'WPA2 passphrase',
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(
                        flex: 3,
                        child: TextField(
                          controller: _host,
                          decoration: const InputDecoration(
                            labelText: 'Probe host',
                          ),
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: TextField(
                          controller: _port,
                          keyboardType: TextInputType.number,
                          decoration: const InputDecoration(labelText: 'Port'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      for (final (label, action, exclusive) in buttons)
                        FilledButton.tonal(
                          onPressed: _busy && exclusive
                              ? null
                              : () => _run(action, exclusive: exclusive),
                          child: Text(label),
                        ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: ListView.builder(
                padding: const EdgeInsets.all(16),
                itemCount: _log.length,
                itemBuilder: (context, i) => Text(
                  _log[i],
                  style: const TextStyle(fontFamily: 'monospace'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
