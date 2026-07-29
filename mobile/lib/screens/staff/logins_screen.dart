import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// Who can sign in, and getting them back in when they can't.
///
/// Superuser-only, and the server enforces that independently — this screen
/// simply isn't offered to anyone else. Two tabs, because there are two ways
/// this starts: someone asks for help from the login screen, or Jess is on the
/// phone to a client and needs a link there and then.
class LoginsScreen extends StatefulWidget {
  const LoginsScreen({super.key});

  @override
  State<LoginsScreen> createState() => _LoginsScreenState();
}

class _LoginsScreenState extends State<LoginsScreen> {
  final _data = getIt<DataService>();
  final _search = TextEditingController();

  List<AccountSummary> _accounts = const [];
  List<PasswordHelpRequest> _requests = const [];
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
    setState(() => _loading = true);
    try {
      final accounts = await _data.getAccounts(search: _search.text.trim());
      final requests = await _data.getPasswordHelpRequests();
      if (!mounted) return;
      setState(() {
        _accounts = accounts;
        _requests = requests;
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
    final pending = _requests.where((request) => request.status == 'PENDING').toList();

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Logins'),
          bottom: TabBar(
            tabs: [
              Tab(text: 'Locked out (${pending.length})'),
              const Tab(text: 'All logins'),
            ],
          ),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _error != null
                ? ErrorRetry(error: _error!, onRetry: _load)
                : TabBarView(
                    children: [_requestList(pending), _accountList()],
                  ),
      ),
    );
  }

  // ── Locked out ─────────────────────────────────────────────────────

  Widget _requestList(List<PasswordHelpRequest> pending) {
    if (pending.isEmpty) {
      return const EmptyState(
        icon: Icons.lock_open_outlined,
        title: 'Nobody is waiting',
        message: 'When someone taps "I\'ve forgotten my password" on the sign-in '
            'screen, they appear here.',
      );
    }
    return RefreshIndicator(
      onRefresh: _load,
      child: ListView.separated(
        itemCount: pending.length,
        separatorBuilder: (_, _) => const Divider(height: 1),
        itemBuilder: (context, index) {
          final request = pending[index];
          return ListTile(
            isThreeLine: true,
            title: Text(request.clientName ?? request.identifier),
            subtitle: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Typed "${request.identifier}"'
                  '${request.createdAt == null ? '' : ' · ${formatDate(request.createdAt!)}'}',
                ),
                if (request.note.isNotEmpty)
                  Text(request.note, style: const TextStyle(fontStyle: FontStyle.italic)),
                const SizedBox(height: 6),
                if (request.isMatched)
                  InfoTag(label: 'Account: ${request.username}', icon: Icons.person_outline)
                else
                  // Nothing matched, so there is no account to issue against.
                  // She can still find them by hand on the other tab.
                  const InfoTag(
                    label: 'No account matched',
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
                  tooltip: 'Dismiss',
                  onPressed: () => _dismiss(request),
                ),
                IconButton(
                  icon: const Icon(Icons.key_outlined, color: AppColors.success),
                  tooltip: 'Send a reset link',
                  onPressed: request.isMatched ? () => _issueForRequest(request) : null,
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  Future<void> _dismiss(PasswordHelpRequest request) async {
    try {
      await _data.dismissPasswordHelpRequest(request.id);
      _load();
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    }
  }

  Future<void> _issueForRequest(PasswordHelpRequest request) async {
    final confirmed = await _confirm(
      title: 'Send a reset link to ${request.username}?',
      message: 'Check this really is ${request.clientName ?? request.identifier} '
          'before you send it — the link sets their password without knowing the '
          'old one, and signs them out everywhere.',
    );
    if (confirmed != true) return;
    await _issue(() => _data.issueResetLink(requestId: request.id));
  }

  // ── All logins ─────────────────────────────────────────────────────

  Widget _accountList() {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _search,
            decoration: const InputDecoration(
              prefixIcon: Icon(Icons.search),
              hintText: 'Name, username, email or UID',
              isDense: true,
            ),
            onSubmitted: (_) => _load(),
          ),
        ),
        Expanded(
          child: _accounts.isEmpty
              ? const EmptyState(
                  icon: Icons.person_off_outlined,
                  title: 'Nothing matches',
                  message: 'No login matches that. Clients who have never signed up '
                      'have a record but no login.',
                )
              : RefreshIndicator(
                  onRefresh: _load,
                  child: ListView.separated(
                    itemCount: _accounts.length,
                    separatorBuilder: (_, _) => const Divider(height: 1),
                    itemBuilder: (context, index) {
                      final account = _accounts[index];
                      return ListTile(
                        leading: Icon(
                          account.isStaff ? Icons.content_cut : Icons.person_outline,
                          color: account.isActive ? AppColors.primary : AppColors.inkSecondary,
                        ),
                        title: Text(account.username),
                        subtitle: Text(
                          account.lastLogin == null
                              ? '${account.subtitle} · never signed in'
                              : '${account.subtitle} · last in ${formatDate(account.lastLogin!)}',
                        ),
                        trailing: IconButton(
                          icon: const Icon(Icons.key_outlined),
                          tooltip: 'Send a reset link',
                          onPressed: () => _issueForAccount(account),
                        ),
                      );
                    },
                  ),
                ),
        ),
      ],
    );
  }

  Future<void> _issueForAccount(AccountSummary account) async {
    final confirmed = await _confirm(
      title: 'Send a reset link to ${account.username}?',
      message: 'The link lets them set a new password without knowing the old '
          'one, and signs that account out of every device. Only send it to '
          'someone you are sure of.',
    );
    if (confirmed != true) return;
    await _issue(() => _data.issueResetLink(accountId: account.id));
  }

  Future<bool?> _confirm({required String title, required String message}) {
    return showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('CANCEL'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('SEND LINK'),
          ),
        ],
      ),
    );
  }

  Future<void> _issue(Future<IssuedResetLink> Function() call) async {
    try {
      final issued = await call();
      if (!mounted) return;
      await _showLink(issued);
      _load();
    } catch (error) {
      if (mounted) showSnack(context, error.toString(), isError: true);
    }
  }

  /// The link comes back once and is never readable again, so this dialog is
  /// the only chance to get it out of the app — hence copy-to-clipboard rather
  /// than a line of text to squint at and retype.
  Future<void> _showLink(IssuedResetLink issued) {
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Reset link'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              issued.emailed
                  ? 'Emailed to ${issued.email}. Here it is as well, in case it '
                      'does not arrive:'
                  : issued.emailConfigured
                      ? 'Could not email it${issued.emailError == null ? '' : ' — ${issued.emailError}'}. '
                          'Send this to them instead:'
                      : 'Email is not set up on this server, so send this to them '
                          'yourself — WhatsApp, text, however you normally would:',
              style: const TextStyle(fontSize: 13.5),
            ),
            const SizedBox(height: 12),
            SelectableText(issued.link, style: const TextStyle(fontSize: 12.5)),
            const SizedBox(height: 12),
            const Text(
              'It works once and then expires. This is the only time it is shown.',
              style: TextStyle(fontSize: 12, color: AppColors.inkSecondary),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: issued.link));
              Navigator.pop(context);
              showSnack(context, 'Link copied.');
            },
            child: const Text('COPY'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('DONE'),
          ),
        ],
      ),
    );
  }
}
