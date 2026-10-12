import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yt_playlist_downloader/application/app_runtime.dart';
import 'package:yt_playlist_downloader/domain/failure.dart';
import 'package:yt_playlist_downloader/main.dart';

const failure = AppFailure(
  FailureCode.storageUnavailable,
  'Private storage is unavailable. Retry after checking available space.',
);

void main() {
  testWidgets('rapid retries start only one new storage session', (
    tester,
  ) async {
    var calls = 0;
    final retry = Completer<AppRuntime>();
    Future<AppRuntime> open() {
      calls++;
      return calls == 1 ? Future.error(failure) : retry.future;
    }

    await tester.pumpWidget(RuntimeHost(openRuntime: open));
    await tester.pumpAndSettle();
    final button = find.text('Retry');
    await tester.tap(button);
    await tester.tap(button);
    expect(calls, 2);
    await tester.pump();
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    retry.completeError(failure);
    await tester.pumpAndSettle();
    expect(find.text('Retry'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('startup failures remain scrollable in landscape at large text', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(640, 240);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await tester.pumpWidget(
      RuntimeHost(openRuntime: () => Future.error(failure)),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(find.text('Retry'));
    expect(find.text('Retry'), findsOneWidget);
  });
}
