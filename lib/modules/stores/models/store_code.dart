import 'package:equatable/equatable.dart';

const _testCodeFrom = 999900001;
const _testCodeTo = 999900009;

class StoreCode extends Equatable {
  const StoreCode({
    required this.id,
    required this.storeName,
    this.env = 'prod',
    this.activationCode = '',
    this.supportCode = '',
    this.supportExpire,
    this.devicePrefix = '',
    this.notes = '',
  });

  final String id;
  final String storeName;
  final String env;
  final String activationCode;
  final String supportCode;
  final DateTime? supportExpire;
  final String devicePrefix;
  final String notes;

  /// Same as `_getServerNumber` in the app's ActivationCubit.
  static int serverOf(String code) {
    if (code.length != 9) return 1;
    final n = int.tryParse(code.substring(0, 2)) ?? 1;
    return n == 1 || n == 99 ? 1 : n;
  }

  /// Same as `LocalStorage.isTestCode` in the app.
  static bool isTestCode(String code) {
    final n = int.tryParse(code) ?? 0;
    return n == 0 || (n >= _testCodeFrom && n <= _testCodeTo);
  }

  int get server => serverOf(activationCode);

  bool get supportExpired => supportExpire != null && supportExpire!.isBefore(DateTime.now());

  StoreCode copyWith({
    String? storeName,
    String? env,
    String? activationCode,
    String? supportCode,
    DateTime? supportExpire,
    bool clearSupportExpire = false,
    String? devicePrefix,
    String? notes,
  }) => StoreCode(
    id: id,
    storeName: storeName ?? this.storeName,
    env: env ?? this.env,
    activationCode: activationCode ?? this.activationCode,
    supportCode: supportCode ?? this.supportCode,
    supportExpire: clearSupportExpire ? null : (supportExpire ?? this.supportExpire),
    devicePrefix: devicePrefix ?? this.devicePrefix,
    notes: notes ?? this.notes,
  );

  Map<String, dynamic> toJson() => {
    'id': id,
    'storeName': storeName,
    'env': env,
    'activationCode': activationCode,
    'supportCode': supportCode,
    'supportExpire': supportExpire?.toIso8601String(),
    'devicePrefix': devicePrefix,
    'notes': notes,
  };

  factory StoreCode.fromJson(Map<String, dynamic> json) => StoreCode(
    id: json['id'] as String? ?? DateTime.now().microsecondsSinceEpoch.toString(),
    storeName: json['storeName'] as String? ?? '',
    env: json['env'] as String? ?? 'prod',
    activationCode: json['activationCode'] as String? ?? '',
    supportCode: json['supportCode'] as String? ?? '',
    supportExpire: DateTime.tryParse(json['supportExpire'] as String? ?? ''),
    devicePrefix: json['devicePrefix'] as String? ?? '',
    notes: json['notes'] as String? ?? '',
  );

  @override
  List<Object?> get props => [id, storeName, env, activationCode, supportCode, supportExpire, devicePrefix, notes];
}
