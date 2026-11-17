import 'package:razorpay_flutter/razorpay_flutter.dart';

import '../core/constants/app_constants.dart';

/// Callback signature invoked when a Razorpay payment succeeds.
typedef PaymentSuccessCallback = void Function(PaymentSuccessResponse response);

/// Callback signature invoked when a Razorpay payment fails or is cancelled.
typedef PaymentErrorCallback = void Function(String message);

/// Manages Razorpay UPI checkout sessions for platform booking fees.
class PaymentService {
  PaymentService() {
    _razorpay = Razorpay();
    _razorpay.on(Razorpay.EVENT_PAYMENT_SUCCESS, _handlePaymentSuccess);
    _razorpay.on(Razorpay.EVENT_PAYMENT_ERROR, _handlePaymentError);
    _razorpay.on(Razorpay.EVENT_EXTERNAL_WALLET, _handleExternalWallet);
  }

  late final Razorpay _razorpay;
  PaymentSuccessCallback? _onSuccess;
  PaymentErrorCallback? _onError;
  bool _isDisposed = false;

  /// Launches Razorpay Checkout configured for UPI and standard Indian methods.
  ///
  /// [orderId] and [keyId] come from the server (`razorpay-create-order`), so
  /// the payment is bound to a server-created order that can be verified.
  void openCheckout({
    required String orderId,
    required String keyId,
    required int amountInPaise,
    required String bookingId,
    required String customerPhone,
    required String customerName,
    required String description,
    required PaymentSuccessCallback onSuccess,
    required PaymentErrorCallback onError,
  }) {
    if (_isDisposed) return;

    _onSuccess = onSuccess;
    _onError = onError;

    final cleanedPhone = customerPhone.replaceAll(RegExp(r'[^0-9+]'), '');
    final options = <String, dynamic>{
      'key': keyId.isNotEmpty ? keyId : AppConstants.RAZORPAY_KEY_ID,
      'order_id': orderId,
      'amount': amountInPaise,
      'currency': 'INR',
      'name': AppConstants.appName,
      'description': description,
      'retry': <String, dynamic>{'enabled': true, 'max_count': 2},
      'prefill': <String, dynamic>{
        'contact': cleanedPhone,
        'name': customerName,
      },
      'notes': <String, dynamic>{
        'booking_id': bookingId,
        'city': AppConstants.cityName,
      },
      'method': <String, dynamic>{
        'upi': true,
        'card': true,
        'netbanking': true,
        'wallet': true,
      },
      'theme': <String, dynamic>{
        'color': '#FF5722',
      },
    };

    try {
      _razorpay.open(options);
    } catch (error) {
      _onError?.call('Payment screen open nahi ho paya. Please retry.');
    }
  }

  void _handlePaymentSuccess(PaymentSuccessResponse response) {
    _onSuccess?.call(response);
  }

  void _handlePaymentError(PaymentFailureResponse response) {
    final message = (response.message != null && response.message!.isNotEmpty)
        ? response.message!
        : 'Payment was cancelled or failed (Code ${response.code ?? '-'}).';
    _onError?.call(message);
  }

  void _handleExternalWallet(ExternalWalletResponse response) {
    final wallet = response.walletName ?? 'external wallet';
    _onError?.call('Please complete payment in $wallet and retry if needed.');
  }

  /// Releases native Razorpay event listeners.
  void dispose() {
    if (_isDisposed) return;
    _isDisposed = true;
    _onSuccess = null;
    _onError = null;
    _razorpay.clear();
  }
}
