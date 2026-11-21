import 'package:material_ui/material_ui.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/vehicle_catalog.dart';
import '../../core/utils/error_helper.dart';
import '../../models/customer_vehicle.dart';
import '../../services/vehicle_service.dart';
import '../../widgets/vehicle_widgets.dart';
import 'add_vehicle_screen.dart';
import '../../widgets/speedy_loader.dart';

/// Drawer -> My Vehicles: list, add and remove saved vehicles.
class MyVehiclesScreen extends StatefulWidget {
  const MyVehiclesScreen({super.key});

  @override
  State<MyVehiclesScreen> createState() => _MyVehiclesScreenState();
}

class _MyVehiclesScreenState extends State<MyVehiclesScreen> {
  final VehicleService _service = VehicleService();
  List<CustomerVehicle> _vehicles = const <CustomerVehicle>[];
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final list = await _service.fetchMyVehicles();
      if (!mounted) return;
      setState(() {
        _vehicles = list;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _error = ErrorHelper.friendly(e);
      });
    }
  }

  Future<void> _add() async {
    final added = await Navigator.of(context).push<CustomerVehicle>(
      MaterialPageRoute<CustomerVehicle>(
        builder: (_) => const AddVehicleScreen(),
      ),
    );
    if (added != null) _load();
  }

  Future<void> _delete(CustomerVehicle v) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove vehicle?'),
        content: Text(
          '${v.name} will be removed from your list. Past bookings are not affected.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _service.deleteVehicle(v.id);
      _load();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(ErrorHelper.friendly(e))));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Vehicles')),
      floatingActionButton: _vehicles.isEmpty
          ? null
          : FloatingActionButton.extended(
              onPressed: _add,
              backgroundColor: AppConstants.primaryColor,
              foregroundColor: Colors.white,
              icon: const Icon(Icons.add_rounded),
              label: const Text('Add vehicle'),
            ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
          children: <Widget>[
            if (_loading)
              const Padding(
                padding: EdgeInsets.all(48),
                child: Center(child: WheelLoader()),
              )
            else if (_error != null)
              Padding(
                padding: const EdgeInsets.all(24),
                child: Column(
                  children: <Widget>[
                    Text(_error!, textAlign: TextAlign.center),
                    const SizedBox(height: 12),
                    FilledButton(onPressed: _load, child: const Text('Retry')),
                  ],
                ),
              )
            else if (_vehicles.isEmpty) ...<Widget>[
              const SizedBox(height: 24),
              Center(
                child: VehicleImage(
                  asset: VehicleCatalog.bodyTypes.first.asset,
                  height: 120,
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'No vehicles saved yet',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 20),
              AddVehicleTile(onTap: _add, large: true),
            ] else
              ..._vehicles.map(
                (v) => Card(
                  elevation: 0,
                  color: Colors.white,
                  margin: const EdgeInsets.only(bottom: 10),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Row(
                      children: <Widget>[
                        SizedBox(
                          width: 96,
                          child: VehicleImage(asset: v.asset, height: 56),
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                v.name,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 15,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                v.subtitle,
                                style: TextStyle(
                                  color: Colors.blueGrey.shade600,
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: 'Remove',
                          icon: const Icon(Icons.delete_outline_rounded),
                          onPressed: () => _delete(v),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
