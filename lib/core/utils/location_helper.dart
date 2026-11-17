import 'package:flutter/foundation.dart';
import 'package:geocoding/geocoding.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../constants/app_constants.dart';

/// Outcome of a GPS location fetch attempt.
class LocationResult {
  const LocationResult({
    required this.coordinates,
    required this.address,
    required this.isFallback,
    this.errorMessage,
    this.permissionPermanentlyDenied = false,
    this.serviceDisabled = false,
  });

  final LatLng coordinates;
  final String address;
  final bool isFallback;
  final String? errorMessage;
  final bool permissionPermanentlyDenied;
  final bool serviceDisabled;
}

/// Handles runtime GPS permission checks, current position acquisition,
/// and reverse geocoding into human-readable Durgapur addresses.
class LocationHelper {
  LocationHelper._();

  /// Checks location services and runtime permissions, then returns the
  /// device coordinates and reverse-geocoded address.
  ///
  /// Falls back cleanly to Durgapur City Centre (`23.5411, 87.2915`) if
  /// GPS services are disabled, denied, or time out.
  static Future<LocationResult> getCurrentLocationWithAddress() async {
    try {
      final serviceEnabled = await Geolocator.isLocationServiceEnabled();
      if (!serviceEnabled) {
        return await _fallbackResult(
          errorMessage:
              'Location services are turned off. Showing Durgapur City Centre.',
          serviceDisabled: true,
        );
      }

      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
        if (permission == LocationPermission.denied) {
          return await _fallbackResult(
            errorMessage:
                'Location permission denied. Drag the map pin to choose pickup.',
          );
        }
      }

      if (permission == LocationPermission.deniedForever) {
        return await _fallbackResult(
          errorMessage:
              'Location permission permanently denied. Enable it in Settings.',
          permissionPermanentlyDenied: true,
        );
      }

      final LocationSettings locationSettings;
      if (defaultTargetPlatform == TargetPlatform.android) {
        locationSettings = AndroidSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
          timeLimit: const Duration(seconds: 15),
        );
      } else {
        locationSettings = const LocationSettings(
          accuracy: LocationAccuracy.high,
          distanceFilter: 10,
          timeLimit: Duration(seconds: 15),
        );
      }

      final position = await Geolocator.getCurrentPosition(
        locationSettings: locationSettings,
      );
      final coords = LatLng(position.latitude, position.longitude);
      final address = await getAddressFromLatLng(
        coords.latitude,
        coords.longitude,
      );

      await _cacheLastLocation(coords, address);

      return LocationResult(
        coordinates: coords,
        address: address,
        isFallback: false,
      );
    } catch (_) {
      return _fallbackResult(
        errorMessage:
            'Unable to fetch live GPS fix. Showing Durgapur City Centre.',
      );
    }
  }

  /// Reverse-geocodes [lat] and [lng] into a readable street address.
  static Future<String> getAddressFromLatLng(double lat, double lng) async {
    try {
      final placemarks = await placemarkFromCoordinates(lat, lng);
      if (placemarks.isEmpty) {
        return _formatCoordinates(lat, lng);
      }

      final place = placemarks.first;
      final segments = <String>[];

      void addUnique(String? value) {
        final trimmed = value?.trim() ?? '';
        if (trimmed.isEmpty) return;
        final lower = trimmed.toLowerCase();
        final alreadyPresent = segments.any(
          (item) => item.toLowerCase() == lower,
        );
        if (!alreadyPresent) {
          segments.add(trimmed);
        }
      }

      addUnique(place.name);
      addUnique(place.street);
      addUnique(place.subLocality);
      addUnique(place.locality);
      addUnique(place.administrativeArea);
      addUnique(place.postalCode);

      if (segments.isEmpty) {
        return _formatCoordinates(lat, lng);
      }
      return segments.join(', ');
    } catch (_) {
      return _formatCoordinates(lat, lng);
    }
  }

  /// Opens the device location settings screen.
  static Future<bool> openLocationSettings() {
    return Geolocator.openLocationSettings();
  }

  /// Opens the Android application settings screen for permissions.
  static Future<bool> openAppSettings() {
    return Geolocator.openAppSettings();
  }

  static Future<LocationResult> _fallbackResult({
    required String errorMessage,
    bool permissionPermanentlyDenied = false,
    bool serviceDisabled = false,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final cachedLat = prefs.getDouble(AppConstants.prefLastPickupLat);
      final cachedLng = prefs.getDouble(AppConstants.prefLastPickupLng);
      final cachedAddress = prefs.getString(AppConstants.prefLastPickupAddress);

      if (cachedLat != null &&
          cachedLng != null &&
          cachedAddress != null &&
          cachedAddress.isNotEmpty) {
        return LocationResult(
          coordinates: LatLng(cachedLat, cachedLng),
          address: cachedAddress,
          isFallback: true,
          errorMessage: errorMessage,
          permissionPermanentlyDenied: permissionPermanentlyDenied,
          serviceDisabled: serviceDisabled,
        );
      }
    } catch (_) {
      // Ignore SharedPreferences read failures and fall back to City Centre.
    }

    return LocationResult(
      coordinates: const LatLng(
        AppConstants.defaultLat,
        AppConstants.defaultLng,
      ),
      address: AppConstants.defaultPickupAddress,
      isFallback: true,
      errorMessage: errorMessage,
      permissionPermanentlyDenied: permissionPermanentlyDenied,
      serviceDisabled: serviceDisabled,
    );
  }

  static Future<void> _cacheLastLocation(LatLng coords, String address) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setDouble(AppConstants.prefLastPickupLat, coords.latitude);
      await prefs.setDouble(AppConstants.prefLastPickupLng, coords.longitude);
      await prefs.setString(AppConstants.prefLastPickupAddress, address);
    } catch (_) {
      // Non-critical cache failure.
    }
  }

  static String _formatCoordinates(double lat, double lng) {
    return 'Durgapur (${lat.toStringAsFixed(4)}, ${lng.toStringAsFixed(4)})';
  }
}
