import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';
import '../../widgets/dog_silhouette.dart';

/// Review what comes in from the outside: intake forms and profile claims.
///
/// Neither creates anything by itself. An intake submission only becomes a
/// real client and dogs once Jess approves it and gives the client a UID, and
/// a claim only links a login to a client record once she confirms the match —
/// approving one grants access to that client's whole history.
class IntakeReviewScreen extends StatefulWidget {
  const IntakeReviewScreen({super.key});

  @override
  State<IntakeReviewScreen> createState() => _IntakeReviewScreenState();
}

class _IntakeReviewScreenState extends State<IntakeReviewScreen> {
  final _data = getIt<DataService>();

  List<IntakeSubmission> _submissions = const [];
  List<ClaimRequest> _claims = const [];
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
      final submissions = await _data.getIntakeSubmissions();
      final claims = await _data.getClaimRequests();
      if (!mounted) return;
      setState(() {
        _submissions = submissions;
        _claims = claims;
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

  @override
  Widget build(BuildContext context) {
    final pendingSubmissions =
        _submissions.where((s) => s.status == 'PENDING').toList();
    final pendingClaims = _claims.where((c) => c.status == 'PENDING').toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Intake'),
          bottom: TabBar(
            tabs: [
              Tab(text: 'Forms (${pendingSubmissions.length})'),
              Tab(text: 'Claims (${pendingClaims.length})'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? ErrorRetry(error: _error!, onRetry: _load)
                : TabBarView(
                    children: [
                      _submissionList(pendingSubmissions),
                      _claimList(pendingClaims),
                    ],
                  ),
      ),
    );
  }

  Widget _submissionList(List<IntakeSubmission> pending) {
    if (pending.isEmpty) {
      return const EmptyState(
        icon: Icons.assignment_turned_in_outlined,
        title: 'Nothing to review',
        message: 'Intake forms sent to new clients will land here.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: pending.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final submission = pending[index];
          return ExpansionTile(
            title: Text(submission.fullName),
            subtitle: Text(
              '${submission.dogs.length} dog${submission.dogs.length == 1 ? '' : 's'}'
              '${submission.createdAt == null ? '' : ' · ${formatDate(submission.createdAt!)}'}',
            ),
            children: [
              DetailRow(label: 'Email', value: submission.email),
              DetailRow(label: 'Phone', value: submission.phone),
              DetailRow(label: 'Postcode', value: submission.postcode),
              for (final dog in submission.dogs) _submittedDog(dog as Map<String, dynamic>),
              Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: () => _reject(submission),
                        child: const Text('REJECT'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: ElevatedButton(
                        onPressed: () => _approve(submission),
                        child: const Text('APPROVE'),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _submittedDog(Map<String, dynamic> dog) {
    final areas = (dog['problem_areas'] as List?) ?? const [];
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      padding: const EdgeInsets.all(12),
      color: AppColors.surfaceTint.withValues(alpha: 0.35),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(dog['name']?.toString() ?? 'Unnamed',
              style: Theme.of(context).textTheme.titleMedium),
          if ((dog['breed']?.toString() ?? '').isNotEmpty)
            Text(dog['breed'].toString(),
                style: Theme.of(context).textTheme.bodySmall),
          for (final key in ['pref_body', 'pref_feet', 'pref_tail', 'pref_face', 'pref_ears', 'pref_skirt'])
            if ((dog[key]?.toString() ?? '').isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('${_prefLabel(key)}: ${dog[key]}',
                    style: const TextStyle(fontSize: 12.5)),
              ),
          if (areas.isNotEmpty) ...[
            const SizedBox(height: 8),
            const Text('Problem areas',
                style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
            for (final area in areas)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    DogSilhouetteThumbnail(
                      cells: ((area as Map)['grid_cells'] as List?)
                              ?.map((c) => c.toString())
                              .toList() ??
                          const [],
                      size: 56,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(area['reason']?.toString() ?? '',
                          style: const TextStyle(fontSize: 12.5)),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  static String _prefLabel(String key) => switch (key) {
        'pref_body' => 'Body',
        'pref_feet' => 'Feet',
        'pref_tail' => 'Tail',
        'pref_face' => 'Face',
        'pref_ears' => 'Ears',
        'pref_skirt' => 'Skirt',
        _ => key,
      };

  Future<void> _approve(IntakeSubmission submission) async {
    final uid = await promptForText(
      context,
      title: 'Give this client a UID',
      message: 'Approving creates ${submission.fullName} and their '
          '${submission.dogs.length} dog${submission.dogs.length == 1 ? '' : 's'}.',
      labelText: 'Client UID',
      hintText: 'MOJO-015',
      textCapitalization: TextCapitalization.characters,
      confirmLabel: 'APPROVE',
    );
    if (uid == null || uid.isEmpty) return;

    try {
      await _data.approveIntake(submission.id, uid);
      if (!mounted) return;
      showSnack(context, '${submission.fullName} added.');
      _load();
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    }
  }

  Future<void> _reject(IntakeSubmission submission) async {
    await _data.rejectIntake(submission.id);
    _load();
  }

  Future<void> _approveClaim(ClaimRequest claim) async {
    final choice = await showModalBottomSheet<ClaimApproval>(
      context: context,
      isScrollControlled: true,
      builder: (_) => _ClientPickerSheet(claim: claim),
    );
    if (choice == null || !mounted) return;

    if (choice.createNew) {
      await _approveAsNewClient(claim);
      return;
    }
    await _linkToExistingClient(claim, choice.client!);
  }

  /// Nobody on file matches, so make the record from what they gave us.
  Future<void> _approveAsNewClient(ClaimRequest claim) async {
    final uid = await promptForText(
      context,
      title: 'Give this client a UID',
      message: 'Creates a new record for ${claim.claimedName} and links it to '
          '${claim.username}. You can add their dogs afterwards.',
      labelText: 'Client UID',
      hintText: 'MOJO-015',
      textCapitalization: TextCapitalization.characters,
      confirmLabel: 'CREATE',
    );
    if (uid == null || uid.isEmpty) return;

    try {
      await _data.approveClaimAsNewClient(claim.id, uid: uid);
      if (!mounted) return;
      showSnack(context, 'Created ${claim.claimedName} and linked ${claim.username}.');
      _load();
    } catch (error) {
      if (!mounted) return;
      showSnack(context, error.toString(), isError: true);
    }
  }

  Future<void> _linkToExistingClient(ClaimRequest claim, ClientRecord client) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Link ${client.fullName}?'),
        content: Text(
          '${claim.username} will sign in and see this client\'s dogs, '
          'bookings and history.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('LINK'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      await _data.approveClaim(claim.id, clientId: client.id);
      if (!mounted) return;
      showSnack(context, 'Linked ${claim.username} to ${client.fullName}.');
      _load();
    } catch (error) {
      if (!mounted) return;
      showSnack(context, error.toString(), isError: true);
    }
  }

  Widget _claimList(List<ClaimRequest> pending) {
    if (pending.isEmpty) {
      return const EmptyState(
        icon: Icons.person_search_outlined,
        title: 'No claims waiting',
        message: 'When a client signs up and asks to be linked to their record, it appears here.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: pending.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final claim = pending[index];
          final matched = claim.matchedClientName;
          return ListTile(
            isThreeLine: true,
            title: Text(claim.claimedName),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('${claim.claimedEmail} · ${claim.claimedPostcode}'),
                const SizedBox(height: 6),
                if (matched != null)
                  InfoTag(label: 'Suggested match: $matched', icon: Icons.link)
                else
                  const InfoTag(
                    label: 'No match found',
                    icon: Icons.help_outline,
                    color: AppColors.warning,
                  ),
              ],
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.close, color: AppColors.error),
                  onPressed: () async {
                    await _data.rejectClaim(claim.id);
                    _load();
                  },
                ),
                IconButton(
                  icon: const Icon(Icons.check, color: AppColors.success),
                  tooltip: 'Approve and link',
                  // Always live. The suggested match is only a hint and misses
                  // often enough that this used to be a dead button; approving
                  // now opens the client list so the record can be named.
                  onPressed: () => _approveClaim(claim),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// What staff chose to do with a claim.
///
/// Two outcomes, because two things happen in practice: the person is already
/// one of Jess's clients and needs linking, or they signed up without ever
/// having been entered and need a record making.
class ClaimApproval {
  const ClaimApproval.link(ClientRecord this.client) : createNew = false;
  const ClaimApproval.createNew()
      : client = null,
        createNew = true;

  final ClientRecord? client;
  final bool createNew;
}

/// Which client record a claim gets linked to.
///
/// The server suggests a match, but it is only a hint — it looks at email, or
/// surname plus postcode, and a client who signs up with a different address
/// to the one on file matches neither. Staff name the record instead.
///
/// Records that already have a login are left out: the server refuses to move
/// one to a second account, so offering them would only produce a 409.
class _ClientPickerSheet extends StatefulWidget {
  const _ClientPickerSheet({required this.claim});

  final ClaimRequest claim;

  @override
  State<_ClientPickerSheet> createState() => _ClientPickerSheetState();
}

class _ClientPickerSheetState extends State<_ClientPickerSheet> {
  final _data = getIt<DataService>();
  final _search = TextEditingController();

  List<ClientRecord> _clients = const [];
  int _hiddenBecauseLinked = 0;
  String _query = '';
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    try {
      final clients = await _data.getClients();
      if (!mounted) return;
      final linkable = clients.where((client) => !client.hasLogin).toList();
      setState(() {
        _clients = linkable;
        _hiddenBecauseLinked = clients.length - linkable.length;
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

  /// Postcodes are typed by hand, so compare them with the spaces taken out —
  /// the same trap that broke the server's own matching.
  static String _squash(String value) => value.toLowerCase().replaceAll(' ', '');

  List<ClientRecord> get _visible {
    final query = _query.trim().toLowerCase();
    final matches = query.isEmpty
        ? _clients
        : [
            for (final client in _clients)
              if (client.fullName.toLowerCase().contains(query) ||
                  client.uid.toLowerCase().contains(query) ||
                  _squash(client.postcode).contains(_squash(query)))
                client,
          ];

    // Float the server's suggestion to the top when it found one.
    final suggested = widget.claim.matchedClientId;
    if (suggested == null) return matches;
    return [
      for (final client in matches)
        if (client.id == suggested) client,
      for (final client in matches)
        if (client.id != suggested) client,
    ];
  }

  @override
  Widget build(BuildContext context) {
    final claim = widget.claim;
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.85,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Approve this claim',
                      style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 6),
                  Text(
                    '${claim.username} claims to be ${claim.claimedName} — '
                    '${claim.claimedEmail} · ${claim.claimedPostcode}',
                    style: const TextStyle(fontSize: 12.5, color: AppColors.inkSecondary),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: _search,
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search),
                      hintText: 'Name, UID or postcode',
                      isDense: true,
                    ),
                    onChanged: (value) => setState(() => _query = value),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Always offered, not just when the search comes up empty: someone
            // who was never entered as a client is an ordinary case, not a
            // failure of the list below.
            ListTile(
              leading: const Icon(Icons.person_add_alt, color: AppColors.primary),
              title: const Text('Create a new client'),
              subtitle: Text('Not one of yours yet — make a record from ${claim.claimedName}'),
              onTap: () => Navigator.pop(context, const ClaimApproval.createNew()),
            ),
            const Divider(height: 1),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _body() {
    if (_loading) return const Center(child: CircularProgressIndicator());
    if (_error != null) return ErrorRetry(error: _error!, onRetry: _load);

    final visible = _visible;
    if (visible.isEmpty) {
      return EmptyState(
        icon: Icons.person_off_outlined,
        title: _clients.isEmpty ? 'No records to link' : 'Nothing matches',
        message: _clients.isEmpty
            ? 'Every client record already has a login attached. Use "Create a '
                'new client" above if this is a new customer.'
            : 'No client matches "$_query". If they are new, create a record '
                'for them above.',
      );
    }

    return ListView.separated(
      itemCount: visible.length + (_hiddenBecauseLinked > 0 ? 1 : 0),
      separatorBuilder: (_, _) => const Divider(height: 1),
      itemBuilder: (context, index) {
        if (index == visible.length) {
          return Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              '$_hiddenBecauseLinked client${_hiddenBecauseLinked == 1 ? '' : 's'} '
              'hidden — already linked to a login.',
              style: const TextStyle(fontSize: 12, color: AppColors.inkSecondary),
            ),
          );
        }
        final client = visible[index];
        final isSuggested = client.id == widget.claim.matchedClientId;
        return ListTile(
          title: Text(client.fullName),
          subtitle: Text(
            '${client.uid} · ${client.postcode} · '
            '${client.dogCount} dog${client.dogCount == 1 ? '' : 's'}',
          ),
          trailing: isSuggested
              ? const InfoTag(label: 'Suggested', icon: Icons.link)
              : const Icon(Icons.chevron_right),
          onTap: () => Navigator.pop(context, ClaimApproval.link(client)),
        );
      },
    );
  }
}
