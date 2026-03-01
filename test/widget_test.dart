// This is a basic Flutter widget test.
//
// To perform an interaction with a widget in your test, use the WidgetTester
// utility in the flutter_test package. For example, you can send tap and scroll
// gestures. You can also use WidgetTester to find child widgets in the widget
// tree, read text, and verify that the values of widget properties are correct.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:pec_night_canteen/main.dart';

void main() {
  testWidgets('Counter increments smoke test', (WidgetTester tester) async {
    // Build our app and trigger a frame.
    // Build the application using the actual root widget and a default screen
    await tester.pumpWidget(const NightCanteenApp(initialScreen: RoleSelectionScreen()));

    // App bar title should be present on the role selection screen
    expect(find.text('Hostel Night Canteen'), findsOneWidget);
    expect(find.byIcon(Icons.school), findsOneWidget);

  });
}
