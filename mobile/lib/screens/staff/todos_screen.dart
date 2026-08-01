import 'package:flutter/material.dart';

import '../../constants/app_colors.dart';
import '../../models/models.dart';
import '../../services/data_service.dart';
import '../../services/service_locator.dart';
import '../../widgets/common.dart';

/// Jess's running list — shampoo to order, calls to make.
///
/// This used to be a collapsible dock pinned to the bottom of the calendar.
/// Jess's verdict was that it "doesn't really work on the calendar": it ate
/// screen height on the one view that needs it most, and nothing about a to-do
/// is tied to the day being looked at. It has its own screen under More now,
/// with the outstanding count on the tile so it is still visible at a glance.
class TodosScreen extends StatefulWidget {
  const TodosScreen({super.key});

  @override
  State<TodosScreen> createState() => _TodosScreenState();
}

class _TodosScreenState extends State<TodosScreen> {
  final _data = getIt<DataService>();

  List<TodoItem> _todos = const [];
  bool _loading = true;
  Object? _error;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      final todos = await _data.getTodos();
      if (!mounted) return;
      setState(() {
        _todos = todos;
        _loading = false;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _error = error;
        _loading = false;
      });
    }
  }

  Future<void> _add() async {
    final text = await promptForText(
      context,
      title: 'Add to the list',
      hintText: 'e.g. Order more shampoo',
      confirmLabel: 'ADD',
    );
    if (text == null || text.isEmpty) return;
    try {
      await _data.createTodo(text);
    } catch (error) {
      // Without this the failure surfaced as an unhandled exception with
      // nothing on screen to say what went wrong.
      if (mounted) showSnack(context, error.toString(), isError: true);
      return;
    }
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final outstanding = _todos.where((todo) => !todo.isDone).toList();
    final done = _todos.where((todo) => todo.isDone).toList();

    return Scaffold(
      appBar: AppBar(title: const Text('To-do')),
      floatingActionButton: FloatingActionButton(
        onPressed: _add,
        tooltip: 'Add a to-do',
        child: const Icon(Icons.add),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _error != null && _todos.isEmpty
              ? ErrorRetry(error: _error!, onRetry: _load)
              : RefreshIndicator(
                  onRefresh: _load,
                  child: _todos.isEmpty
                      ? ListView(
                          children: const [
                            SizedBox(height: 80),
                            EmptyState(
                              icon: Icons.checklist,
                              title: 'Nothing on the list',
                              message: 'Shampoo to order, calls to make.',
                            ),
                          ],
                        )
                      : ListView(
                          padding: const EdgeInsets.only(bottom: 88),
                          children: [
                            for (final todo in outstanding) _row(todo),
                            if (done.isNotEmpty)
                              // Ticked items collapse rather than silting up
                              // the list — the dock had no room to do this and
                              // filled with strikethroughs.
                              ExpansionTile(
                                title: Text('Done (${done.length})'),
                                children: [for (final todo in done) _row(todo)],
                              ),
                          ],
                        ),
                ),
    );
  }

  Widget _row(TodoItem todo) {
    return Dismissible(
      key: ValueKey(todo.id),
      direction: DismissDirection.endToStart,
      background: Container(
        color: AppColors.error,
        alignment: Alignment.centerRight,
        padding: const EdgeInsets.only(right: 16),
        child: const Icon(Icons.delete, color: Colors.white),
      ),
      onDismissed: (_) async {
        await _data.deleteTodo(todo.id);
        _load();
      },
      child: CheckboxListTile(
        value: todo.isDone,
        onChanged: (value) async {
          await _data.updateTodo(todo.id, {'is_done': value});
          _load();
        },
        title: Text(
          todo.text,
          style: TextStyle(
            decoration: todo.isDone ? TextDecoration.lineThrough : null,
            color: todo.isDone ? context.mojo.muted : null,
          ),
        ),
        subtitle: todo.dueDate == null ? null : Text('Due ${formatDate(todo.dueDate!)}'),
        controlAffinity: ListTileControlAffinity.leading,
      ),
    );
  }
}
