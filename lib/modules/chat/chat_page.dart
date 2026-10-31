import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'chat_service.dart';

class ChatPage extends StatefulWidget {
  const ChatPage({super.key});

  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final chat = ChatService.instance;
  var _open = everyone;
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _select(String id) {
    setState(() => _open = id);
    chat.markRead(id);
    _focus.requestFocus();
  }

  Future<void> _send() async {
    final text = _input.text;
    if (text.trim().isEmpty) return;
    _input.clear();
    final delivered = await chat.send(_open, text);
    if (!mounted) return;
    final online = _open == everyone ? chat.peers.values.where((p) => p.online).length : 1;
    if (delivered < online || online == 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          width: 420,
          content: Text(online == 0 ? 'Nobody else is online yet' : 'Delivered to $delivered of $online'),
        ),
      );
    }
  }

  Future<void> _rename() async {
    final ctrl = TextEditingController(text: chat.myName);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Your chat name'),
        content: SizedBox(
          width: 320,
          child: TextField(controller: ctrl, autofocus: true, onSubmitted: (v) => Navigator.pop(ctx, v)),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, ctrl.text), child: const Text('Save')),
        ],
      ),
    );
    if (name != null) await chat.rename(name);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final text = Theme.of(context).textTheme;

    return ListenableBuilder(
      listenable: chat,
      builder: (context, _) {
        // Reading a conversation while it's on screen.
        if (TickerMode.valuesOf(context).enabled && (chat.unread[_open] ?? 0) > 0) {
          WidgetsBinding.instance.addPostFrameCallback((_) => chat.markRead(_open));
        }
        final messages = chat.conversations[_open] ?? const <ChatMessage>[];
        final peer = chat.peers[_open];
        final online = chat.peers.values.where((p) => p.online).length;

        return Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 24, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('Chat', style: text.headlineSmall),
                      Text(
                        'Local network only · $online online${chat.error == null ? '' : ' · ${chat.error}'}',
                        style: text.bodySmall?.copyWith(color: chat.error == null ? scheme.outline : scheme.error),
                      ),
                    ],
                  ),
                  const Spacer(),
                  ActionChip(
                    avatar: CircleAvatar(
                      backgroundColor: scheme.primary,
                      child: Text(_initial(chat.myName), style: TextStyle(color: scheme.onPrimary, fontSize: 11)),
                    ),
                    label: Text('You: ${chat.myName}'),
                    tooltip: 'Change your name',
                    onPressed: _rename,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              Expanded(
                child: Card(
                  margin: EdgeInsets.zero,
                  clipBehavior: Clip.antiAlias,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 260,
                        child: Container(
                          color: scheme.surfaceContainerLow,
                          child: ListView(
                            padding: const EdgeInsets.all(8),
                            children: [
                              _ConvTile(
                                icon: Icons.groups_outlined,
                                title: 'Everyone',
                                subtitle: '$online online',
                                online: online > 0,
                                unread: chat.unread[everyone] ?? 0,
                                selected: _open == everyone,
                                onTap: () => _select(everyone),
                              ),
                              const Divider(height: 16),
                              if (chat.peers.isEmpty)
                                Padding(
                                  padding: const EdgeInsets.all(12),
                                  child: Text(
                                    'Waiting for other DevKit users on this network…',
                                    style: text.bodySmall?.copyWith(color: scheme.outline),
                                  ),
                                ),
                              for (final p in chat.sortedPeers)
                                _ConvTile(
                                  initial: _initial(p.name),
                                  title: p.name,
                                  subtitle: p.online ? p.host : 'offline',
                                  online: p.online,
                                  unread: chat.unread[p.id] ?? 0,
                                  selected: _open == p.id,
                                  onTap: () => _select(p.id),
                                ),
                            ],
                          ),
                        ),
                      ),
                      VerticalDivider(width: 1, color: scheme.outlineVariant),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Container(
                              height: 52,
                              padding: const EdgeInsets.symmetric(horizontal: 16),
                              alignment: Alignment.centerLeft,
                              child: Text(
                                _open == everyone
                                    ? 'Everyone'
                                    : '${peer?.name ?? 'Unknown'}${peer == null ? '' : '  ·  ${peer.host} (${peer.ip})'}',
                                style: text.titleSmall,
                              ),
                            ),
                            const Divider(height: 1),
                            Expanded(
                              child: messages.isEmpty
                                  ? Center(
                                      child: Text('Say hi 👋', style: text.bodyMedium?.copyWith(color: scheme.outline)),
                                    )
                                  : ListView.builder(
                                      controller: _scroll,
                                      reverse: true,
                                      padding: const EdgeInsets.all(16),
                                      itemCount: messages.length,
                                      itemBuilder: (_, i) {
                                        final m = messages[messages.length - 1 - i];
                                        final prev = i + 1 < messages.length ? messages[messages.length - 2 - i] : null;
                                        return _Bubble(
                                          message: m,
                                          mine: m.from == chat.myId,
                                          showName: _open == everyone && m.from != chat.myId && prev?.from != m.from,
                                        );
                                      },
                                    ),
                            ),
                            const Divider(height: 1),
                            Padding(
                              padding: const EdgeInsets.all(10),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: CallbackShortcuts(
                                      bindings: {const SingleActivator(LogicalKeyboardKey.enter): _send},
                                      child: TextField(
                                        controller: _input,
                                        focusNode: _focus,
                                        minLines: 1,
                                        maxLines: 5,
                                        decoration: InputDecoration(
                                          hintText: _open == everyone
                                              ? 'Message everyone… (Shift+Enter for a new line)'
                                              : 'Message ${peer?.name ?? ''}…',
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  IconButton.filled(onPressed: _send, icon: const Icon(Icons.send, size: 18)),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

String _initial(String name) => name.trim().isEmpty ? '?' : name.trim()[0].toUpperCase();

class _ConvTile extends StatelessWidget {
  const _ConvTile({
    this.icon,
    this.initial,
    required this.title,
    required this.subtitle,
    required this.online,
    required this.unread,
    required this.selected,
    required this.onTap,
  });

  final IconData? icon;
  final String? initial;
  final String title;
  final String subtitle;
  final bool online;
  final int unread;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.primary.withValues(alpha: .10) : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(8),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  CircleAvatar(
                    radius: 17,
                    backgroundColor: scheme.surfaceContainerHigh,
                    child: icon != null
                        ? Icon(icon, size: 18, color: scheme.primary)
                        : Text(initial ?? '?', style: const TextStyle(fontWeight: FontWeight.w700)),
                  ),
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 10,
                      height: 10,
                      decoration: BoxDecoration(
                        color: online ? const Color(0xFF10B981) : scheme.outlineVariant,
                        shape: BoxShape.circle,
                        border: Border.all(color: scheme.surfaceContainerLow, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    Text(
                      subtitle,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 11.5, color: scheme.outline),
                    ),
                  ],
                ),
              ),
              if (unread > 0) Badge(label: Text('$unread')),
            ],
          ),
        ),
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble({required this.message, required this.mine, required this.showName});

  final ChatMessage message;
  final bool mine;
  final bool showName;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final t = message.time;
    final time = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Padding(
          padding: EdgeInsets.only(top: showName ? 10 : 3),
          child: Column(
            crossAxisAlignment: mine ? CrossAxisAlignment.end : CrossAxisAlignment.start,
            children: [
              if (showName)
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 2),
                  child: Text(
                    message.fromName,
                    style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w600, color: scheme.primary),
                  ),
                ),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 6),
                decoration: BoxDecoration(
                  color: mine ? scheme.primary : scheme.surfaceContainerHigh,
                  borderRadius: BorderRadius.only(
                    topLeft: const Radius.circular(14),
                    topRight: const Radius.circular(14),
                    bottomLeft: Radius.circular(mine ? 14 : 4),
                    bottomRight: Radius.circular(mine ? 4 : 14),
                  ),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    SelectableText(
                      message.text,
                      style: TextStyle(color: mine ? scheme.onPrimary : scheme.onSurface, height: 1.35),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      time,
                      style: TextStyle(
                        fontSize: 10,
                        color: (mine ? scheme.onPrimary : scheme.onSurface).withValues(alpha: .6),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
