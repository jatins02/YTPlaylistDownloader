import 'dart:async';

import 'package:flutter/material.dart';

import 'application/app_runtime.dart';
import 'application/drafts_controller.dart';
import 'domain/failure.dart';
import 'ui/foundation_app.dart';
import 'ui/theme.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const RuntimeHost());
}

class RuntimeHost extends StatefulWidget {
  const RuntimeHost({super.key, this.openRuntime = AppRuntime.open});
  final Future<AppRuntime> Function() openRuntime;
  @override
  State<RuntimeHost> createState() => _RuntimeHostState();
}

class _RuntimeHostState extends State<RuntimeHost> {
  late Future<AppRuntime> _opening;
  AppRuntime? _runtime;
  bool _openingNow = false;

  @override
  void initState() {
    super.initState();
    _opening = _open();
  }

  Future<AppRuntime> _open() async {
    _openingNow = true;
    try {
      final runtime = await widget.openRuntime();
      if (!mounted) {
        await runtime.close();
        throw const AppFailure(
          FailureCode.storageUnavailable,
          'The app was closed during startup.',
        );
      }
      _runtime = runtime;
      return runtime;
    } finally {
      _openingNow = false;
    }
  }

  @override
  void dispose() {
    final runtime = _runtime;
    if (runtime != null) {
      unawaited(
        runtime.close().catchError((Object _) {
          debugPrint('Private storage did not finish closing.');
        }),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FutureBuilder<AppRuntime>(
    future: _opening,
    builder: (context, snapshot) {
      if (snapshot.hasData) return _LoadedApp(runtime: snapshot.data!);
      final error = snapshot.error;
      return MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'YTPlaylistDownloader',
        theme: appTheme,
        home: Scaffold(
          body: Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child:
                    snapshot.connectionState != ConnectionState.waiting &&
                        snapshot.hasError
                    ? SingleChildScrollView(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const Icon(Icons.lock_outline, size: 36),
                            const SizedBox(height: 16),
                            Text(
                              error is AppFailure
                                  ? error.message
                                  : 'Could not open the app safely.',
                              textAlign: TextAlign.center,
                            ),
                            const SizedBox(height: 20),
                            FilledButton(
                              onPressed: () {
                                if (_openingNow) return;
                                setState(() {
                                  _opening = _open();
                                });
                              },
                              child: const Text('Retry'),
                            ),
                          ],
                        ),
                      )
                    : const CircularProgressIndicator(
                        semanticsLabel: 'Opening private app storage',
                      ),
              ),
            ),
          ),
        ),
      );
    },
  );
}

class _LoadedApp extends StatefulWidget {
  const _LoadedApp({required this.runtime});
  final AppRuntime runtime;
  @override
  State<_LoadedApp> createState() => _LoadedAppState();
}

class _LoadedAppState extends State<_LoadedApp> {
  late final DraftsController controller;
  @override
  void initState() {
    super.initState();
    controller = DraftsController(
      jobs: widget.runtime.jobs,
      workspace: widget.runtime.workspace,
      vault: widget.runtime.vault,
    );
    unawaited(controller.load());
  }

  @override
  void dispose() {
    controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => FoundationApp(
    controller: controller,
    recoveredAttempts: widget.runtime.recoveredAttempts,
    media: widget.runtime.media,
  );
}
