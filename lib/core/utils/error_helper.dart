import 'dart:async';
import 'dart:io';

import 'package:supabase_flutter/supabase_flutter.dart';

/// Converts any Supabase / network / server error into a short, friendly
/// message that can be shown directly in a SnackBar.
class ErrorHelper {
  ErrorHelper._();

  static String friendly(
    Object error, {
    String fallback = 'Kuch galat ho gaya. Please dobara try karein.',
  }) {
    if (error is SocketException || error is TimeoutException) {
      return 'Internet connection weak hai. Network check karke retry karein.';
    }
    if (error is AuthException) {
      return error.message.isNotEmpty ? error.message : fallback;
    }
    if (error is PostgrestException) {
      // Messages raised by our SQL functions are already user friendly.
      final message = error.message.trim();
      if (error.code == '28000' || error.code == 'PGRST301') {
        return 'Session expire ho gaya. Please dobara login karein.';
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
      return 'Internet connection weak hai. Network check karke retry karein.';
    }
    return fallback;
  }
}
