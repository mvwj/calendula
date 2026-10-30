import 'package:flutter/material.dart';

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:url_launcher/url_launcher.dart';

import 'calendar.dart';
import 'mail.dart';
import 'mail_message_page.dart';
import 'main.dart';
import 'schedule_import.dart';
import 'import_review_page.dart';
import 'imap_mail.dart';
import 'gmail_desktop_auth.dart';

import 'package:file_selector/file_selector.dart';

class MailPage extends StatefulWidget {
  final MailController controller;
  final List<CalendarEvent> Function() events;
  final Future<bool> Function(List<CalendarEvent>) commit;
  const MailPage({
    super.key,
    required this.controller,
    required this.events,
    required this.commit,
  });
  @override
  State<MailPage> createState() => _MailPageState();
}

class _MailPageState extends State<MailPage> {
  final clientId = TextEditingController();
  final googleId = TextEditingController(),
      googleSecret = TextEditingController();
  final imapUser = TextEditingController(),
      imapPassword = TextEditingController(),
      imapHost = TextEditingController(text: 'imap.gmail.com');
  bool connecting = false, cancelled = false;
  DeviceSignIn? signIn;
  String? error;
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(changed);
    clientId.text = widget.controller.outlook?.clientId ?? '';
    googleId.text = widget.controller.gmailConfig?.clientId ?? '';
    googleSecret.text = widget.controller.gmailConfig?.clientSecret ?? '';
  }

  void changed() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    cancelled = true;
    widget.controller.removeListener(changed);
    clientId.dispose();
    googleId.dispose();
    googleSecret.dispose();
    imapUser.dispose();
    imapPassword.dispose();
    imapHost.dispose();
    super.dispose();
  }

  Future<void> connect(bool google, {GmailAccount? reconnect}) async {
    setState(() {
      connecting = true;
      error = null;
      cancelled = false;
    });
    try {
      if (google) {
        await widget.controller.connectGmail(
          desktopClientId: googleId.text.trim(),
          desktopSecret: googleSecret.text.trim(),
          reconnect: reconnect,
        );
      } else {
        final auth = OutlookAuth(widget.controller.client),
            id = clientId.text.trim();
        final code = await auth.begin(id);
        if (!mounted) return;
        setState(() => signIn = code);
        final session = await auth.complete(
          id,
          code,
          cancelled: () => cancelled || !mounted,
        );
        if (!cancelled) await widget.controller.saveOutlook(session);
      }
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is MailFailure
              ? e.message
              : e is PlatformException
              ? e.message
              : 'Connection could not be completed.',
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          connecting = false;
          signIn = null;
        });
      }
    }
  }

  Future<void> importGoogleClient() async {
    try {
      final file = await openFile(
        acceptedTypeGroups: [
          const XTypeGroup(
            label: 'Google Desktop OAuth client',
            extensions: ['json'],
          ),
        ],
      );
      if (file == null || !mounted) return;
      if (await file.length() > 65536) {
        throw const MailFailure(
          'OAuth client JSON must be smaller than 64 KB.',
        );
      }
      final config = GmailDesktopConfig.fromDownload(await file.readAsString());
      await widget.controller.configureGmail(config);
      if (!mounted) return;
      setState(() {
        googleId.text = config.clientId;
        googleSecret.text = config.clientSecret;
        error = null;
      });
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is MailFailure ? e.message : 'The Desktop OAuth file could not be imported. Your connections were kept.',
        );
      }
    }
  }

  Widget googlePanel(MailController c) => panel(
    Icons.mail_outline,
    'Sign in with Google',
    'Choose a Gmail account and allow read-only access. No app password. Register Calendula once in one Google project, then add your other accounts here. Up to eight accounts; credentials stay on this device.',
    action: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final account in c.gmailAccounts)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  account.label,
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                Wrap(
                  spacing: 8,
                  children: [
                    TextButton(
                      onPressed: connecting || c.busy
                          ? null
                          : () => connect(true, reconnect: account),
                      child: const Text('Reconnect'),
                    ),
                    TextButton(
                      onPressed: connecting || c.busy
                          ? null
                          : () => c.disconnectGmail(account.id),
                      child: const Text('Disconnect'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        if (Platform.isWindows)
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              tilePadding: EdgeInsets.zero,
              title: const Text('Google project settings · once per PC'),
              subtitle: Text(
                c.gmailConfig == null
                    ? 'Import the Desktop app OAuth JSON first'
                    : 'Desktop client saved securely',
              ),
              initiallyExpanded: c.gmailConfig == null,
              children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    onPressed: connecting || c.busy ? null : importGoogleClient,
                    icon: const Icon(Icons.file_open_outlined),
                    label: const Text('Import Desktop OAuth JSON'),
                  ),
                ),
                TextField(
                  controller: googleId,
                  enabled: !connecting && !c.busy,
                  decoration: const InputDecoration(
                    labelText: 'Desktop OAuth client ID',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: googleSecret,
                  enabled: !connecting && !c.busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Issued Desktop client secret',
                  ),
                ),
                const SizedBox(height: 12),
              ],
            ),
          ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: connecting || c.busy ? null : () => connect(true),
              icon: const Icon(Icons.person_add_alt_1_outlined),
              label: const Text('Add Google account'),
            ),
            TextButton(
              onPressed: () => launchUrl(
                Uri.parse('https://console.cloud.google.com/auth/clients'),
                mode: LaunchMode.externalApplication,
              ),
              child: const Text('Google project setup'),
            ),
          ],
        ),
        if (!Platform.isWindows)
          const Padding(
            padding: EdgeInsets.only(top: 12),
            child: Text(
              'Android setup: app.calendula.calendula · register this APK signing SHA-1. Add your Gmail addresses as Test users while the project is in Testing.',
              style: TextStyle(color: muted),
            ),
          ),
      ],
    ),
  );

  Future<void> connectImap() async {
    setState(() {
      connecting = true;
      error = null;
    });
    try {
      await widget.controller.connectImap(
        ImapAccount(
          imapHost.text.trim().toLowerCase(),
          imapUser.text.trim(),
          imapHost.text.trim().toLowerCase() == 'imap.gmail.com'
              ? imapPassword.text.replaceAll(' ', '')
              : imapPassword.text,
        ),
      );
      imapPassword.clear();
    } catch (e) {
      if (mounted) {
        setState(
          () => error = e is MailFailure ? e.message : 'Private IMAP connection failed. Check the server and try later.',
        );
      }
    } finally {
      if (mounted) setState(() => connecting = false);
    }
  }

  Future<void> review(MailMessage message) async {
    final now = localNow(),
        through = DateTime(
          localNow().year,
          localNow().month,
          localNow().day + 90,
        );
    final events = <CalendarEvent>[], warnings = <String>[];
    for (final attachment in message.calendarAttachments) {
      try {
        final batch = parseIcs(attachment, from: now, through: through);
        events.addAll(batch.events);
        warnings.addAll(batch.warnings);
      } on FormatException catch (e) {
        warnings.add(e.message);
      }
    }
    if (events.isEmpty) {
      final batch = recognizeText(
        '${message.subject}\n${message.text}',
        source: '${message.provider.name}:${message.accountId}:${message.id}',
      );
      events.addAll(batch.events);
      warnings.addAll(batch.warnings);
    }
    if (!mounted) return;
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ImportReviewPage(
          existing: widget.events(),
          commit: widget.commit,
          heading: 'Review mail invitation',
          initial: ImportBatch(
            events,
            warnings: warnings,
            sourceText: '${message.subject}\n${message.text}',
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = widget.controller;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Mail invitations'),
        actions: [
          IconButton(
            onPressed: c.busy ? null : () => c.refresh(),
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh mail',
          ),
        ],
      ),
      body: centered(
        ListView(
          padding: const EdgeInsets.all(24),
          children: [
            eyebrow('READ ONLY · ON OPEN OR ON REQUEST'),
            title('Invitations, quietly'),
            const SizedBox(height: 12),
            const Text(
              'The mail provider knows your account. Message contents are parsed here; no external AI, images, sending, deletion or read-status changes.',
              style: TextStyle(color: muted, height: 1.5),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Check mail when Calendula opens'),
              value: c.refreshOnOpen,
              onChanged: (v) async {
                c.refreshOnOpen = v;
                await c.preferences();
                changed();
              },
            ),
            panel(
              Icons.share_outlined,
              'Share an invitation',
              'In your mail app, share selected text or an attachment with Calendula, or open an ICS, PDF or XLSX file with Calendula. Review it before adding. This works without signing in here; shared mail is not checked automatically.',
            ),
            const SizedBox(height: 16),
            googlePanel(c),
            const SizedBox(height: 16),
            panel(
              Icons.lock_outline,
              'Read with IMAP',
              'Gmail: use a Google app password with 2-Step Verification. No Google Cloud project. Other mail: use the IMAP server and credentials allowed by your provider. TLS on port 993, through app-only Tor.',
              action: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (final account in c.imapAccounts)
                    ListTile(
                      contentPadding: EdgeInsets.zero,
                      title: Text(account.username),
                      subtitle: Text(
                        '${account.host} · last 10 inbox messages',
                      ),
                      trailing: IconButton(
                        tooltip: 'Disconnect IMAP',
                        onPressed: c.busy || connecting
                            ? null
                            : () => c.disconnectImap(account.id),
                        icon: const Icon(Icons.link_off),
                      ),
                    ),
                  TextField(
                    controller: imapUser,
                    autocorrect: false,
                    enableSuggestions: false,
                    keyboardType: TextInputType.emailAddress,
                    decoration: const InputDecoration(
                      labelText: 'Email / IMAP username',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: imapHost,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'IMAP server',
                      helperText: 'Gmail: imap.gmail.com · TLS port 993',
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: imapPassword,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'App password / permitted IMAP password',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'CUNI Microsoft 365: an @cuni.cz sign-in usually belongs to Exchange Online, which requires OAuth. If your faculty has a separate mail server, enter the server listed in its official instructions. Otherwise use Share or Microsoft sign-in below.',
                    style: TextStyle(color: muted, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: connecting || c.busy ? null : connectImap,
                        child: const Text('Connect IMAP'),
                      ),
                      TextButton(
                        onPressed: () => launchUrl(
                          Uri.parse(
                            'https://myaccount.google.com/apppasswords',
                          ),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: const Text('Google app password'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            panel(
              Icons.mark_email_unread_outlined,
              'Microsoft 365 / Outlook · OAuth',
              c.outlook != null ? 'Connected · inbox only' : 'Register a personal native app in Microsoft Entra. Allow public client flows, choose personal and organizational accounts, and add delegated Mail.Read. No secret or paid API needed.',
              action: Column(
                children: [
                  if (c.outlook == null) ...[
                    TextField(
                      controller: clientId,
                      decoration: const InputDecoration(
                        labelText: 'Application (client) ID',
                      ),
                    ),
                    const SizedBox(height: 12),
                  ],
                  Wrap(
                    spacing: 8,
                    children: [
                      FilledButton(
                        onPressed: connecting
                            ? null
                            : c.outlook != null
                            ? () => c.disconnect(MailProvider.outlook)
                            : () => connect(false),
                        child: Text(
                          c.outlook != null ? 'Disconnect' : 'Connect Outlook',
                        ),
                      ),
                      TextButton(
                        onPressed: () => launchUrl(
                          Uri.parse(
                            'https://entra.microsoft.com/#view/Microsoft_AAD_RegisteredApps/ApplicationsListBlade',
                          ),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: const Text('Microsoft setup'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            if (signIn != null)
              Card(
                color: Colors.white,
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Enter this code on the Microsoft sign-in page',
                      ),
                      SelectableText(
                        signIn!.userCode,
                        style: const TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      OutlinedButton(
                        onPressed: () => launchUrl(
                          Uri.parse(signIn!.url),
                          mode: LaunchMode.externalApplication,
                        ),
                        child: const Text('Open Microsoft sign-in'),
                      ),
                      TextButton(
                        onPressed: () => setState(() => cancelled = true),
                        child: const Text('Cancel sign-in'),
                      ),
                    ],
                  ),
                ),
              ),
            if (connecting || c.busy)
              const Padding(
                padding: EdgeInsets.all(16),
                child: LinearProgressIndicator(),
              ),
            if (error != null || c.error != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 16),
                child: Text(
                  error ?? c.error!,
                  style: const TextStyle(color: Colors.red),
                ),
              ),
            if (c.notice != null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 12),
                child: Text(c.notice!, style: const TextStyle(color: muted)),
              ),
            const SizedBox(height: 20),
            for (final m in c.messages)
              Card(
                color: Colors.white,
                child: ListTile(
                  leading: const Icon(Icons.inbox_outlined, color: forest),
                  title: Text(m.subject.isEmpty ? '(No subject)' : m.subject),
                  subtitle: Text(
                    '${m.sender}\n${m.provider.name}${m.provider == MailProvider.gmail && m.accountId.startsWith('gmail:') ? ' · ${m.accountId.substring(6)}' : ''} · ${dayKey(m.received)}${m.calendarAttachments.isEmpty ? '' : ' · ICS invitation'}',
                  ),
                  isThreeLine: true,
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) =>
                          MailMessagePage(message: m, review: () => review(m)),
                    ),
                  ),
                ),
              ),
            if (!c.busy && c.messages.isEmpty)
              const Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'Connect an account to review recent invitations. Mail stays in memory until this app closes.',
                  style: TextStyle(color: muted),
                ),
              ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }
}
