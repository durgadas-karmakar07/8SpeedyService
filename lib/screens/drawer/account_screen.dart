import 'package:material_ui/material_ui.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/constants/app_constants.dart';
import '../../core/constants/legal_content.dart';
import '../../core/utils/error_helper.dart';
import '../../models/customer_model.dart';
import '../../services/auth_service.dart';
import '../3_phone_login_screen.dart';
import 'legal_screen.dart';

/// Profile name, legal links and permanent account deletion.
class AccountScreen extends StatefulWidget {
  const AccountScreen({super.key});

  @override
  State<AccountScreen> createState() => _AccountScreenState();
}

class _AccountScreenState extends State<AccountScreen> {
  final AuthService _auth = AuthService();
  final TextEditingController _name = TextEditingController();
  CustomerModel? _customer;
  bool _loading = true;
  bool _savingName = false;
  bool _deleting = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final c = await _auth.fetchCustomerProfile();
      if (!mounted) return;
      setState(() {
        _customer = c;
        final n = c?.fullName ?? '';
        _name.text = n == '8Speedy User' ? '' : n;
        _loading = false;
      });
    } catch (_) {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _saveName() async {
    final name = _name.text.trim();
    if (name.length < 2 || name.length > 50) {
      _snack('Name must be 2 to 50 characters.');
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _savingName = true);
    try {
      await _auth.updateCustomerName(name);
      _snack('Name saved. Your mechanic will see this name.');
    } catch (e) {
      _snack(ErrorHelper.friendly(e));
    } finally {
      if (mounted) setState(() => _savingName = false);
    }
  }

  Future<void> _open(String url) async {
    final ok = await launchUrl(Uri.parse(url), mode: LaunchMode.externalApplication);
    if (!ok) _snack('Could not open the link.');
  }

  void _openDoc(LegalDoc doc) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => LegalScreen(doc: doc)),
    );
  }

  Future<void> _confirmDelete() async {
    var understood = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          icon: const Icon(Icons.warning_amber_rounded, color: Colors.red, size: 36),
          title: const Text('Delete your account?'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              const Text(
                '• Your name, phone number, saved vehicles and remaining free credits will be removed permanently.\n'
                '• Past booking records are kept without your identity for payment and tax purposes.\n'
                '• This cannot be undone.',
                style: TextStyle(height: 1.45, fontSize: 13.5),
              ),
              const SizedBox(height: 8),
              CheckboxListTile(
                value: understood,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                onChanged: (v) => setLocal(() => understood = v ?? false),
                title: const Text('I understand', style: TextStyle(fontSize: 13.5)),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(
              style: FilledButton.styleFrom(backgroundColor: Colors.red),
              onPressed: understood ? () => Navigator.pop(ctx, true) : null,
              child: const Text('Delete'),
            ),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;

    setState(() => _deleting = true);
    try {
      await _auth.deleteAccount();
      if (!mounted) return;
      await Navigator.of(context).pushAndRemoveUntil(
        MaterialPageRoute<void>(builder: (_) => const PhoneLoginScreen()),
        (_) => false,
      );
    } catch (e) {
      if (!mounted) return;
      setState(() => _deleting = false);
      _snack(ErrorHelper.friendly(e, fallback: 'Could not delete the account. Please try again.'));
    }
  }

  void _snack(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(text)));
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Account & Privacy')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                _section('Profile'),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: _card(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      TextField(
                        controller: _name,
                        enabled: !_savingName,
                        maxLength: 50,
                        textCapitalization: TextCapitalization.words,
                        decoration: InputDecoration(
                          labelText: 'Your name',
                          hintText: 'Your mechanic will see this name',
                          counterText: '',
                          prefixIcon: const Icon(Icons.person_outline_rounded),
                          border: OutlineInputBorder(borderRadius: BorderRadius.circular(14)),
                        ),
                      ),
                      const SizedBox(height: 10),
                      Row(
                        children: <Widget>[
                          const Icon(Icons.phone_rounded, size: 18, color: Colors.blueGrey),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              _customer?.phone ?? _auth.currentUser?.phone ?? '',
                              style: TextStyle(color: Colors.blueGrey.shade700),
                            ),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(minimumSize: const Size(96, 42)),
                            onPressed: _savingName ? null : _saveName,
                            child: _savingName
                                ? const SizedBox(
                                    width: 18,
                                    height: 18,
                                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                                  )
                                : const Text('Save'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _section('Legal & help'),
                Container(
                  decoration: _card(),
                  child: Column(
                    children: <Widget>[
                      _link(Icons.privacy_tip_outlined, 'Privacy Policy', () => _openDoc(LegalContent.privacy)),
                      const Divider(height: 1),
                      _link(Icons.description_outlined, 'Terms of Service', () => _openDoc(LegalContent.terms)),
                      const Divider(height: 1),
                      _link(Icons.support_agent_rounded, 'WhatsApp Support (${AppConstants.supportPhoneDisplay})', () => _open(AppConstants.whatsappSupportUrl), external: true),
                    ],
                  ),
                ),
                const SizedBox(height: 20),
                _section('Danger zone'),
                Container(
                  decoration: _card(),
                  child: ListTile(
                    leading: _deleting
                        ? const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5))
                        : const Icon(Icons.delete_forever_rounded, color: Colors.red),
                    title: const Text('Delete my account', style: TextStyle(color: Colors.red, fontWeight: FontWeight.w600)),
                    subtitle: const Text('Permanently remove your account and personal data'),
                    onTap: _deleting ? null : _confirmDelete,
                  ),
                ),
                const SizedBox(height: 24),
                Center(
                  child: Text(
                    '${AppConstants.appName} v${AppConstants.appVersion}',
                    style: TextStyle(color: Colors.blueGrey.shade400, fontSize: 12),
                  ),
                ),
              ],
            ),
    );
  }

  Widget _section(String t) => Padding(
        padding: const EdgeInsets.only(left: 4, bottom: 8),
        child: Text(
          t.toUpperCase(),
          style: TextStyle(
            fontSize: 12,
            letterSpacing: 0.8,
            fontWeight: FontWeight.w700,
            color: Colors.blueGrey.shade500,
          ),
        ),
      );

  BoxDecoration _card() => BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
      );

  Widget _link(IconData icon, String title, VoidCallback onTap, {bool external = false}) => ListTile(
        leading: Icon(icon, color: AppConstants.secondaryDarkColor),
        title: Text(title),
        trailing: Icon(external ? Icons.open_in_new_rounded : Icons.chevron_right_rounded, size: 20),
        onTap: onTap,
      );
}
