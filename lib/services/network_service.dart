import 'dart:async';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';

/// 网络状态检测服务（需求 §6.3）
///
/// 先用 connectivity_plus 看是否有网络接口，再对 api.deepseek.com:443
/// 做一次短超时 TCP 探活，避免「连着 Wi-Fi 但实际不通」的情况。
class NetworkService {
  NetworkService._();
  static final NetworkService instance = NetworkService._();

  static const _probeHost = 'api.deepseek.com';
  static const _probePort = 443;
  static const _probeTimeout = Duration(seconds: 3);

  bool _lastOnline = false;
  DateTime _lastCheckAt = DateTime.fromMillisecondsSinceEpoch(0);

  bool get isOnline => _lastOnline;

  /// 最近一次检测结果（不主动发起探测）
  bool get cachedOnline => _lastOnline;

  /// 检测是否在线。3 秒内的重复调用直接返回缓存，避免频繁探测。
  Future<bool> checkOnline({bool force = false}) async {
    final now = DateTime.now();
    if (!force && now.difference(_lastCheckAt) < const Duration(seconds: 3)) {
      return _lastOnline;
    }
    _lastCheckAt = now;
    _lastOnline = await _probe();
    return _lastOnline;
  }

  Future<bool> _probe() async {
    try {
      final results = await Connectivity().checkConnectivity();
      if (results.contains(ConnectivityResult.none) && results.length == 1) {
        return false;
      }
    } catch (_) {
      // 拿不到接口状态时继续走 TCP 探活
    }

    try {
      final socket = await Socket.connect(
        _probeHost,
        _probePort,
        timeout: _probeTimeout,
      );
      socket.destroy();
      return true;
    } on SocketException {
      return false;
    } on TimeoutException {
      return false;
    } catch (_) {
      return false;
    }
  }
}
