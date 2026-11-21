import 'package:material_ui/material_ui.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import 'core/constants/app_constants.dart';
import 'screens/1_splash_screen.dart';

// ignore: constant_identifier_names
const String SUPABASE_URL = AppConstants.SUPABASE_URL;

// ignore: constant_identifier_names
const String SUPABASE_ANON_KEY = AppConstants.SUPABASE_ANON_KEY;

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!AppConstants.isBackendConfigured) {
    runApp(const _MissingConfigApp());
    return;
  }

  await Supabase.initialize(
    url: SUPABASE_URL,
    publishableKey: SUPABASE_ANON_KEY,
  );

  runApp(const SpeedyServiceApp());
}

/// Root widget configuring Material 3 theming (`#FF5722`) and launching
/// [SplashScreen].
class SpeedyServiceApp extends StatelessWidget {
  const SpeedyServiceApp({super.key});

  @override
  Widget build(BuildContext context) {
    final colorScheme = ColorScheme.fromSeed(
      seedColor: AppConstants.primaryColor,
      primary: AppConstants.primaryColor,
    );

    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        fontFamily: 'Poppins',
        colorScheme: colorScheme,
        scaffoldBackgroundColor: AppConstants.backgroundColor,
        appBarTheme: const AppBarTheme(
          backgroundColor: Colors.white,
          foregroundColor: AppConstants.secondaryDarkColor,
          elevation: 0,
          scrolledUnderElevation: 0.5,
          surfaceTintColor: Colors.transparent,
          titleTextStyle: TextStyle(
            fontFamily: 'Poppins',
            fontSize: 18,
            fontWeight: FontWeight.w700,
            color: AppConstants.secondaryDarkColor,
          ),
        ),
        snackBarTheme: SnackBarThemeData(
          behavior: SnackBarBehavior.floating,
          backgroundColor: AppConstants.secondaryDarkColor,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        chipTheme: ChipThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
        ),
        dialogTheme: DialogThemeData(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20),
          ),
        ),
        bottomSheetTheme: const BottomSheetThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        filledButtonTheme: FilledButtonThemeData(
          style: FilledButton.styleFrom(
            backgroundColor: AppConstants.primaryColor,
            foregroundColor: Colors.white,
            minimumSize: const Size(64, 48),
            textStyle: const TextStyle(
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w700,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        outlinedButtonTheme: OutlinedButtonThemeData(
          style: OutlinedButton.styleFrom(
            minimumSize: const Size(64, 48),
            foregroundColor: AppConstants.secondaryDarkColor,
            side: const BorderSide(color: Color(0xFFCBD5E1)),
            textStyle: const TextStyle(
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w700,
            ),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
            ),
          ),
        ),
        textButtonTheme: TextButtonThemeData(
          style: TextButton.styleFrom(
            foregroundColor: AppConstants.primaryDarkColor,
            textStyle: const TextStyle(
              fontFamily: 'Poppins',
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: Colors.white,
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 16,
            vertical: 14,
          ),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: Color(0xFFE2E8F0)),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(
              color: AppConstants.primaryColor,
              width: 1.6,
            ),
          ),
        ),
        listTileTheme: const ListTileThemeData(
          iconColor: AppConstants.secondaryDarkColor,
          titleTextStyle: TextStyle(
            fontFamily: 'Poppins',
            fontSize: 15,
            fontWeight: FontWeight.w600,
            color: AppConstants.secondaryDarkColor,
          ),
        ),
        drawerTheme: const DrawerThemeData(
          backgroundColor: Colors.white,
          surfaceTintColor: Colors.transparent,
        ),
        progressIndicatorTheme: const ProgressIndicatorThemeData(
          color: AppConstants.primaryColor,
        ),
        pageTransitionsTheme: const PageTransitionsTheme(
          builders: <TargetPlatform, PageTransitionsBuilder>{
            TargetPlatform.android: ZoomPageTransitionsBuilder(),
          },
        ),
        splashFactory: InkSparkle.splashFactory,
        visualDensity: VisualDensity.standard,
      ),
      home: const SplashScreen(),
    );
  }
}

/// Shown only when the APK was built without the Supabase keys
/// (`--dart-define-from-file=env/prod.json`). Prevents a confusing blank app.
class _MissingConfigApp extends StatelessWidget {
  const _MissingConfigApp();

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        body: Center(
          child: Padding(
            padding: EdgeInsets.all(24),
            child: Text(
              'App configuration missing.\n\nBuild with:\n'
              'flutter build appbundle --dart-define-from-file=env/prod.json',
              textAlign: TextAlign.center,
            ),
          ),
        ),
      ),
    );
  }
}
