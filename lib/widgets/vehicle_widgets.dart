import 'package:material_ui/material_ui.dart';

import '../core/constants/app_constants.dart';
import '../models/customer_vehicle.dart';

/// Vehicle illustration from `assets/vehicles/` with a safe fallback.
class VehicleImage extends StatelessWidget {
  const VehicleImage({super.key, required this.asset, this.height = 64});

  final String asset;
  final double height;

  @override
  Widget build(BuildContext context) {
    return Image.asset(
      asset,
      height: height,
      fit: BoxFit.contain,
      filterQuality: FilterQuality.medium,
      errorBuilder: (_, _, _) => SizedBox(
        height: height,
        child: Icon(
          Icons.directions_car_filled_rounded,
          size: height * 0.6,
          color: Colors.blueGrey.shade300,
        ),
      ),
    );
  }
}

/// Selectable card for one saved vehicle (horizontal list on Home).
class SavedVehicleCard extends StatelessWidget {
  const SavedVehicleCard({
    super.key,
    required this.vehicle,
    required this.selected,
    required this.onTap,
    this.feeLabel,
  });

  final CustomerVehicle vehicle;
  final bool selected;
  final VoidCallback onTap;
  final String? feeLabel;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      selected: selected,
      button: true,
      label: '${vehicle.name}, ${vehicle.subtitle}',
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          width: 150,
          padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
          decoration: BoxDecoration(
            color: selected
                ? AppConstants.primaryColor.withValues(alpha: 0.08)
                : Colors.white,
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: selected ? AppConstants.primaryColor : Colors.grey.shade300,
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Stack(
                children: <Widget>[
                  Center(child: VehicleImage(asset: vehicle.asset, height: 58)),
                  if (selected)
                    const Positioned(
                      right: 0,
                      top: 0,
                      child: Icon(
                        Icons.check_circle_rounded,
                        color: AppConstants.primaryColor,
                        size: 20,
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                vehicle.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  fontSize: 13.5,
                  color: AppConstants.secondaryDarkColor,
                ),
              ),
              Text(
                feeLabel ?? vehicle.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 11.5, color: Colors.blueGrey.shade600),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dashed "+ Add vehicle" tile.
class AddVehicleTile extends StatelessWidget {
  const AddVehicleTile({super.key, required this.onTap, this.large = false});

  final VoidCallback onTap;
  final bool large;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(18),
      onTap: onTap,
      child: Container(
        width: large ? double.infinity : 120,
        padding: EdgeInsets.symmetric(horizontal: 12, vertical: large ? 18 : 10),
        decoration: BoxDecoration(
          color: AppConstants.backgroundColor,
          borderRadius: BorderRadius.circular(18),
          border: Border.all(color: AppConstants.primaryColor.withValues(alpha: 0.45), width: 1.4),
        ),
        child: large
            ? const Row(
                children: <Widget>[
                  CircleAvatar(
                    radius: 22,
                    backgroundColor: AppConstants.primaryColor,
                    child: Icon(Icons.add_rounded, color: Colors.white),
                  ),
                  SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Add your vehicle',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            fontSize: 15,
                            color: AppConstants.secondaryDarkColor,
                          ),
                        ),
                        SizedBox(height: 2),
                        Text(
                          'Pick brand & model so the mechanic brings the right tools',
                          style: TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded),
                ],
              )
            : const Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: <Widget>[
                  Icon(Icons.add_circle_outline_rounded, color: AppConstants.primaryColor, size: 30),
                  SizedBox(height: 6),
                  Text(
                    'Add vehicle',
                    style: TextStyle(fontWeight: FontWeight.w600, color: AppConstants.primaryColor),
                  ),
                ],
              ),
      ),
    );
  }
}
