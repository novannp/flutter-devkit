class KnownApp {
  const KnownApp(this.name, this.short, this.package);

  final String name;
  final String short;
  final String package;
}

// New apps only need to be added here.
const knownApps = [
  KnownApp('Ravo POS', 'POS', 'com.payfirstsolutions.ravopos'),
  KnownApp('Rova Signature', 'Signature', 'com.payfirstsolutions.rovapad'),
  KnownApp('Ravo Checkout', 'Checkout', 'com.payfirstsolutions.ravocheckout'),
  KnownApp('Ravo Turn', 'Turn', 'com.payfirstsolutions.ravoturn'),
  KnownApp('Ravo Checkin', 'Checkin', 'com.payfirstsolutions.rovacheckin'),
  KnownApp('Rova Digital Signage', 'Signage', 'com.payfirstsolutions.rovadigitalsignage'),
  KnownApp('Ramo App', 'Ramo', 'com.payfirstsolutions.ravotechapp'),
];

const ourPackagePrefix = 'com.payfirstsolutions.';

bool isOurApp(String package) => package.startsWith(ourPackagePrefix);

KnownApp? appByPackage(String package) => knownApps.where((a) => a.package == package).firstOrNull;

String appName(String package) => appByPackage(package)?.name ?? package;

String appShort(String package) => appByPackage(package)?.short ?? package.replaceFirst(ourPackagePrefix, '');
