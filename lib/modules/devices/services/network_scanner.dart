import 'dart:async';
import 'dart:io';

final _subnetRe = RegExp(r'^(\d{1,3})\.(\d{1,3})\.(\d{1,3})(?:\.(\d{1,3}|\*))?(?:/(\d{1,2}))?$');

/// Hosts of `192.168.5`, `192.168.5.*`, `10.1.0.0/22` or a single IP. Null when invalid,
/// or wider than /20: a scan that size would take minutes.
List<String>? subnetHosts(String input) {
  final m = _subnetRe.firstMatch(input.trim());
  if (m == null) return null;
  final last = m[4];
  final hasHost = last != null && last != '*';
  final prefix = m[5] != null ? int.parse(m[5]!) : (hasHost ? 32 : 24);
  final octets = [m[1]!, m[2]!, m[3]!, hasHost ? last : '0'].map(int.parse).toList();
  if (octets.any((o) => o > 255) || prefix < 20 || prefix > 32) return null;
  final ip = octets.fold(0, (sum, o) => (sum << 8) | o);
  final size = 1 << (32 - prefix);
  final base = ip & ~(size - 1);
  String dotted(int v) => [v >> 24 & 255, v >> 16 & 255, v >> 8 & 255, v & 255].join('.');
  // Network and broadcast addresses only exist from /30 down.
  return size <= 2
      ? [for (var i = 0; i < size; i++) dotted(base + i)]
      : [for (var i = 1; i < size - 1; i++) dotted(base + i)];
}

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

  String _slash24(String ip) => ip.contains('.') ? '${ip.substring(0, ip.lastIndexOf('.'))}.0/24' : ip;

  /// The subnets a scan covers: only the ones this PC is on.
  Future<List<String>> subnetLabels() async => {
    for (final a in await localAddresses()) _slash24(a.address),
  }.toList();

  /// Looks for [port] on this PC's own subnets, taken as /24, which covers most networks. Only when asked to.
  Stream<String> scan(
    int port, {
    void Function(int done, int total)? onProgress,
    int concurrency = 64,
    Duration timeout = const Duration(milliseconds: 400),
  }) async* {
    final own = await localAddresses();
    final targets = <String>{
      for (final s in await subnetLabels()) ...?subnetHosts(s),
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
