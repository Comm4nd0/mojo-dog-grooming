import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// Basic invoicing. Hidden from clients until the setting is switched on.
class InvoicesScreen extends StatefulWidget {
  const InvoicesScreen({super.key});

  @override
  State<InvoicesScreen> createState() => _InvoicesScreenState();
}

class _InvoicesScreenState extends State<InvoicesScreen> {
  final _data = getIt<DataService>();
  List<Invoice> _invoices = const [];
  AppSettings? _settings;
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    try {
      final invoices = await _data.getInvoices();
      final settings = await _data.getSettings();
      if (!mounted) return;
      setState(() {
        _invoices = invoices;
        _settings = settings;
        _loading = false;
        _error = null;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _newInvoice() async {
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(builder: (_) => const _InvoiceFormScreen()),
    );
    if (saved == true) _load();
  }

  @override
  Widget build(BuildContext context) {
    final visible = _settings?.invoicingVisibleToClients ?? false;
    return Scaffold(
      appBar: AppBar(title: const Text('Invoices')),
      floatingActionButton: FloatingActionButton(
        onPressed: _newInvoice,
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? ErrorRetry(error: _error!, onRetry: _load)
              : Column(
                  children: [
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      color: (visible ? AppColors.success : context.mojo.muted)
                          .withValues(alpha: 0.08),
                      child: Row(
                        children: [
                          Icon(
                            visible ? Icons.visibility_outlined : Icons.visibility_off_outlined,
                            size: 18,
                            color: visible ? AppColors.success : context.mojo.muted,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              visible
                                  ? 'Clients can see their own invoices.'
                                  : 'Invoices are hidden from clients. Turn this on in Settings.',
                              style: const TextStyle(fontSize: 12.5),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: _invoices.isEmpty
                          ? EmptyState(
                              icon: Icons.receipt_long_outlined,
                              title: 'No invoices yet',
                              action: ElevatedButton(
                                onPressed: _newInvoice,
                                child: const Text('RAISE AN INVOICE'),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.only(bottom: 88),
                              itemCount: _invoices.length,
                              separatorBuilder: (_, _) => const Divider(height: 1),
                              itemBuilder: (context, index) {
                                final invoice = _invoices[index];
                                return ListTile(
                                  title: Text('${invoice.number} — ${invoice.clientName}'),
                                  subtitle: Text(
                                    '${invoice.issueDate == null ? '' : '${formatDate(invoice.issueDate!)} · '}'
                                    '${invoice.lines.length} line${invoice.lines.length == 1 ? '' : 's'}',
                                  ),
                                  trailing: Column(
                                    mainAxisAlignment: MainAxisAlignment.center,
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        formatMoney(invoice.total),
                                        style: const TextStyle(fontWeight: FontWeight.w700),
                                      ),
                                      const SizedBox(height: 2),
                                      InfoTag(
                                        label: invoice.status,
                                        color: switch (invoice.status) {
                                          'PAID' => AppColors.success,
                                          'VOID' => context.mojo.muted,
                                          'SENT' => AppColors.warning,
                                          _ => context.mojo.muted,
                                        },
                                      ),
                                    ],
                                  ),
                                  onTap: () => _showActions(invoice),
                                );
                              },
                            ),
                    ),
                  ],
                ),
    );
  }

  void _showActions(Invoice invoice) {
    showModalBottomSheet<void>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(invoice.number, style: Theme.of(context).textTheme.titleMedium),
              subtitle: Text(
                '${invoice.clientName} · ${formatMoney(invoice.total)} · '
                'balance ${formatMoney(invoice.balance)}',
              ),
            ),
            const Divider(height: 1),
            for (final line in invoice.lines)
              ListTile(
                dense: true,
                title: Text(line.description),
                // The quantity and unit price were dropped here, so a line
                // reading "£15.00" gave no clue it was two nail trims at
                // £7.50. Only shown when there is more than one — "1 × £50.00"
                // is noise.
                subtitle: line.quantity == 1
                    ? null
                    : Text('${_qty(line.quantity)} × ${formatMoney(line.unitPrice)}'),
                trailing: Text(formatMoney(line.lineTotal)),
              ),
            const Divider(height: 1),
            // Sent before paid: that is the order the paperwork happens in,
            // and having them the other way round meant reaching past the
            // destructive-feeling one every time.
            if (invoice.status != 'PAID' && invoice.status != 'VOID')
              ListTile(
                leading: Icon(Icons.send_outlined, color: context.mojo.accent),
                title: const Text('Mark as sent'),
                onTap: () async {
                  Navigator.pop(context);
                  await _run(() => _data.markInvoiceSent(invoice.id), 'Marked sent.');
                },
              ),
            if (invoice.balance > 0 && invoice.status != 'VOID')
              ListTile(
                leading: Icon(Icons.payments_outlined, color: context.mojo.accent),
                title: const Text('Record payment'),
                subtitle: Text('${formatMoney(invoice.balance)} outstanding'),
                onTap: () async {
                  Navigator.pop(context);
                  await _recordPayment(invoice);
                },
              ),
            // A draft is not a record of anything yet, so one raised by
            // mistake can go. Past that the number has been quoted to
            // somebody and is unique, so it is voided instead — deleting
            // would free the number for a later invoice with a different
            // total. The server enforces both.
            if (invoice.status == 'DRAFT')
              ListTile(
                leading: const Icon(Icons.delete_outline, color: AppColors.error),
                title: const Text('Delete', style: TextStyle(color: AppColors.error)),
                subtitle: const Text('Only while it is a draft'),
                onTap: () async {
                  Navigator.pop(context);
                  await _delete(invoice);
                },
              )
            else if (invoice.status != 'VOID')
              ListTile(
                leading: Icon(Icons.block_outlined, color: context.mojo.muted),
                title: const Text('Void'),
                subtitle: const Text('Keeps the number used up'),
                onTap: () async {
                  Navigator.pop(context);
                  await _run(
                    () => _data.updateInvoice(invoice.id, {'status': 'VOID'}),
                    'Voided.',
                  );
                },
              ),
          ],
        ),
      ),
    );
  }

  /// Runs an invoice action, surfacing whatever the server says if it refuses.
  ///
  /// The refusals are the point: marking a paid invoice sent, or deleting one
  /// that has gone out, both come back as a 409 with a sentence explaining
  /// why, and that sentence is more use than "something went wrong".
  Future<void> _run(Future<void> Function() action, String done) async {
    try {
      await action();
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
      return;
    }
    if (mounted) showSnack(context, done);
    _load();
  }

  Future<void> _delete(Invoice invoice) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Delete ${invoice.number}?'),
        content: const Text(
          'It is still a draft, so nothing has been sent to anyone. This '
          'cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('KEEP IT'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: TextButton.styleFrom(foregroundColor: AppColors.error),
            child: const Text('DELETE'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run(() => _data.deleteInvoice(invoice.id), 'Deleted.');
  }

  /// Renders a line quantity without a pointless `.00`.
  static String _qty(num quantity) =>
      quantity == quantity.roundToDouble() ? quantity.round().toString() : quantity.toString();

  /// Takes payment, asking how it was paid.
  ///
  /// It used to post the full balance as a card payment without asking, so
  /// every invoice in the books said CARD whether it was cash in hand or a
  /// bank transfer. `Payment.method` has always been there; nothing filled it
  /// in.
  Future<void> _recordPayment(Invoice invoice) async {
    const methods = {
      'CASH': ('Cash', Icons.payments_outlined),
      'CARD': ('Card', Icons.credit_card),
      'BANK': ('Bank transfer', Icons.account_balance_outlined),
      'OTHER': ('Something else', Icons.more_horiz),
    };

    final method = await showModalBottomSheet<String>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              title: Text(
                'How was ${formatMoney(invoice.balance)} paid?',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
              subtitle: Text(invoice.clientName),
            ),
            const Divider(height: 1),
            for (final entry in methods.entries)
              ListTile(
                leading: Icon(entry.value.$2, color: sheetContext.mojo.accent),
                title: Text(entry.value.$1),
                onTap: () => Navigator.pop(sheetContext, entry.key),
              ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
    if (method == null) return;

    // One call: the server writes the payment and closes the invoice in a
    // single transaction, so a failure halfway can't leave a payment recorded
    // against an invoice still showing as unpaid.
    await _run(
      () => _data.markInvoicePaid(invoice.id, method: method),
      'Marked paid — ${methods[method]!.$1.toLowerCase()}.',
    );
  }
}

class _InvoiceFormScreen extends StatefulWidget {
  const _InvoiceFormScreen();

  @override
  State<_InvoiceFormScreen> createState() => _InvoiceFormScreenState();
}

class _InvoiceFormScreenState extends State<_InvoiceFormScreen> {
  final _data = getIt<DataService>();
  final _number = TextEditingController();

  List<ClientRecord> _clients = const [];
  List<Appointment> _recent = const [];
  int? _clientId;
  final List<InvoiceLine> _lines = [];
  bool _loading = true;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _number.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final clients = await _data.getClients();
      final recent = await _data.getAppointments(
        from: DateTime.now().subtract(const Duration(days: 90)),
        to: DateTime.now(),
      );
      if (!mounted) return;
      setState(() {
        _clients = clients;
        _recent = recent.where((a) => a.status == 'COMPLETED').toList();
        _loading = false;
        // Deliberately left blank. This used to be
        // 'INV-${millisecondsSinceEpoch % 100000}' — sequential-*looking* and
        // nothing more: it did not sort, could not be read down a phone, and
        // modulo a timestamp it could collide with an existing number and fail
        // the unique constraint in front of Jess. The server allocates the
        // real next number when this is empty.
      });
    } catch (error) {
      if (!mounted) return;
      setState(() => _loading = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  /// Completed grooms for the chosen client, offered as one-tap invoice lines.
  List<Appointment> get _billable =>
      _recent.where((a) => a.clientId == _clientId).toList();

  Future<void> _save() async {
    if (_clientId == null || _lines.isEmpty) {
      showSnack(context, 'Choose a client and add at least one line.', isError: true);
      return;
    }
    setState(() => _busy = true);
    try {
      await _data.createInvoice(
        clientId: _clientId!,
        number: _number.text.trim(),
        lines: _lines,
      );
      if (mounted) Navigator.pop(context, true);
    } catch (error) {
      if (!mounted) return;
      setState(() => _busy = false);
      showSnack(context, error.toString(), isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: AppBar(title: const Text('New invoice')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    final total = _lines.fold<num>(0, (sum, line) => sum + line.lineTotal);

    return Scaffold(
      appBar: AppBar(title: const Text('New invoice')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 40),
        children: [
          DropdownButtonFormField<int>(
            initialValue: _clientId,
            decoration: const InputDecoration(labelText: 'Client *'),
            isExpanded: true,
            items: [
              for (final client in _clients)
                DropdownMenuItem(
                  value: client.id,
                  child: Text('${client.fullName} (${client.uid})',
                      overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: (value) => setState(() {
              _clientId = value;
              _lines.clear();
            }),
          ),
          const SizedBox(height: 14),
          MojoTextField(
            controller: _number,
            decoration: const InputDecoration(
              labelText: 'Invoice number',
              hintText: 'Leave blank for the next one',
              helperText: 'Only fill this in to match a number you have already written down',
            ),
          ),

          if (_clientId != null && _billable.isNotEmpty) ...[
            const SectionHeader(title: 'Recent completed grooms'),
            for (final appointment in _billable)
              ListTile(
                dense: true,
                title: Text('${appointment.dogName} — ${formatDate(appointment.startAt)}'),
                trailing: Text(formatMoney(appointment.priceQuoted ?? 0)),
                leading: Icon(Icons.add_circle_outline, color: context.mojo.accent),
                onTap: () => setState(() {
                  _lines.add(InvoiceLine(
                    description: '${appointment.dogName} groom, '
                        '${formatDate(appointment.startAt)}',
                    quantity: 1,
                    unitPrice: appointment.priceQuoted ?? 0,
                    lineTotal: appointment.priceQuoted ?? 0,
                  ));
                }),
              ),
          ],

          SectionHeader(
            title: 'Lines',
            action: TextButton.icon(
              onPressed: _addCustomLine,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('ADD'),
            ),
          ),
          if (_lines.isEmpty)
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                'No lines yet.',
                style: TextStyle(color: context.mojo.muted, fontSize: 13),
              ),
            )
          else
            for (int index = 0; index < _lines.length; index++)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(_lines[index].description),
                subtitle: Text(
                  '${_lines[index].quantity} × ${formatMoney(_lines[index].unitPrice)}',
                ),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(formatMoney(_lines[index].lineTotal)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () => setState(() => _lines.removeAt(index)),
                    ),
                  ],
                ),
              ),

          const Divider(height: 32),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text('Total', style: Theme.of(context).textTheme.titleLarge),
              Text(formatMoney(total), style: AppColors.display(24)),
            ],
          ),
          const SizedBox(height: 28),
          ElevatedButton(
            onPressed: _busy ? null : _save,
            child: Text(_busy ? 'SAVING…' : 'CREATE INVOICE'),
          ),
        ],
      ),
    );
  }

  Future<void> _addCustomLine() async {
    final description = TextEditingController();
    final price = TextEditingController();
    final added = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a line'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            MojoTextField(
              controller: description,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Description'),
              textCapitalization: TextCapitalization.sentences,
            ),
            const SizedBox(height: 12),
            MojoTextField(
              controller: price,
              decoration: const InputDecoration(labelText: 'Price (£)'),
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('CANCEL')),
          ElevatedButton(onPressed: () => Navigator.pop(context, true), child: const Text('ADD')),
        ],
      ),
    );
    if (added == true && description.text.trim().isNotEmpty) {
      final unitPrice = num.tryParse(price.text.trim()) ?? 0;
      setState(() {
        _lines.add(InvoiceLine(
          description: description.text.trim(),
          quantity: 1,
          unitPrice: unitPrice,
          lineTotal: unitPrice,
        ));
      });
    }
    description.dispose();
    price.dispose();
  }
}
