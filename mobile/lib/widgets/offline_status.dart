import 'package:flutter/material.dart';

import '../constants/app_colors.dart';
import '../models/models.dart';
import '../services/data_service.dart';
import '../services/service_locator.dart';

/// Visible provenance for locally saved records and uploads still on-device.
class OfflineStatus extends StatelessWidget {
  const OfflineStatus({super.key, this.showReady = false, this.onReview});
  final bool showReady;
  final VoidCallback? onReview;

  @override
  Widget build(BuildContext context) {
    final data = getIt<DataService>();
    final store = data.offline;
    if (store == null) return const SizedBox.shrink();
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        if (!store.enabled ||
            (!showReady &&
                !store.isOffline &&
                store.pendingCount == 0 &&
                store.syncError == null)) {
          return const SizedBox.shrink();
        }
        final saved = store.savedAt?.toLocal();
        return Material(
          color: context.mojo.tintWash,
          child: ListTile(
            dense: true,
            leading: Icon(
              store.isOffline ? Icons.cloud_off : Icons.offline_pin_outlined,
              color: context.mojo.accent,
            ),
            title: Text(
              store.isOffline
                  ? 'Offline — saved Doguments'
                  : store.syncing
                  ? 'Updating saved Doguments…'
                  : saved == null
                  ? 'Preparing Doguments for offline use'
                  : 'Doguments saved for offline use',
            ),
            subtitle: Text(
              [
                if (saved != null)
                  'Updated ${formatDate(saved)}, ${formatTime(saved)}.',
                if (store.pendingCount > 0)
                  '${store.pendingCount} groom${store.pendingCount == 1 ? '' : 's'} waiting to upload.',
                if (store.syncError != null)
                  'Upload needs attention: ${store.syncError}',
              ].join(' '),
            ),
            trailing: IconButton(
              tooltip: 'Sync and refresh offline copy',
              onPressed: store.syncing
                  ? null
                  : () => data.syncOffline(refreshSnapshot: true),
              icon: const Icon(Icons.sync),
            ),
            onTap: store.pendingCount == 0
                ? null
                : onReview ??
                      () => showModalBottomSheet<void>(
                        context: context,
                        isScrollControlled: true,
                        builder: (context) => SafeArea(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Waiting to upload',
                                  style: Theme.of(context).textTheme.titleLarge,
                                ),
                                const Text(
                                  'These grooms are kept on this device until the server confirms they are saved.',
                                ),
                                Flexible(
                                  child: ListView(
                                    shrinkWrap: true,
                                    children: [
                                      for (final entry in store.pending)
                                        ListTile(
                                          title: Text(
                                            entry['dog_name']?.toString() ??
                                                'Groom',
                                          ),
                                          subtitle: Text(
                                            entry['body']['started_at']
                                                    ?.toString() ??
                                                '',
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                                ElevatedButton(
                                  onPressed: () {
                                    Navigator.pop(context);
                                    data.syncOffline(refreshSnapshot: true);
                                  },
                                  child: const Text('RETRY UPLOADS'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
          ),
        );
      },
    );
  }
}
