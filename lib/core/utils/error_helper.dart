import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts any Supabase / network / server error into a short, friendly
/// message that can be shown directly in a SnackBar.
class ErrorHelper {
  ErrorHelper._();

  static String friendly(
    Object error, {
    String fallback = 'Something went wrong. Please try again.',
  }) {
    if (error is SocketException || error is TimeoutException) {
      return 'Weak internet connection. Check your network and try again.';
    }
    if (error is AuthException) {
      return error.message.isNotEmpty ? error.message : fallback;
    }
    if (error is PostgrestException) {
      // Messages raised by our SQL functions are already user friendly.
      final message = error.message.trim();
      if (error.code == 'PGRST202') {
        return 'The server is being updated. Please try again in a few minutes.';
      }
      if (error.code == '28000' || error.code == 'PGRST301') {
        return 'Your session has expired. Please log in again.';
      }
      if (message.isNotEmpty && !message.contains('violates') &&
          !message.contains('permission denied')) {
        return message;
      }
      return fallback;
    }
    if (error is FunctionException) {
      final details = error.details;
      if (details is Map && details['error'] is String) {
        return details['error'] as String;
      }
      return fallback;
    }
    if (error is StateError) {
      return error.message;
    }
    final text = error.toString();
    if (text.contains('SocketException') ||
        text.contains('Failed host lookup') ||
        text.contains('ClientException')) {
      return 'Weak internet connection. Check your network and try again.';
    }
    return fallback;
  }
}
