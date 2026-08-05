import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../../services/api_client.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// Add or edit a client. The UID is Jess's own reference and stays editable.
class ClientFormScreen extends StatefulWidget {
  const ClientFormScreen({super.key, this.client});

  final ClientRecord? client;

  @override
  State<ClientFormScreen> createState() => _ClientFormScreenState();
}

class _ClientFormScreenState extends State<ClientFormScreen> {
  final _formKey = GlobalKey<FormState>();
  final _data = getIt<DataService>();

  late final TextEditingController _uid;
  late final TextEditingController _firstName;
  late final TextEditingController _lastName;
  late final TextEditingController _email;
  late final TextEditingController _phone;
  late final TextEditingController _address;
  late final TextEditingController _postcode;
  late final TextEditingController _emergencyName;
  late final TextEditingController _emergencyPhone;
  late final TextEditingController _notes;

  late bool _chatty;
  late bool _leafletReceived;
  late bool _particularAboutStandard;
  bool _busy = false;

  bool get _isEditing => widget.client != null;

  @override
  void initState() {
    super.initState();
    final client = widget.client;
    _uid = TextEditingController(text: client?.uid ?? '');
    _firstName = TextEditingController(text: client?.firstName ?? '');
    _lastName = TextEditingController(text: client?.lastName ?? '');
    _email = TextEditingController(text: client?.email ?? '');
    _phone = TextEditingController(text: client?.phone ?? '');
    _address = TextEditingController(text: client?.address ?? '');
    _postcode = TextEditingController(text: client?.postcode ?? '');
    _emergencyName = TextEditingController(text: client?.emergencyContactName ?? '');
    _emergencyPhone = TextEditingController(text: client?.emergencyContactPhone ?? '');
    _notes = TextEditingController(text: client?.notes ?? '');
    _chatty = client?.chatty ?? false;
    _leafletReceived = client?.leafletReceived ?? false;
    _particularAboutStandard = client?.particularAboutStandard ?? false;
  }

  @override
  void dispose() {
    for (final controller in [
      _uid, _firstName, _lastName, _email, _phone, _address, _postcode,
      _emergencyName, _emergencyPhone, _notes,
    ]) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _busy = true);
    final body = {
      'uid': _uid.text.trim(),
      'first_name': _firstName.text.trim(),
      'last_name': _lastName.text.trim(),
      'email': _email.text.trim(),
      'phone': _phone.text.trim(),
      'address': _address.text.trim(),
      'postcode': _postcode.text.trim(),
      'emergency_contact_name': _emergencyName.text.trim(),
      'emergency_contact_phone': _emergencyPhone.text.trim(),
      'chatty': _chatty,
      'particular_about_standard': _particularAboutStandard,
      'leaflet_received': _leafletReceived,
      'notes': _notes.text.trim(),
    };
    try {
      if (_isEditing) {
        await _data.updateClient(widget.client!.id, body);
      } else {
        await _data.createClient(body);
      }
      if (mounted) Navigator.of(context).pop(true);
    } on ApiException catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      // A duplicate UID is the likely failure — point at the right field.
      final uidError = error.fieldErrors['uid']?.first;
      showSnack(context, uidError ?? error.message, isError: true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_isEditing ? 'Edit client' : 'Add client')),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
          children: [
            MojoTextField(
              controller: _uid,
              decoration: const InputDecoration(
                labelText: 'Client UID *',
                helperText: 'Your own reference, e.g. MOJO-014',
              ),
              textCapitalization: TextCapitalization.characters,
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? 'Give this client a UID' : null,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _firstName,
              decoration: const InputDecoration(labelText: 'First name *'),
              textCapitalization: TextCapitalization.words,
              validator: (value) =>
                  (value == null || value.trim().isEmpty) ? 'Enter a first name' : null,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _lastName,
              decoration: const InputDecoration(labelText: 'Last name'),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _phone,
              decoration: const InputDecoration(labelText: 'Phone'),
              keyboardType: TextInputType.phone,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _email,
              decoration: const InputDecoration(labelText: 'Email'),
              keyboardType: TextInputType.emailAddress,
              validator: (value) => (value != null && value.isNotEmpty && !value.contains('@'))
                  ? 'That does not look like an email address'
                  : null,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _address,
              decoration: const InputDecoration(labelText: 'Address'),
              maxLines: 3,
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _postcode,
              decoration: const InputDecoration(labelText: 'Postcode'),
              textCapitalization: TextCapitalization.characters,
            ),

            // The paper booking card asks for an "additional contact name and
            // number (ICE)", and the intake form has always collected it — but
            // there was nowhere to type it in or read it back for a client Jess
            // adds herself.
            const SectionHeader(title: 'In an emergency'),
            MojoTextField(
              controller: _emergencyName,
              decoration: const InputDecoration(
                labelText: 'Who to contact',
                helperText: 'Someone other than them — a partner, a neighbour',
              ),
              textCapitalization: TextCapitalization.words,
            ),
            const SizedBox(height: 14),
            MojoTextField(
              controller: _emergencyPhone,
              decoration: const InputDecoration(labelText: 'Their number'),
              keyboardType: TextInputType.phone,
            ),

            const SectionHeader(title: 'Staff only'),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _chatty,
              onChanged: (value) => setState(() => _chatty = value),
              title: const Text('Chatty'),
              subtitle: const Text('Allow extra time at drop-off and collection'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _particularAboutStandard,
              onChanged: (value) => setState(() => _particularAboutStandard = value),
              title: const Text('Particular about groom standard'),
              subtitle: const Text('Check the finish over before they collect'),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              value: _leafletReceived,
              onChanged: (value) => setState(() => _leafletReceived = value),
              title: const Text('Leaflet received'),
            ),
            const SizedBox(height: 8),
            MojoTextField(
              controller: _notes,
              decoration: const InputDecoration(
                labelText: 'Private notes',
                helperText: 'Never shown to the client',
              ),
              maxLines: 4,
              textCapitalization: TextCapitalization.sentences,
            ),

            const SizedBox(height: 28),
            ElevatedButton(
              onPressed: _busy ? null : _save,
              child: Text(_busy ? 'SAVING…' : 'SAVE CLIENT'),
            ),
          ],
        ),
      ),
    );
  }
}
