import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../api/client.dart';

class AuthState {
  const AuthState({this.token, this.user, this.isLoading = false, this.error});

  final String? token;
  final Map<String, dynamic>? user;
  final bool isLoading;
  final String? error;

  AuthState copyWith({
    String? token,
    Map<String, dynamic>? user,
    bool? isLoading,
    String? error,
  }) {
    return AuthState(
      token: token ?? this.token,
      user: user ?? this.user,
      isLoading: isLoading ?? this.isLoading,
      error: error,
    );
  }
}

String _formatAuthError(Object e) {
  if (e is DioException) {
    if (e.type == DioExceptionType.connectionError ||
        e.type == DioExceptionType.connectionTimeout) {
      return '서버에 연결할 수 없습니다 ($resolvedApiBaseUrl). 백엔드가 실행 중인지 확인하세요.';
    }
    final data = e.response?.data;
    if (data is Map && data['detail'] != null) {
      return data['detail'].toString();
    }
    if (e.response?.statusCode == 409) {
      return '이미 등록된 이메일입니다.';
    }
    return e.message ?? e.toString();
  }
  return e.toString();
}

class AuthNotifier extends StateNotifier<AuthState> {
  AuthNotifier() : super(const AuthState(isLoading: true)) {
    _init();
  }

  Future<void> _init() async {
    final token = await apiClient.getToken();
    if (token != null) {
      try {
        final user = await apiClient.me();
        state = AuthState(token: token, user: user);
      } catch (_) {
        await apiClient.clearToken();
        state = const AuthState();
      }
    } else {
      state = const AuthState();
    }
  }

  Future<bool> login(String email, String password) async {
    state = state.copyWith(isLoading: true, error: null);
    try {
      final data = await apiClient.login(email, password);
      final token = data['access_token'] as String;
      await apiClient.saveToken(token);
      final user = await apiClient.me();
      state = AuthState(token: token, user: user);
      return true;
    } catch (e) {
      state = AuthState(error: _formatAuthError(e));
      return false;
    }
  }

  Future<bool> register(String email, String password) async {
    if (password.length < 6) {
      state = const AuthState(error: '비밀번호는 6자 이상이어야 합니다.');
      return false;
    }
    state = state.copyWith(isLoading: true, error: null);
    try {
      final data = await apiClient.register(email, password);
      final token = data['access_token'] as String;
      await apiClient.saveToken(token);
      final user = await apiClient.me();
      state = AuthState(token: token, user: user);
      return true;
    } catch (e) {
      state = AuthState(error: _formatAuthError(e));
      return false;
    }
  }

  Future<void> logout() async {
    await apiClient.clearToken();
    state = const AuthState();
  }

  Future<void> refreshUser() async {
    if (state.token == null) return;
    final user = await apiClient.me();
    state = state.copyWith(user: user);
  }
}

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>(
  (ref) => AuthNotifier(),
);
