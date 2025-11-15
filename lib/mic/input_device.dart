/// Enum đại diện cho loại thiết bị input
enum InputDeviceType {
  /// Thiết bị tích hợp sẵn (built-in)
  builtIn,
  
  /// Thiết bị Bluetooth
  bluetooth,
  
  /// Thiết bị ngoài (external)
  external;

  /// Tạo từ string (từ native code)
  static InputDeviceType fromString(String type) {
    switch (type.toLowerCase()) {
      case 'built-in':
        return InputDeviceType.builtIn;
      case 'bluetooth':
        return InputDeviceType.bluetooth;
      case 'external':
        return InputDeviceType.external;
      default:
        return InputDeviceType.external;
    }
  }

  /// Chuyển đổi sang string (để gửi về native code nếu cần)
  @override
  String toString() {
    switch (this) {
      case InputDeviceType.builtIn:
        return 'built-in';
      case InputDeviceType.bluetooth:
        return 'bluetooth';
      case InputDeviceType.external:
        return 'external';
    }
  }
}

/// Class đại diện cho thông tin thiết bị input (microphone)
class InputDevice {
  /// ID duy nhất của thiết bị
  final String id;

  /// Tên thiết bị
  final String name;

  /// Loại thiết bị
  final InputDeviceType type;

  /// Số lượng kênh audio
  final int channelCount;

  /// Có phải thiết bị mặc định không
  final bool isDefault;

  /// Constructor
  const InputDevice({
    required this.id,
    required this.name,
    required this.type,
    required this.channelCount,
    required this.isDefault,
  });

  /// Tạo từ Map (từ native code)
  factory InputDevice.fromMap(Map<String, dynamic> map) {
    return InputDevice(
      id: map['id'] as String? ?? '',
      name: map['name'] as String? ?? '',
      type: InputDeviceType.fromString(map['type'] as String? ?? 'external'),
      channelCount: map['channelCount'] as int? ?? 0,
      isDefault: map['isDefault'] as bool? ?? false,
    );
  }

  /// Chuyển đổi sang Map (để gửi về native code nếu cần)
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'type': type.toString(),
      'channelCount': channelCount,
      'isDefault': isDefault,
    };
  }

  @override
  String toString() {
    return 'InputDevice(id: $id, name: $name, type: ${type.toString()}, '
        'channelCount: $channelCount, isDefault: $isDefault)';
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is InputDevice && other.id == id;
  }

  @override
  int get hashCode => id.hashCode;
}

