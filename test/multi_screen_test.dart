import 'package:devkit/core/tools.dart';
import 'package:devkit/modules/devices/cubit/devices_cubit.dart';
import 'package:devkit/modules/devices/models/device.dart';
import 'package:devkit/modules/devices/services/adb_service.dart';
import 'package:devkit/modules/devices/services/device_store.dart';
import 'package:devkit/modules/devices/services/mdns_service.dart';
import 'package:devkit/modules/devices/services/network_scanner.dart';
import 'package:devkit/modules/devices/view/multi_screen_page.dart';
import 'package:devkit/modules/devices/view/workspace/embedded_scrcpy.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('connected devices wait to be picked', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final tools = (await tester.runAsync(Tools.resolve))!;
    final adb = AdbService(tools);
    final cubit = DevicesCubit(adb: adb, mdns: MdnsService(), scanner: NetworkScanner(), store: DeviceStore())..toggleDemo();
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(
      RepositoryProvider.value(
        value: adb,
        child: BlocProvider.value(
          value: cubit,
          child: const MaterialApp(home: Scaffold(body: MultiScreenPage())),
        ),
      ),
    );
    await tester.pump();

    final connected = cubit.state.devices.where((d) => d.adb == AdbState.connected && d.adbTarget != null).toList();
    expect(connected, isNotEmpty);
    for (final d in connected) {
      final chip = find.ancestor(of: find.text(d.displayName), matching: find.byType(FilterChip));
      expect(tester.widget<FilterChip>(chip).selected, isFalse, reason: d.displayName);
    }
    expect(find.byType(EmbeddedScrcpy), findsNothing);
    expect(find.text('Select devices above to show them.'), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    await tester.binding.setSurfaceSize(null);
  });
}
