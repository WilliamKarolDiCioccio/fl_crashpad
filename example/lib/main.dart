// fl_crashpad's example, and the package's end-to-end check: the only place
// the handler is found where a real build puts it, inside a real bundle.
//
// Run it, press a crash button, start it again: the crash is in the list,
// and opening it shows what the report holds.
//
// Headless, for CI:
//
//   <bundle>/fl_crashpad_example --database=/tmp/db --crash=segfault
//
// starts Crashpad on that database and crashes before any window opens; the
// report is then in /tmp/db. On Android the same arguments arrive through the
// launching intent (tool/android_e2e.dart):
//
//   adb shell am start -n dev.wilielmus.fl_crashpad_example/.MainActivity \
//     --esa dart_entrypoint_args --crash=segfault
//
// Every option, each also usable alone:
//   --database=<dir>   where reports go (default: under app support)
//   --crash=<kind>     a CrashpadTestCrash name, or `dump` for a report of a
//                      process that carries on
//   --upload=<url>     send reports there, with the user's consent given
//   --report-json      print the reports, once sanitised (and on mobile sent),
//                      as one `fl_crashpad_reports: <json>` line, and exit
import 'dart:convert';
import 'dart:io';

import 'package:fl_crashpad/fl_crashpad.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'report_page.dart';

Future<void> main(List<String> args) async {
  String? option(String name) => args
      .where((a) => a.startsWith('--$name='))
      .map((a) => a.substring(name.length + 3))
      .firstOrNull;

  final crash = option('crash');
  final upload = option('upload');
  final reportJson = args.contains('--report-json');
  final Directory database;
  if (option('database') case final path?) {
    database = Directory(path);
  } else {
    WidgetsFlutterBinding.ensureInitialized();
    database = Directory(
      '${(await getApplicationSupportDirectory()).path}/crashpad',
    );
  }

  // As early as possible: nothing that crashes before this line is caught.
  Object? startError;
  try {
    Crashpad.start(
      CrashpadOptions(
        databaseDirectory: database,
        annotations: {'example.build': 'fl_crashpad example'},
        upload: upload == null
            ? null
            : CrashpadUpload(url: Uri.parse(upload), rateLimit: false),
        uploadsEnabled: upload == null ? null : true,
      ),
    );
    Crashpad.annotations['example.screen'] = 'home';
    if (crash != null) {
      // Something the sanitiser has to take out, for the headless check to
      // look for in the raw dump and not find in the sanitised one.
      Crashpad.annotations['example.contact'] = 'ada@example.com';
    }
  } on CrashpadException catch (e) {
    startError = e;
  }

  if ((crash != null || reportJson) && startError != null) {
    stderr.writeln(startError);
    // print, too: on Android it is the one that reaches logcat.
    // ignore: avoid_print
    print('fl_crashpad_error: $startError');
    exit(2);
  }
  if (crash == 'dump') {
    Crashpad.dumpWithoutCrash();
  } else if (crash != null) {
    Crashpad.crashForTesting(CrashpadTestCrash.values.byName(crash));
  }
  if (reportJson) {
    await Crashpad.sanitizationIdle;
    final reports = await CrashReportDatabase(database).reports();
    // ignore: avoid_print — a headless run's output, read from logcat.
    print(
      'fl_crashpad_reports: ${jsonEncode([
        for (final r in reports) {'id': r.id, 'state': r.state.name, 'sanitized': r.sanitized, 'uploaded': r.uploaded, 'remoteId': r.remoteId, 'minidump': r.minidump.path},
      ])}',
    );
    exit(0);
  }
  if (crash == 'dump') exit(0);

  runApp(ExampleApp(database: database, startError: startError));
}

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key, required this.database, this.startError});

  final Directory database;
  final Object? startError;

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'fl_crashpad',
    theme: ThemeData(colorSchemeSeed: Colors.deepOrange),
    darkTheme: ThemeData(
      colorSchemeSeed: Colors.deepOrange,
      brightness: Brightness.dark,
    ),
    home: HomePage(database: database, startError: startError),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, required this.database, this.startError});

  final Directory database;
  final Object? startError;

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  late final CrashReportDatabase _reports = CrashReportDatabase(
    widget.database,
  );
  final _annotation = TextEditingController();
  List<CrashReport> _list = const [];
  bool _uploads = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _annotation.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final list = await _reports.reports();
    if (!mounted) return;
    setState(() {
      _list = list;
      _uploads = _reports.uploadsEnabled;
    });
  }

  void _say(String message) => ScaffoldMessenger.of(
    context,
  ).showSnackBar(SnackBar(content: Text(message)));

  @override
  Widget build(BuildContext context) {
    final started = Crashpad.isStarted;
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('fl_crashpad')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            leading: Icon(
              started ? Icons.shield : Icons.error_outline,
              color: started ? Colors.green : theme.colorScheme.error,
            ),
            title: Text(started ? 'Crashpad is running' : 'Not started'),
            subtitle: Text(
              widget.startError?.toString() ??
                  'Crashpad ${Crashpad.crashpadRevision.substring(0, 12)} · '
                      '${_reports.sanitizer.sanitizeText(widget.database.path)}',
            ),
          ),
          const Divider(),
          Text('Runtime annotation', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _annotation,
                  decoration: const InputDecoration(
                    labelText: 'example.note',
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              FilledButton(
                onPressed: () {
                  try {
                    Crashpad.annotations['example.note'] = _annotation.text;
                    _say('The next report carries example.note.');
                  } on ArgumentError catch (e) {
                    _say('${e.message}');
                  }
                },
                child: const Text('Set'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Text('Crash on purpose', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in CrashpadTestCrash.values)
                OutlinedButton(
                  onPressed: started
                      ? () => Crashpad.crashForTesting(kind)
                      : null,
                  child: Text(kind.name),
                ),
              OutlinedButton(
                onPressed: started
                    ? () {
                        Crashpad.dumpWithoutCrash();
                        _say('Report written; the app carries on.');
                        Future<void>.delayed(
                          const Duration(seconds: 1),
                          _refresh,
                        );
                      }
                    : null,
                child: const Text('dump without crash'),
              ),
            ],
          ),
          const SizedBox(height: 24),
          SwitchListTile(
            title: const Text('Uploads enabled'),
            subtitle: const Text(
              'Consent, kept in the database. Nothing is sent without an '
              'upload URL either, and this example has none.',
            ),
            value: _uploads,
            onChanged: (value) {
              _reports.uploadsEnabled = value;
              _refresh();
            },
          ),
          const Divider(),
          Row(
            children: [
              Text(
                'Reports (${_list.length})',
                style: theme.textTheme.titleMedium,
              ),
              const Spacer(),
              IconButton(
                tooltip: 'Refresh',
                onPressed: _refresh,
                icon: const Icon(Icons.refresh),
              ),
            ],
          ),
          for (final report in _list)
            ListTile(
              dense: true,
              leading: const Icon(Icons.description_outlined),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        ReportPage(report: report, database: _reports),
                  ),
                );
                _refresh();
              },
              title: Text(report.id),
              subtitle: Text(
                '${report.sanitized ? 'sanitised' : 'raw'} · '
                '${report.state.name} · ${report.createdAt.toLocal()} · '
                '${report.minidump.existsSync() ? report.minidump.lengthSync() : 0} bytes',
              ),
              trailing: IconButton(
                tooltip: 'Delete',
                icon: const Icon(Icons.delete_outline),
                onPressed: () {
                  _reports.delete(report.id);
                  _refresh();
                },
              ),
            ),
        ],
      ),
    );
  }
}
