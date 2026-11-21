import 'package:material_ui/material_ui.dart';

import '../core/constants/app_constants.dart';
import 'speedy_loader.dart';

/// Shared "premium" building blocks: soft cards, pills, gradient buttons,
/// probability bars and icon mapping for the server-driven issue catalog.

const LinearGradient kBrandGradient = LinearGradient(
  colors: <Color>[
    Color(0xFFFF7A45),
    AppConstants.primaryColor,
    Color(0xFFE64A19),
  ],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

const LinearGradient kNightGradient = LinearGradient(
  colors: <Color>[
    Color(0xFF0F172A),
    AppConstants.secondaryDarkColor,
    Color(0xFF334155),
  ],
  begin: Alignment.topLeft,
  end: Alignment.bottomRight,
);

List<BoxShadow> softShadow([double strength = 1]) => <BoxShadow>[
  BoxShadow(
    color: const Color(0xFF0F172A).withValues(alpha: 0.06 * strength),
    blurRadius: 24,
    offset: const Offset(0, 10),
  ),
  BoxShadow(
    color: const Color(0xFF0F172A).withValues(alpha: 0.03 * strength),
    blurRadius: 4,
    offset: const Offset(0, 1),
  ),
];

/// White rounded card with a soft layered shadow.
class PremiumCard extends StatelessWidget {
  const PremiumCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.all(16),
    this.margin,
    this.color = Colors.white,
    this.borderColor,
    this.onTap,
    this.radius = 20,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final EdgeInsetsGeometry? margin;
  final Color color;
  final Color? borderColor;
  final VoidCallback? onTap;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final card = Container(
      margin: margin,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: borderColor ?? const Color(0xFFE2E8F0)),
        boxShadow: softShadow(),
      ),
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(radius),
        child: InkWell(
          borderRadius: BorderRadius.circular(radius),
          onTap: onTap,
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
    return card;
  }
}

/// Small rounded status / info pill.
class StatusPill extends StatelessWidget {
  const StatusPill({
    super.key,
    required this.label,
    required this.color,
    this.icon,
  });

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(30),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 14, color: color),
            const SizedBox(width: 5),
          ],
          Text(
            label,
            style: TextStyle(
              color: color,
              fontWeight: FontWeight.w700,
              fontSize: 12,
            ),
          ),
        ],
      ),
    );
  }
}

/// Section heading with an optional trailing action.
class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key, this.trailing, this.icon});

  final String text;
  final Widget? trailing;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: <Widget>[
          if (icon != null) ...<Widget>[
            Icon(icon, size: 18, color: AppConstants.primaryColor),
            const SizedBox(width: 8),
          ],
          Expanded(
            child: Text(
              text,
              style: const TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: AppConstants.secondaryDarkColor,
                letterSpacing: -0.2,
              ),
            ),
          ),
          ?trailing,
        ],
      ),
    );
  }
}

/// Big gradient call-to-action button with a built-in loading state.
class GradientButton extends StatelessWidget {
  const GradientButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.loading = false,
    this.height = 56,
    this.gradient = kBrandGradient,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final bool loading;
  final double height;
  final Gradient gradient;

  @override
  Widget build(BuildContext context) {
    final enabled = onPressed != null && !loading;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 200),
      opacity: enabled || loading ? 1 : 0.55,
      child: Container(
        height: height,
        decoration: BoxDecoration(
          gradient: gradient,
          borderRadius: BorderRadius.circular(16),
          boxShadow: <BoxShadow>[
            BoxShadow(
              color: AppConstants.primaryColor.withValues(
                alpha: enabled ? 0.35 : 0.1,
              ),
              blurRadius: 18,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(16),
          child: InkWell(
            borderRadius: BorderRadius.circular(16),
            onTap: enabled ? onPressed : null,
            child: Center(
              child: loading
                  ? const DotsLoader()
                  : Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        if (icon != null) ...<Widget>[
                          Icon(icon, color: Colors.white, size: 21),
                          const SizedBox(width: 10),
                        ],
                        Flexible(
                          child: Text(
                            label,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 16,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.1,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal bar showing a probability (0–100).
class ProbabilityBar extends StatelessWidget {
  const ProbabilityBar({
    super.key,
    required this.value,
    this.color = AppConstants.primaryColor,
  });

  final int value;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Stack(
        children: <Widget>[
          Container(height: 8, color: color.withValues(alpha: 0.12)),
          FractionallySizedBox(
            widthFactor: (value.clamp(0, 100)) / 100,
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: <Color>[color.withValues(alpha: 0.75), color],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Bullet list used in AI answers / tips.
class BulletList extends StatelessWidget {
  const BulletList({
    super.key,
    required this.items,
    this.icon = Icons.check_circle_rounded,
    this.color = AppConstants.successColor,
  });

  final List<String> items;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: items
          .map(
            (t) => Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Padding(
                    padding: const EdgeInsets.only(top: 2),
                    child: Icon(icon, size: 16, color: color),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t,
                      style: const TextStyle(
                        fontSize: 13.5,
                        height: 1.4,
                        color: Color(0xFF334155),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          )
          .toList(),
    );
  }
}

/// Maps `issue_catalog.icon` names to Material icons (kept as constants so
/// icon tree-shaking still works).
IconData issueIcon(String? name) {
  switch (name) {
    case 'tire_repair':
      return Icons.tire_repair_rounded;
    case 'power_settings_new':
      return Icons.power_settings_new_rounded;
    case 'battery_alert':
      return Icons.battery_alert_rounded;
    case 'settings':
      return Icons.settings_rounded;
    case 'thermostat':
      return Icons.thermostat_rounded;
    case 'local_gas_station':
      return Icons.local_gas_station_rounded;
    case 'electrical_services':
      return Icons.electrical_services_rounded;
    case 'tune':
      return Icons.tune_rounded;
    case 'graphic_eq':
      return Icons.graphic_eq_rounded;
    case 'water_drop':
      return Icons.water_drop_rounded;
    case 'key':
      return Icons.key_rounded;
    case 'car_crash':
      return Icons.car_crash_rounded;
    default:
      return Icons.more_horiz_rounded;
  }
}

/// Icon for a fallback chip label (when the catalog could not be loaded).
IconData issueIconForLabel(String label) {
  const map = <String, String>{
    'Puncture / Tyre Flat': 'tire_repair',
    "Won't Start": 'power_settings_new',
    'Battery Dead': 'battery_alert',
    'Chain / Brake': 'settings',
    'Overheating': 'thermostat',
    'Fuel Problem': 'local_gas_station',
    'Lights / Electrical': 'electrical_services',
    'Clutch / Gear': 'tune',
    'Strange Noise': 'graphic_eq',
    'Oil / Fluid Leak': 'water_drop',
    'Key Lost / Lockout': 'key',
    'Accident / Towing': 'car_crash',
  };
  return issueIcon(map[label]);
}

/// Colour for an urgency level from the AI.
Color urgencyColor(String urgency) {
  switch (urgency) {
    case 'emergency':
      return const Color(0xFFDC2626);
    case 'high':
      return const Color(0xFFEA580C);
    case 'low':
      return AppConstants.successColor;
    default:
      return AppConstants.warningColor;
  }
}

String formatInr(int amount) {
  final s = amount.toString();
  if (s.length <= 3) return '₹$s';
  final last3 = s.substring(s.length - 3);
  var rest = s.substring(0, s.length - 3);
  final parts = <String>[];
  while (rest.length > 2) {
    parts.insert(0, rest.substring(rest.length - 2));
    rest = rest.substring(0, rest.length - 2);
  }
  if (rest.isNotEmpty) parts.insert(0, rest);
  return '₹${parts.join(',')},$last3';
}
