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
    final controller = TextEditingController();
    final uid = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Give this client a UID'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Approving creates ${submission.fullName} and their '
                '${submission.dogs.length} dog${submission.dogs.length == 1 ? '' : 's'}.'),
            const SizedBox(height: 12),
            TextField(
              controller: controller,
              autofocus: true,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(labelText: 'Client UID', hintText: 'MOJO-015'),
            ),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('CANCEL')),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('APPROVE'),
          ),
        ],
      ),
    );
    controller.dispose();
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

  Future<void> _approveClaim(ClaimRequest claim, String matchedName) async {
    try {
      await _data.approveClaim(claim.id);
      if (!mounted) return;
      showSnack(context, 'Linked to $matchedName.');
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
                  icon: Icon(
                    Icons.check,
                    color: matched == null ? AppColors.inkSecondary : AppColors.success,
                  ),
                  // Without a suggested match there is nothing to link to;
                  // Jess sets the link from the client record instead.
                  onPressed:
                      matched == null ? null : () => _approveClaim(claim, matched),
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
