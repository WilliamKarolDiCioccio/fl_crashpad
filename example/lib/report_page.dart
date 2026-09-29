// One report, opened: what happened and where, the annotations it carries,
// the machine it came from, its attachments and its modules — what somebody
// asked "send this crash report?" deserves to be able to see first.
import 'dart:io';
import 'dart:isolate';

import 'package:fl_crashpad/fl_crashpad.dart';
import 'package:flutter/material.dart';

import 'minidump.dart';

class ReportPage extends StatefulWidget {
  const ReportPage({super.key, required this.report, required this.database});

  final CrashReport report;
  final CrashReportDatabase database;

  @override
  State<ReportPage> createState() => _ReportPageState();
}

class _ReportPageState extends State<ReportPage> {
  late final Future<Minidump> _dump = _read(widget.report.minidump.path);

  // Off the UI isolate: a dump of a big process runs to megabytes.
  static Future<Minidump> _read(String path) =>
      Isolate.run(() => Minidump.parse(File(path).readAsBytesSync()));

  List<File> get _attachments {
    // Crashpad keeps a report's attachments beside the database's reports,
    // in attachments/<report id>/.
    final directory = Directory(
      '${widget.database.directory.path}/attachments/${widget.report.id}',
    );
    if (!directory.existsSync()) return const [];
    return directory.listSync().whereType<File>().toList();
  }

  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final report = widget.report;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Report'),
        actions: [
          if (report.state == CrashReportState.pending)
            IconButton(
              tooltip: 'Request upload',
              icon: const Icon(Icons.cloud_upload_outlined),
              onPressed: () async {
                try {
                  await widget.database.requestUpload(report.id);
                  _say('Upload requested; it needs an upload URL to go.');
                } on CrashpadException catch (e) {
                  _say(e.message);
                }
              },
            ),
          IconButton(
            tooltip: 'Delete',
            icon: const Icon(Icons.delete_outline),
            onPressed: () {
              widget.database.delete(report.id);
              Navigator.of(context).pop(true);
            },
          ),
        ],
      ),
      body: FutureBuilder<Minidump>(
        future: _dump,
        builder: (context, snapshot) => ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (snapshot.data case final dump?)
              _Summary(dump: dump)
            else if (snapshot.hasError)
              _Section(
                title: 'Could not read the minidump',
                children: [Text('${snapshot.error}')],
              )
            else
              const Center(child: CircularProgressIndicator()),
            _Section(
              title: 'Report',
              children: [
                _Row('Id', report.id),
                _Row('State', report.state.name),
                _Row(
                  'Sanitised',
                  report.sanitized
                      ? 'yes — home, account name, secrets, emails and '
                            'private paths are masked'
                      : 'no',
                ),
                _Row('Written', '${report.createdAt.toLocal()}'),
                _Row(
                  'Uploaded',
                  report.uploaded ? 'yes, as ${report.remoteId}' : 'no',
                ),
                _Row('Upload attempts', '${report.uploadAttempts}'),
                _Row(
                  'Size',
                  report.minidump.existsSync()
                      ? _bytes(report.minidump.lengthSync())
                      : 'missing',
                ),
                // Where the file sits is this machine's business: shown through
                // the same sanitiser, and never part of the upload, which
                // names the file by the report's id alone.
                _Row(
                  'Stored at',
                  widget.database.sanitizer.sanitizeText(report.minidump.path),
                ),
                _Row('Sent as', '${report.id}.dmp'),
              ],
            ),
            if (snapshot.data case final dump?) ..._details(dump),
            _Section(
              title: 'Attachments',
              children: [
                for (final file in _attachments)
                  _Row(file.uri.pathSegments.last, _bytes(file.lengthSync())),
                if (_attachments.isEmpty) const Text('None.'),
              ],
            ),
          ],
        ),
      ),
    );
  }

  List<Widget> _details(Minidump dump) {
    final crashpad = dump.crashpad;
    final system = dump.system;
    final crashed = switch (dump.exception?.instructionPointer) {
      final pc? => dump.moduleAt(pc),
      null => null,
    };
    return [
      _Section(
        title: 'Process annotations',
        subtitle: 'CrashpadOptions.annotations, fixed at start',
        children: _annotations(crashpad?.processAnnotations ?? const {}),
      ),
      _Section(
        title: 'Runtime annotations',
        subtitle: 'Crashpad.annotations, read from memory at the crash',
        children: [
          for (final MapEntry(key: index, value: annotations)
              in crashpad?.moduleAnnotations.entries ??
                  const <MapEntry<int, ModuleAnnotations>>[])
            if (!annotations.isEmpty) ...[
              Text(
                index < dump.modules.length
                    ? dump.modules[index].name
                    : 'module $index',
                style: Theme.of(context).textTheme.labelLarge,
              ),
              ..._annotations({...annotations.simple, ...annotations.objects}),
            ],
          if (crashpad?.moduleAnnotations.values.every((a) => a.isEmpty) ??
              true)
            const Text('None.'),
        ],
      ),
      if (system != null)
        _Section(
          title: 'System',
          children: [
            _Row(
              'OS',
              '${system.os} ${system.major}.${system.minor}.'
                  '${system.build}',
            ),
            _Row('Version', system.version),
            _Row('CPU', '${system.cpu}, ${system.processors} cores'),
            _Row('Threads', '${dump.threadCount}'),
            if (crashpad != null) _Row('Client id', crashpad.clientId),
          ],
        ),
      _Section(
        title: 'Modules (${dump.modules.length})',
        children: [
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: Text(
              crashed == null
                  ? 'Every library loaded at the time'
                  : 'Crashed in ${crashed.name}',
            ),
            children: [
              for (final module in dump.modules)
                ListTile(
                  dense: true,
                  selected: identical(module, crashed),
                  title: Text(module.name),
                  subtitle: Text(
                    '${_hex(module.base)}–${_hex(module.base + module.size)}'
                    ' · ${module.path}',
                  ),
                ),
            ],
          ),
        ],
      ),
    ];
  }

  static List<Widget> _annotations(Map<String, String> entries) => [
    for (final MapEntry(:key, :value) in entries.entries) _Row(key, value),
    if (entries.isEmpty) const Text('None.'),
  ];
}

/// The headline: what ended the process, and where it was executing.
class _Summary extends StatelessWidget {
  const _Summary({required this.dump});

  final Minidump dump;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final exception = dump.exception;
    if (exception == null) {
      return const _Section(
        title: 'No exception recorded',
        children: [Text('This dump has no exception stream.')],
      );
    }
    final pc = exception.instructionPointer;
    final module = pc == null ? null : dump.moduleAt(pc);
    final where = switch ((pc, module)) {
      (final pc?, final module?) =>
        '${module.name} + ${_hex(pc - module.base)}',
      (final pc?, null) => _hex(pc),
      _ => 'an unknown address',
    };
    return Card(
      color: theme.colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              exception.describe(dump.system?.platform),
              style: theme.textTheme.headlineSmall?.copyWith(
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
            const SizedBox(height: 4),
            SelectableText(
              'in $where, on thread ${exception.threadId}\n'
              'address ${_hex(exception.address)}'
              '${dump.system?.platform == MinidumpSystem.linux ? ' · si_code ${exception.signedFlags}' : ''}',
              style: theme.textTheme.bodyMedium?.copyWith(
                fontFamily: 'monospace',
                color: theme.colorScheme.onErrorContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  const _Section({required this.title, this.subtitle, required this.children});

  final String title;
  final String? subtitle;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: theme.textTheme.titleMedium),
          if (subtitle != null)
            Text(subtitle!, style: theme.textTheme.bodySmall),
          const SizedBox(height: 8),
          ...children,
        ],
      ),
    );
  }
}

class _Row extends StatelessWidget {
  const _Row(this.label, this.value);

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 2),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 160,
          child: Text(label, style: Theme.of(context).textTheme.bodySmall),
        ),
        Expanded(child: SelectableText(value)),
      ],
    ),
  );
}

String _hex(int value) => '0x${value.toRadixString(16)}';

String _bytes(int bytes) => bytes < 1024 * 1024
    ? '${(bytes / 1024).toStringAsFixed(1)} KB'
    : '${(bytes / 1024 / 1024).toStringAsFixed(1)} MB';
