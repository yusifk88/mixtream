import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:learningflutter/main.dart';

void main() {
  testWidgets('App renders with title', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());
    await tester.pump();

    expect(find.text('MixStream Pro Studio'), findsOneWidget);
  });

  testWidgets('Control dock expands with tabs on swipe up', (WidgetTester tester) async {
    await tester.pumpWidget(const MyApp());

    // Swipe up on the dock handle to expand
    await tester.drag(find.byType(GestureDetector).first, const Offset(0, -200));
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.text('Start'), findsOneWidget);
    expect(find.text('Elements'), findsOneWidget);
    expect(find.text('Advance'), findsOneWidget);
  });
}
