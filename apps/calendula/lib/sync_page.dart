import 'dart:convert';
import 'dart:io';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'calendar.dart';
import 'main.dart';
import 'sync.dart';
import 'setup_transfer.dart';
import 'gmail_desktop_auth.dart';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SyncPage extends StatefulWidget {
  final SyncRepository repository;
  final Future<void> Function()? onSetupApplied;
  const SyncPage({super.key, required this.repository, this.onSetupApplied});
  @override
  State<SyncPage> createState() => _SyncPageState();
}

class _SyncPageState extends State<SyncPage> {
  final endpoint = TextEditingController(),
      user = TextEditingController(),
      password = TextEditingController(),
      pairing = TextEditingController();
  String mode = 'webdav', error = '';
  List<String> local = [];
  bool busy = false, showCode = false;
  @override
  void initState() {
    super.initState();
    final r = widget.repository;
    r.addListener(changed);
    mode = r.mode == 'disabled' ? 'webdav' : r.mode;
    endpoint.text = r.url;
    user.text = r.username;
    password.text = r.password;
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.repository.removeListener(changed);
    for (final c in [endpoint, user, password, pairing]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> run(Future<void> Function() action) async {
    setState(() {
      busy = true;
      error = '';
    });
    try {
      await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is FormatException
              ? e.message
              : 'Could not complete this action. Your local calendar was kept.',
        );
      }
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> configure() async {
    final r = widget.repository;
    final profile = pairing.text.trim().isNotEmpty
        ? SyncProfile.parse(pairing.text.trim())
        : r.profile ?? SyncProfile.create();
    await r.configure(
      pairing: profile,
      transport: mode,
      endpoint: endpoint.text.trim(),
      user: user.text.trim(),
      secret: password.text,
    );
    if (mounted) setState(() => showCode = true);
    await r.synchronize();
  }

  Future<void> export() async {
    final r = widget.repository;
    if (r.profile == null) {
      await r.configure(
        pairing: SyncProfile.create(),
        transport: 'disabled',
        endpoint: '',
      );
    }
    final bytes = utf8.encode(await r.exportPacket());
    if (Platform.isAndroid) {
      await const MethodChannel('app.calendula/import').invokeMethod(
        'saveFile',
        {'name': 'calendar.calsync', 'bytes': Uint8List.fromList(bytes)},
      );
    } else {
      final target = await getSaveLocation(suggestedName: 'calendar.calsync');
      if (target != null) {
        await File(target.path).writeAsBytes(bytes, flush: true);
      }
    }
    if (mounted) setState(() => showCode = true);
  }

  Future<void> import() async {
    final r = widget.repository;
    if (r.profile == null) {
      throw const FormatException(
        'Enter the other device pairing code and save its settings first.',
      );
    }
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Encrypted Calendula file',
          extensions: ['calsync'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > 8 * 1024 * 1024) {
      throw const FormatException('Encrypted file exceeds 8 MB.');
    }
    await r.mergePackets({'manual': await file.readAsString()});
  }

  Future<void> exportSetup() async {
    final r = widget.repository;
    if (r.profile == null) {
      throw const FormatException('Save your cloud connection first.');
    }
    final bytes = utf8.encode(await SetupTransfer(r.profile!).export(r));
    if (Platform.isAndroid) {
      await const MethodChannel('app.calendula/import').invokeMethod(
        'saveFile',
        {'name': 'Calendula.calsetup', 'bytes': Uint8List.fromList(bytes)},
      );
    } else {
      final target = await getSaveLocation(suggestedName: 'Calendula.calsetup');
      if (target != null) {
        await File(target.path).writeAsBytes(bytes, flush: true);
      }
    }
  }

  Future<void> includeGoogleProject() async {
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(label: 'Google Desktop client', extensions: ['json']),
      ],
    );
    if (file == null) return;
    if (await file.length() > 65536) {
      throw const FormatException(
        'Choose the downloaded Google Desktop OAuth JSON below 64 KB.',
      );
    }
    final project = GmailDesktopConfig.fromDownload(await file.readAsString());
    await const FlutterSecureStorage().write(
      key: SetupTransfer.projectKey,
      value: jsonEncode(project.toJson()),
    );
    await widget.onSetupApplied?.call();
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Google project saved. It will be included in the next connection file.',
          ),
        ),
      );
    }
  }

  Future<void> importSetup() async {
    final r = widget.repository;
    final file = await openFile(
      acceptedTypeGroups: [
        const XTypeGroup(
          label: 'Calendula connection',
          extensions: ['calsetup'],
        ),
      ],
    );
    if (file == null) return;
    if (await file.length() > SetupTransfer.maximum) {
      throw const FormatException('Connection file exceeds its size limit.');
    }
    SyncProfile? profile = r.profile;
    if (profile == null) {
      final code = TextEditingController(text: pairing.text.trim());
      if (!mounted) {
        code.dispose();
        return;
      }
      final value = await showDialog<String>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Unlock connection file'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Paste the pairing code from your configured device once. Cloud settings do not need to be entered again.',
              ),
              const SizedBox(height: 16),
              TextField(
                controller: code,
                obscureText: true,
                maxLength: 500,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'Pairing code'),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(ctx, code.text.trim()),
              child: const Text('Unlock'),
            ),
          ],
        ),
      );
      // Dialog animations may still refer to its controller after pop.
      await Future<void>.delayed(const Duration(milliseconds: 250));
      code.dispose();
      if (value == null) return;
      profile = SyncProfile.parse(value);
    }
    final setup = await SetupTransfer(profile).open(await file.readAsString());
    if (!mounted) return;
    final yes = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Connect this device?'),
        content: Text(
          'Cloud: ${Uri.parse(setup.url).host}\nStarting point: ${setup.journey.label}\n\nImports the cloud connection, starting point, calendar and available Google project settings. Existing events are merged. Mail accounts require sign-in on this device.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Connect'),
          ),
        ],
      ),
    );
    if (yes != true) return;
    await setup.apply(r);
    await widget.onSetupApplied?.call();
    if (!mounted) return;
    setState(() {
      mode = r.mode;
      endpoint.text = r.url;
      user.text = r.username;
      password.text = r.password;
      pairing.clear();
    });
    await r.synchronize();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.repository,
        conflicts = r.initialized ? r.document.conflicts : <SyncConflict>[];
    return Scaffold(
      appBar: AppBar(title: const Text('Private device sync')),
      body: centered(
        ListView(
          padding: const EdgeInsets.all(24),
          children: [
            eyebrow('ENCRYPT BEFORE SHARING'),
            title('Your day, on both devices'),
            const SizedBox(height: 12),
            const Text(
              'Calendar operations are encrypted with a separate pairing key. Mail tokens, API keys and GPS history stay on each device. Cloud providers can see account and transfer metadata.',
              style: TextStyle(color: muted, height: 1.5),
            ),
            const SizedBox(height: 20),
            panel(
              Icons.devices,
              'Set up the other device',
              'Save one encrypted connection file to your cloud and open it here. Already paired devices unlock it automatically. A new device needs the pairing code once. This is a setup snapshot; export again after changing connection or home settings.',
              action: Wrap(
                spacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: busy || r.mode != 'webdav'
                        ? null
                        : () => run(exportSetup),
                    child: const Text('Export connection file'),
                  ),
                  FilledButton(
                    onPressed: busy ? null : () => run(importSetup),
                    child: const Text('Import connection file'),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                tilePadding: EdgeInsets.zero,
                title: const Text('Include Google setup for Windows'),
                children: [
                  const Text(
                    'Optional for this personal build: import the Desktop OAuth JSON once on the configured device before exporting its connection file. Windows will then only need account selection and consent.',
                  ),
                  const SizedBox(height: 12),
                  OutlinedButton(
                    onPressed: busy ? null : () => run(includeGoogleProject),
                    child: const Text('Include Desktop OAuth JSON'),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            const SizedBox(height: 20),
            DropdownButtonFormField<String>(
              key: ValueKey('connection:$mode'),
              initialValue: mode,
              decoration: const InputDecoration(labelText: 'Connection'),
              items: [
                const DropdownMenuItem(
                  value: 'webdav',
                  child: Text('HTTPS WebDAV'),
                ),
                const DropdownMenuItem(
                  value: 'lan',
                  child: Text('Direct local network'),
                ),
                if (!Platform.isAndroid)
                  const DropdownMenuItem(
                    value: 'folder',
                    child: Text('Local or cloud-synced folder'),
                  ),
              ],
              onChanged: (v) => setState(() => mode = v!),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: pairing,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Pairing code from the other device (optional)',
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: endpoint,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: mode == 'lan'
                    ? 'Other device local URL'
                    : mode == 'folder'
                    ? 'Folder path'
                    : 'HTTPS folder URL',
                hintText: mode == 'webdav'
                    ? 'https://webdav.yandex.ru/Calendula/'
                    : null,
              ),
            ),
            if (mode == 'webdav') ...[
              const SizedBox(height: 16),
              TextField(
                controller: user,
                decoration: const InputDecoration(labelText: 'WebDAV username'),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: password,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Files / WebDAV app password',
                ),
              ),
            ],
            const SizedBox(height: 16),
            FilledButton(
              onPressed: busy ? null : () => run(configure),
              child: const Text('Save connection & sync'),
            ),
            if (r.profile != null) ...[
              const SizedBox(height: 12),
              OutlinedButton(
                onPressed: () => setState(() => showCode = !showCode),
                child: Text(
                  showCode ? 'Hide pairing code' : 'Show pairing code',
                ),
              ),
              if (showCode)
                Card(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Copy privately to your other device. This code grants access to this calendar; keep it out of chats and screenshots.',
                          style: TextStyle(color: muted, fontSize: 12),
                        ),
                        const SizedBox(height: 12),
                        SelectableText(r.profile!.pairingCode),
                        TextButton(
                          onPressed: () => Clipboard.setData(
                            ClipboardData(text: r.profile!.pairingCode),
                          ),
                          child: const Text('Copy pairing code'),
                        ),
                      ],
                    ),
                  ),
                ),
              OutlinedButton(
                onPressed: busy
                    ? null
                    : () => run(() async {
                        local = await r.listenLocal();
                      }),
                child: const Text('Receive on this local network'),
              ),
              for (final address in local) SelectableText(address),
              if (local.isNotEmpty)
                TextButton(
                  onPressed: () => run(() async {
                    await r.stopListening();
                    local = [];
                  }),
                  child: const Text('Stop local receiver'),
                ),
              const Text(
                'Local receiving works while this app is running. Campus networks may isolate Wi-Fi from wired devices; use cloud sync if the local address cannot be reached.',
                style: TextStyle(fontSize: 12, color: muted),
              ),
              Wrap(
                spacing: 12,
                children: [
                  OutlinedButton(
                    onPressed: busy || r.syncing
                        ? null
                        : () => run(r.synchronize),
                    child: const Text('Sync now'),
                  ),
                  TextButton(
                    onPressed: () => run(
                      () => r.configure(
                        pairing: r.profile!,
                        transport: 'disabled',
                        endpoint: '',
                      ),
                    ),
                    child: const Text('Disconnect sync'),
                  ),
                ],
              ),
            ],
            const SizedBox(height: 20),
            Wrap(
              spacing: 12,
              children: [
                OutlinedButton(
                  onPressed: busy ? null : () => run(export),
                  child: const Text('Export encrypted file'),
                ),
                OutlinedButton(
                  onPressed: busy ? null : () => run(import),
                  child: const Text('Import encrypted file'),
                ),
              ],
            ),
            if (busy || r.syncing)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
            if (error.isNotEmpty || r.syncError != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 14),
                child: Text(
                  error.isNotEmpty ? error : r.syncError!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (r.lastSync != null)
              Text(
                'Last sync: ${dayKey(r.lastSync!)} ${clock(r.lastSync!)}',
                style: const TextStyle(color: muted, fontSize: 12),
              ),
            if (conflicts.isNotEmpty) ...[
              const SizedBox(height: 24),
              title('Choose between simultaneous edits'),
              for (final conflict in conflicts)
                Card(
                  color: Colors.white,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '${conflict.event}\n${conflict.field}',
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                        for (final option in conflict.versions)
                          TextButton(
                            onPressed: () => run(
                              () => r.resolve(
                                conflict,
                                option.fields[conflict.field],
                              ),
                            ),
                            child: Text(
                              conflict.field == '_alive'
                                  ? (option.fields['_alive'] == true
                                        ? 'Keep event'
                                        : 'Delete event')
                                  : 'Use ${option.fields[conflict.field]}',
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
            ],
            const SizedBox(height: 30),
          ],
        ),
      ),
    );
  }
}
