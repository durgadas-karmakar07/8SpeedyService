import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/vehicle_catalog.dart';
import '../../core/utils/error_helper.dart';
import '../../models/customer_vehicle.dart';
import '../../services/vehicle_service.dart';
import '../../widgets/vehicle_widgets.dart';
import '../../widgets/speedy_loader.dart';

/// 4 steps: Type -> Brand -> Model -> Number & fuel. Returns the saved
/// [CustomerVehicle] via `Navigator.pop`.
class AddVehicleScreen extends StatefulWidget {
  const AddVehicleScreen({super.key});

  @override
  State<AddVehicleScreen> createState() => _AddVehicleScreenState();
}

class _AddVehicleScreenState extends State<AddVehicleScreen> {
  final VehicleService _service = VehicleService();
  final TextEditingController _search = TextEditingController();
  final TextEditingController _customModel = TextEditingController();
  final TextEditingController _reg = TextEditingController();

  int _step = 0;
  BodyType? _body;
  String? _brand;
  String? _model;
  String? _fuel;
  bool _saving = false;
  String? _regError;

  static const List<String> _titles = <String>[
    'Vehicle type',
    'Select brand',
    'Select model',
    'Vehicle details',
  ];

  @override
  void dispose() {
    _search.dispose();
    _customModel.dispose();
    _reg.dispose();
    super.dispose();
  }

  void _goTo(int step) {
    _search.clear();
    FocusScope.of(context).unfocus();
    setState(() => _step = step);
  }

  void _back() {
    if (_step == 0) {
      Navigator.of(context).pop();
    } else {
      _goTo(_step - 1);
    }
  }

  Future<void> _askCustom({required bool brand}) async {
    var typed = '';
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(brand ? 'Brand name' : 'Model name'),
        content: TextField(
          autofocus: true,
          maxLength: brand ? 40 : 60,
          textCapitalization: TextCapitalization.words,
          decoration: InputDecoration(
            hintText: brand ? 'E.g. Kinetic' : 'E.g. Activa 5G',
            counterText: '',
          ),
          onChanged: (v) => typed = v,
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: <Widget>[
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, typed),
            child: const Text('Next'),
          ),
        ],
      ),
    );
    final v = value?.trim() ?? '';
    if (v.length < 2 || !mounted) return;
    if (brand) {
      setState(() => _brand = v);
      _goTo(2);
    } else {
      setState(() => _model = v);
      _goTo(3);
    }
  }

  Future<void> _save() async {
    final body = _body;
    if (body == null || _brand == null || _model == null) return;
    final reg = _reg.text.replaceAll(RegExp(r'[^A-Za-z0-9]'), '').toUpperCase();
    if (reg.isNotEmpty &&
        !RegExp(r'^([A-Z]{2}\d{1,2}[A-Z]{0,3}\d{1,4}|\d{2}BH\d{4}[A-Z]{1,2})$').hasMatch(reg)) {
      setState(() => _regError = 'Please enter a valid number, e.g. WB 38 AB 1234');
      return;
    }
    setState(() {
      _saving = true;
      _regError = null;
    });
    try {
      final saved = await _service.saveVehicle(
        bodyType: body.key,
        brand: _brand!,
        model: _model!,
        regNumber: reg.isEmpty ? null : reg,
        fuelType: body.hasFuel ? _fuel : null,
      );
      if (!mounted) return;
      Navigator.of(context).pop<CustomerVehicle>(saved);
    } catch (e) {
      if (!mounted) return;
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(ErrorHelper.friendly(e, fallback: 'Could not save the vehicle. Please try again.'))),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _step == 0,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(icon: const Icon(Icons.arrow_back_rounded), onPressed: _back),
          title: Text(_titles[_step]),
          bottom: PreferredSize(
            preferredSize: const Size.fromHeight(4),
            child: LinearProgressIndicator(
              value: (_step + 1) / 4,
              minHeight: 4,
              backgroundColor: Colors.grey.shade200,
              color: AppConstants.primaryColor,
            ),
          ),
        ),
        body: SafeArea(
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: KeyedSubtree(
              key: ValueKey<int>(_step),
              child: switch (_step) {
                0 => _typeStep(),
                1 => _listStep(brand: true),
                2 => _listStep(brand: false),
                _ => _detailsStep(),
              },
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 1: type grid
  // ---------------------------------------------------------------------------

  Widget _typeStep() {
    return GridView.builder(
      padding: const EdgeInsets.all(16),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 12,
        crossAxisSpacing: 12,
        childAspectRatio: 1.05,
      ),
      itemCount: VehicleCatalog.bodyTypes.length,
      itemBuilder: (context, i) {
        final b = VehicleCatalog.bodyTypes[i];
        final selected = _body?.key == b.key;
        return InkWell(
          borderRadius: BorderRadius.circular(18),
          onTap: () {
            setState(() {
              if (_body?.key != b.key) {
                _brand = null;
                _model = null;
                _fuel = null;
              }
              _body = b;
            });
            _goTo(1);
          },
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(18),
              border: Border.all(
                color: selected ? AppConstants.primaryColor : Colors.grey.shade200,
                width: selected ? 2 : 1,
              ),
              boxShadow: const <BoxShadow>[
                BoxShadow(color: Color(0x0F000000), blurRadius: 8, offset: Offset(0, 2)),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Expanded(child: VehicleImage(asset: b.asset, height: 90)),
                Text(
                  b.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 14.5,
                    color: AppConstants.secondaryDarkColor,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  b.subtitle,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 11.5, color: Colors.blueGrey.shade600),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Steps 2 & 3: searchable brand / model list
  // ---------------------------------------------------------------------------

  Widget _listStep({required bool brand}) {
    final body = _body!;
    final all = brand
        ? body.brands.keys.toList()
        : (body.brands[_brand] ?? const <String>[]);
    final q = _search.text.trim().toLowerCase();
    final items = q.isEmpty ? all : all.where((e) => e.toLowerCase().contains(q)).toList();

    return Column(
      children: <Widget>[
        _selectionHeader(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              hintText: brand ? 'Search brand' : 'Search model',
              prefixIcon: const Icon(Icons.search_rounded),
              isDense: true,
              filled: true,
              fillColor: Colors.white,
              border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
            ),
          ),
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            children: <Widget>[
              ...items.map(
                (name) => Card(
                  elevation: 0,
                  color: Colors.white,
                  margin: const EdgeInsets.only(bottom: 8),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                    side: BorderSide(color: Colors.grey.shade200),
                  ),
                  child: ListTile(
                    title: Text(name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    trailing: const Icon(Icons.chevron_right_rounded),
                    onTap: () {
                      if (brand) {
                        setState(() {
                          if (_brand != name) _model = null;
                          _brand = name;
                        });
                        _goTo(2);
                      } else {
                        setState(() => _model = name);
                        _goTo(3);
                      }
                    },
                  ),
                ),
              ),
              Card(
                elevation: 0,
                color: AppConstants.backgroundColor,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(14),
                  side: BorderSide(color: AppConstants.primaryColor.withValues(alpha: 0.4)),
                ),
                child: ListTile(
                  leading: const Icon(Icons.edit_rounded, color: AppConstants.primaryColor),
                  title: Text(
                    brand ? 'My brand is not listed' : 'My model is not listed',
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  onTap: () => _askCustom(brand: brand),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _selectionHeader() {
    final body = _body!;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: <Widget>[
          SizedBox(width: 80, child: VehicleImage(asset: body.asset, height: 48)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(body.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                if (_brand != null)
                  Text(
                    _model == null ? _brand! : '$_brand $_model',
                    style: TextStyle(color: Colors.blueGrey.shade600, fontSize: 12.5),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Step 4: number plate + fuel
  // ---------------------------------------------------------------------------

  Widget _detailsStep() {
    final body = _body!;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: <Widget>[
              VehicleImage(asset: body.asset, height: 130),
              const SizedBox(height: 8),
              Text(
                '$_brand $_model',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  color: AppConstants.secondaryDarkColor,
                ),
              ),
              Text(body.title, style: TextStyle(color: Colors.blueGrey.shade600)),
            ],
          ),
        ),
        const SizedBox(height: 20),
        const Text('Vehicle number (optional)', style: TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        TextField(
          controller: _reg,
          enabled: !_saving,
          maxLength: 14,
          textCapitalization: TextCapitalization.characters,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.allow(RegExp(r'[A-Za-z0-9 ]')),
            TextInputFormatter.withFunction(
              (oldV, newV) => newV.copyWith(text: newV.text.toUpperCase()),
            ),
          ],
          style: const TextStyle(fontWeight: FontWeight.w700, letterSpacing: 1.5, fontSize: 17),
          decoration: InputDecoration(
            hintText: 'WB 38 AB 1234',
            counterText: '',
            errorText: _regError,
            prefixIcon: const Icon(Icons.pin_outlined),
            filled: true,
            fillColor: Colors.white,
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
          ),
        ),
        Text(
          'Helps the mechanic find your vehicle. Shown only after a mechanic accepts.',
          style: TextStyle(fontSize: 12, color: Colors.blueGrey.shade600),
        ),
        if (body.hasFuel) ...<Widget>[
          const SizedBox(height: 20),
          const Text('Fuel (optional)', style: TextStyle(fontWeight: FontWeight.w700)),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: VehicleCatalog.fuels
                .map(
                  (f) => ChoiceChip(
                    label: Text(f.label),
                    selected: _fuel == f.key,
                    onSelected: _saving
                        ? null
                        : (on) => setState(() => _fuel = on ? f.key : null),
                  ),
                )
                .toList(),
          ),
        ],
        const SizedBox(height: 28),
        SizedBox(
          height: 54,
          child: FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const DotsLoader()
                : const Icon(Icons.check_rounded),
            label: const Text('Save vehicle', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          ),
        ),
      ],
    );
  }
}
