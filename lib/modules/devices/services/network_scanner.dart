import 'dart:async';
import 'dart:io';

class NetworkScanner {
  static const _virtualNics = ['vethernet', 'wsl', 'virtualbox', 'vmware', 'hyper-v', 'loopback'];

  Future<List<InternetAddress>> localAddresses() async {
    final nics = await NetworkInterface.list(type: InternetAddressType.IPv4);
    return [
      for (final nic in nics)
        if (!_virtualNics.any(nic.name.toLowerCase().contains))
          for (final addr in nic.addresses)
            if (_isPrivate(addr.address)) addr,
    ];
  }

  bool _isPrivate(String ip) =>
      ip.startsWith('192.168.') || ip.startsWith('10.') || RegExp(r'^172\.(1[6-9]|2\d|3[01])\.').hasMatch(ip);

  /// Assumes a /24 subnet, which covers most office networks.
  Stream<String> scan(
    int port, {
    void Function(int done, int total)? onProgress,
    int concurrency = 64,
    Duration timeout = const Duration(milliseconds: 400),
  }) async* {
    final own = await localAddresses();
    final targets = <String>{
      for (final a in own)
        for (var i = 1; i < 255; i++) '${a.address.substring(0, a.address.lastIndexOf('.'))}.$i',
    }..removeAll(own.map((a) => a.address));

    final list = targets.toList();
    var done = 0;
    for (var i = 0; i < list.length; i += concurrency) {
      final batch = list.skip(i).take(concurrency);
      final results = await Future.wait(
        batch.map((ip) async {
          try {
            final s = await Socket.connect(ip, port, timeout: timeout);
            s.destroy();
            return ip;
          } catch (_) {
            return null;
          }
        }),
      );
      done += batch.length;
      onProgress?.call(done, list.length);
      for (final ip in results.nonNulls) {
        yield ip;
      }
    }
  }
}
