// Smoke test: the app builds and shows the login screen when signed out.
import 'package:flutter_test/flutter_test.dart';

import 'package:nimbus/main.dart';

void main() {
  testWidgets('App boots to the Nimbus login screen', (tester) async {
    await tester.pumpWidget(const NimbusApp());
    await tester.pump();
    expect(find.text('Nimbus'), findsWidgets);
  });
}
