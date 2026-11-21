import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../core/constants/app_constants.dart';

/// Safety sheet: emergency numbers, share the trip with family, call support.
/// The shared text never contains the start OTP.
Future<void> showSosSheet(
  BuildContext context, {
  required String pickupAddress,
  required double lat,
  required double lng,
  String? mechanicName,
  String? vehicleName,
  String? bookingId,
}) {
  Future<void> open(Uri uri) async {
    try {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    } catch (_) {}
  }

  final shortId = bookingId == null || bookingId.length < 8
      ? ''
      : ' (booking ${bookingId.substring(0, 8)})';
  final tripText = StringBuffer()
    ..write('I am using 8SpeedyService for roadside help$shortId.')
    ..write(vehicleName != null ? ' Vehicle: $vehicleName.' : '')
    ..write(mechanicName != null ? ' Mechanic: $mechanicName.' : '')
    ..write(
      ' Location: $pickupAddress — https://maps.google.com/?q=${lat.toStringAsFixed(5)},${lng.toStringAsFixed(5)}',
    );

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(28)),
    ),
    builder: (ctx) {
      Widget action(
        IconData icon,
        Color color,
        String title,
        String subtitle,
        VoidCallback onTap,
      ) {
        return ListTile(
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 4,
            vertical: 2,
          ),
          leading: Container(
            width: 46,
            height: 46,
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Icon(icon, color: color),
          ),
          title: Text(
            title,
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          subtitle: Text(subtitle, style: const TextStyle(fontSize: 12.5)),
          onTap: () {
            Navigator.of(ctx).pop();
            onTap();
          },
        );
      }

      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              const Row(
                children: <Widget>[
                  Icon(Icons.shield_rounded, color: Color(0xFFDC2626)),
                  SizedBox(width: 8),
                  Text(
                    'Safety & SOS',
                    style: TextStyle(
                      fontSize: 19,
                      fontWeight: FontWeight.w800,
                      color: AppConstants.secondaryDarkColor,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              const Text(
                'Help is one tap away. These actions work even without the internet.',
                style: TextStyle(color: Color(0xFF64748B), fontSize: 13),
              ),
              const SizedBox(height: 12),
              action(
                Icons.emergency_rounded,
                const Color(0xFFDC2626),
                'Call 112 — Emergency',
                'Police, fire and medical help',
                () => open(
                  Uri(scheme: 'tel', path: AppConstants.emergencyNumber),
                ),
              ),
              action(
                Icons.local_hospital_rounded,
                const Color(0xFFEA580C),
                'Call 108 — Ambulance',
                'Free emergency ambulance',
                () => open(
                  Uri(scheme: 'tel', path: AppConstants.ambulanceNumber),
                ),
              ),
              action(
                Icons.share_location_rounded,
                AppConstants.successColor,
                'Share trip on WhatsApp',
                'Send your location and mechanic details to family',
                () => open(
                  Uri.parse(
                    'https://wa.me/?text=${Uri.encodeComponent(tripText.toString())}',
                  ),
                ),
              ),
              action(
                Icons.sms_rounded,
                const Color(0xFF2563EB),
                'Share trip by SMS',
                'Works on any phone',
                () => open(
                  Uri(
                    scheme: 'sms',
                    queryParameters: <String, String>{
                      'body': tripText.toString(),
                    },
                  ),
                ),
              ),
              action(
                Icons.support_agent_rounded,
                AppConstants.secondaryDarkColor,
                'Call 8SpeedyService support',
                AppConstants.supportPhoneDisplay,
                () => open(
                  Uri(
                    scheme: 'tel',
                    path: '+${AppConstants.supportPhoneNumber}',
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
