import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import '../domain/failure.dart';

/// All children are supervised in a private Linux process group. Raw stderr is
/// bounded and discarded, so URLs, provider diagnostics and credentials never
/// become app errors/logs. Tools inherit only nonsecret runtime necessities.
final class ProcessScope {
  ProcessScope({
    required this.python,
    required this.guard,
    this.maxFileBytes = 50 * 1024 * 1024,
  });
  final String python, guard;
  final int maxFileBytes;
  final Set<Process> _processes = {};
  bool cancelled = false;
  AppFailure? _cancellationCause;

  void cancel({AppFailure? cause}) {
    _cancellationCause ??= cause;
    cancelled = true;
    for (final process in _processes.toList()) {
      process.kill(ProcessSignal.sigterm);
    }
  }

  void check() {
    if (cancelled) {
      throw _cancellationCause ??
          const AppFailure(
            FailureCode.operationCancelled,
            'Processing stopped.',
          );
    }
  }

  Future<String> run(
    String executable,
    List<String> arguments, {
    required Directory directory,
    Duration timeout = const Duration(minutes: 5),
    int maxOutputBytes = 4 * 1024 * 1024,
    Future<void> Function()? monitor,
    void Function(List<int>)? onOutput,
    bool localAudio = false,
    bool requireCleanStderr = false,
  }) async {
    check();
    if (timeout <= Duration.zero || maxOutputBytes <= 0) {
      throw const AppFailure(
        FailureCode.limitExceeded,
        'Invalid media operation limits.',
      );
    }
    Process? process;
    StreamSubscription<List<int>>? stdout, stderr;
    Timer? deadline, polling;
    Future<void>? pendingMonitor;
    AppFailure? failure;
    Directory? audioConfiguration;
    final output = BytesBuilder(copy: false);
    var outputBytes = 0;
    var hasStderr = false;
    String stderrTail = "";
    FailureCode? exitHint;
    void abort(AppFailure error) {
      failure ??= error;
      process?.kill(ProcessSignal.sigterm);
    }

    try {
      final environment = <String, String>{
        for (final key in [
          'PATH',
          'HOME',
          'LANG',
          'LC_ALL',
          'SSL_CERT_FILE',
          'SSL_CERT_DIR',
        ])
          if (Platform.environment[key] != null)
            key: Platform.environment[key]!,
        'TMPDIR': directory.path,
        'DENO_DIR': '${directory.path}/deno-cache',
        'PYTHONIOENCODING': 'utf-8',
      };
      if (localAudio) {
        if (!Platform.isLinux) {
          throw const AppFailure(
            FailureCode.unsupportedPlatform,
            'This audio output adapter requires Linux.',
          );
        }
        // PulseAudio otherwise allocates a shared-memory file larger than the
        // media file cap. Use local socket transport without raising that cap,
        // reading user client configuration or autospawning another server.
        audioConfiguration = await directory.createTemp('.audio-client-');
        final config = File('${audioConfiguration.path}/client.conf');
        await config.writeAsString(
          'enable-shm = no\nenable-memfd = no\nautospawn = no\n',
          flush: true,
        );
        environment['PULSE_CLIENTCONFIG'] = config.path;
      }
      process = await Process.start(
        python,
        ['-I', guard, '$maxFileBytes', executable, ...arguments],
        workingDirectory: directory.path,
        environment: environment,
        includeParentEnvironment: false,
        runInShell: false,
      );
      _processes.add(process);
      if (cancelled) process.kill(ProcessSignal.sigterm);
      final outDone = Completer<void>(), errDone = Completer<void>();
      void count(List<int> bytes) {
        outputBytes += bytes.length;
        if (outputBytes > maxOutputBytes) {
          abort(
            const AppFailure(
              FailureCode.limitExceeded,
              'Tool output exceeded its safe limit.',
            ),
          );
        }
      }

      stdout = process.stdout.listen(
        (bytes) {
          count(bytes);
          if (failure == null) {
            output.add(bytes);
            try {
              onOutput?.call(bytes);
            } catch (_) {
              abort(
                const AppFailure(
                  FailureCode.toolUnavailable,
                  'Tool progress could not be read safely.',
                ),
              );
            }
          }
        },
        onDone: outDone.complete,
        onError: (Object _) {
          abort(
            const AppFailure(
              FailureCode.storageUnavailable,
              'Tool output could not be read.',
            ),
          );
          outDone.complete();
        },
        cancelOnError: true,
      );
      stderr = process.stderr.listen(
        (bytes) {
          hasStderr = hasStderr || bytes.isNotEmpty;
          count(bytes);
          final text =
              stderrTail +
              utf8.decode(bytes, allowMalformed: true).toLowerCase();
          if (text.contains('file too large')) {
            exitHint = FailureCode.limitExceeded;
          }
          if (text.contains('no space left on device')) {
            exitHint = FailureCode.storageUnavailable;
          }
          stderrTail = text.length > 512
              ? text.substring(text.length - 512)
              : text;
        },
        onDone: errDone.complete,
        onError: (Object _) {
          abort(
            const AppFailure(
              FailureCode.storageUnavailable,
              'Tool output could not be read.',
            ),
          );
          errDone.complete();
        },
        cancelOnError: true,
      );
      deadline = Timer(
        timeout,
        () => abort(
          const AppFailure(
            FailureCode.processTimeout,
            'The media operation timed out.',
            retryable: true,
          ),
        ),
      );
      if (monitor != null) {
        polling = Timer.periodic(const Duration(milliseconds: 100), (_) {
          if (pendingMonitor != null) return;
          pendingMonitor = Future<void>.sync(monitor)
              .catchError((Object error) {
                abort(
                  error is AppFailure
                      ? error
                      : const AppFailure(
                          FailureCode.storageUnavailable,
                          'Storage could not be checked safely.',
                        ),
                );
              })
              .whenComplete(() {
                pendingMonitor = null;
              });
        });
      }
      final code = await process.exitCode;
      polling?.cancel();
      await Future.wait([outDone.future, errDone.future])
          .timeout(const Duration(seconds: 3));
      final pending = pendingMonitor;
      if (pending != null) await pending;
      check();
      if (failure != null) throw failure!;
      // Some tools report a failed final buffered flush but still exit zero.
      // A successful exit cannot override an observed storage failure.
      if (exitHint != null || code == 153) {
        final reason = exitHint ?? FailureCode.limitExceeded;
        throw AppFailure(
          reason,
          reason == FailureCode.limitExceeded
              ? 'A media file exceeded its enforced byte limit.'
              : 'The device ran out of storage.',
          retryable: true,
        );
      }
      if (code != 0 || (requireCleanStderr && hasStderr)) {
        throw const AppFailure(
          FailureCode.sourceUnavailable,
          'The source or media tool could not finish. Check the connection and retry.',
          retryable: true,
        );
      }
      if (monitor != null) await monitor();
      return utf8.decode(output.takeBytes());
    } on AppFailure {
      rethrow;
    } on TimeoutException {
      throw const AppFailure(
        FailureCode.processTimeout,
        'The tool did not close its output safely.',
        retryable: true,
      );
    } catch (_) {
      throw const AppFailure(
        FailureCode.toolUnavailable,
        'The media tool could not start safely.',
        retryable: true,
      );
    } finally {
      deadline?.cancel();
      polling?.cancel();
      await stdout?.cancel();
      await stderr?.cancel();
      if (process != null) {
        process.kill(ProcessSignal.sigterm);
        // Cleanup must not race the supervisor's final descendant termination.
        await process.exitCode;
        _processes.remove(process);
      }
      final pending = pendingMonitor;
      if (pending != null) await pending;
      if (audioConfiguration != null) {
        try {
          await audioConfiguration.delete(recursive: true);
        } on FileSystemException {
          /* Private scratch cleanup retries later. */
        }
      }
    }
  }
}
