import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'main.dart';
import 'private_network.dart';
import 'desktop_tor.dart';

class NetworkSettingsPage extends StatefulWidget {
  const NetworkSettingsPage({super.key});
  @override
  State<NetworkSettingsPage> createState() => _NetworkSettingsPageState();
}

class _NetworkSettingsPageState extends State<NetworkSettingsPage> {
  Map<String, dynamic>? status;
  String? message;
  bool busy = false;
  @override
  void initState() {
    super.initState();
    load();
  }

  Future<void> load() async {
    try {
      final s = await PrivateNetwork.status();
      if (mounted) setState(() => status = s);
    } catch (_) {
      if (mounted) {
        setState(() => message = 'Private networking could not be read.');
      }
    }
  }

  Future<void> configure({bool? enabled, bool? background}) async {
    if (Platform.isWindows) {
      await DesktopTor.instance.configure(
        enabled ?? status?['enabled'] == true,
      );
      await load();
      return;
    }
    await privateTransitChannel.invokeMethod('configure', {
      'enabled': enabled ?? status?['enabled'] == true,
      'background': background ?? status?['background'] == true,
    });
    await load();
  }

  Future<void> run(String method) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final r = Platform.isWindows
          ? (method == 'check'
                ? await DesktopTor.instance.check()
                : <String, dynamic>{})
          : await privateTransitChannel.invokeMethod(method);
      await Future<void>.delayed(const Duration(milliseconds: 300));
      await load();
      if (mounted) {
        setState(
          () => message = method == 'check'
              ? 'Tor verified · exit IP ${r['ip']}\nYour device IP was not sent to the destination.'
              : method == 'startActive'
              ? 'Live updates started for up to 90 minutes.'
              : 'Active updates stopped.',
        );
      }
    } on PlatformException catch (e) {
      if (mounted) {
        setState(
          () => message = e.message ?? 'Private connection unavailable.',
        );
      }
    } catch (_) {
      if (mounted) {
        setState(
          () => message = 'Private connection unavailable. Try again later.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Private updates')),
    body: centered(
      ListView(
        padding: const EdgeInsets.all(24),
        children: [
          eyebrow('PRIVATE TRANSIT & MAIL'),
          title('A private way online'),
          const SizedBox(height: 16),
          const Text(
            'Transit and mail API requests use Tor included in the app. No system VPN is required. If Tor cannot connect, those updates wait. Encrypted cloud synchronization uses HTTPS.',
            style: TextStyle(color: muted, height: 1.5),
          ),
          const SizedBox(height: 24),
          if (!Platform.isAndroid && !Platform.isWindows)
            const Text(
              'Private networking is available on Android and Windows.',
            )
          else if (status == null)
            const LinearProgressIndicator()
          else ...[
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Private networking'),
              subtitle: const Text('Embedded Tor · no direct requests'),
              value: status!['enabled'] == true,
              onChanged: busy ? null : (v) => configure(enabled: v),
            ),
            if (Platform.isAndroid)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Background updates'),
                subtitle: const Text(
                  'Plans recalculate locally about every 15 minutes, even offline. Delays download near journeys; timetable daily on unmetered networks. Android may defer work.',
                ),
                value: status!['background'] == true,
                onChanged: busy ? null : (v) => configure(background: v),
              ),
            if (Platform.isWindows)
              const Text(
                'Delays refresh about every 2 minutes while the window is open. Enable tray mode in Windows preferences to continue with the window closed. Timetable checks run daily while the app is running.',
                style: TextStyle(color: muted),
              ),
            const SizedBox(height: 18),
            if ((status!['liveChecked'] as int? ?? 0) > 0)
              Text(
                'Last PID download: ${DateTime.fromMillisecondsSinceEpoch(status!['liveChecked']).toLocal()}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            OutlinedButton.icon(
              onPressed: busy || status!['enabled'] != true
                  ? null
                  : () => run('check'),
              icon: const Icon(Icons.shield_outlined),
              label: const Text('Verify hidden IP'),
            ),
            const SizedBox(height: 20),
            if (Platform.isAndroid)
              panel(
                Icons.sensors,
                'Before a journey',
                'Check the common delay feed every 2 minutes for up to 90 minutes, with a visible Android notification. This keeps the refresh worker awake and uses more battery. Android may still stop work. No GPS tracking; missing and old predictions remain labelled.',
                action: FilledButton(
                  onPressed: busy || status!['enabled'] != true
                      ? null
                      : () => run('startActive'),
                  child: const Text('Keep live updates for 90 minutes'),
                ),
              ),
            if (Platform.isAndroid)
              TextButton(
                onPressed: busy ? null : () => run('stopActive'),
                child: const Text('Stop active updates'),
              ),
            const SizedBox(height: 20),
            const Text(
              'The same persisted 60-second limit, retry pauses and public cache are shared by the app and background tasks. Tor exit nodes can be blocked; the app honours provider limits and does not change circuits to bypass them.',
              style: TextStyle(color: muted, fontSize: 12, height: 1.5),
            ),
            if (status!['error'] is String)
              Padding(
                padding: const EdgeInsets.only(top: 16),
                child: Text(
                  status!['error'],
                  style: const TextStyle(color: muted),
                ),
              ),
          ],
          if (busy)
            const Padding(
              padding: EdgeInsets.only(top: 20),
              child: LinearProgressIndicator(),
            ),
          if (message != null)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Text(message!, style: const TextStyle(height: 1.5)),
            ),
        ],
      ),
    ),
  );
}
