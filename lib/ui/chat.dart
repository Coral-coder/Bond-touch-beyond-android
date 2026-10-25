import 'package:flutter/material.dart';

import '../app/app_model.dart';
import 'charts.dart';
import 'theme.dart';

/// Chat with the selected partner (text; photos and touches show as they come in).
class ChatPage extends StatefulWidget {
  const ChatPage({super.key, required this.model});
  final AppModel model;
  @override
  State<ChatPage> createState() => _ChatPageState();
}

class _ChatPageState extends State<ChatPage> {
  final _text = TextEditingController();

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: widget.model,
    builder: (context, _) {
      final m = widget.model;
      final partner = m.selected;
      if (partner == null) {
        return const Center(child: Text('Add a partner to chat'));
      }
      final list = (m.chats[partner.id] ?? []).reversed.toList();
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: [
                Avatar(
                  name: partner.name,
                  color: partner.colorRGB,
                  photo: partner.photo,
                  size: 36,
                  online: partner.online,
                ),
                const SizedBox(width: 10),
                Text(
                  partner.name,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: ListView.builder(
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: list.length,
              itemBuilder: (context, i) {
                final msg = list[i];
                final mine = msg.mine;
                final seen =
                    mine &&
                    msg.ringSeq != null &&
                    msg.ringSeq! <= partner.seenMessage;
                return Align(
                  alignment: mine
                      ? Alignment.centerRight
                      : Alignment.centerLeft,
                  child: Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 9,
                    ),
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.75,
                    ),
                    decoration: BoxDecoration(
                      color: mine
                          ? AppTheme.rgb(m.colorRGB).withValues(alpha: 0.85)
                          : Colors.white.withValues(alpha: 0.1),
                      borderRadius: BorderRadius.circular(18),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Text(
                          msg.kind == 'image'
                              ? '📷 Photo'
                              : msg.kind == 'touch'
                              ? '✋ ${msg.text}'
                              : msg.text,
                          style: const TextStyle(fontSize: 15),
                        ),
                        Text(
                          '${whenText(context, msg.sentAt)}${seen ? ' · Seen' : ''}',
                          style: const TextStyle(
                            fontSize: 10,
                            color: Colors.white70,
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.all(8),
              child: Row(
                children: [
                  Expanded(
                    child: TextField(
                      controller: _text,
                      textInputAction: TextInputAction.send,
                      onSubmitted: (_) => _send(),
                      decoration: InputDecoration(
                        hintText: 'Message',
                        filled: true,
                        border: OutlineInputBorder(
                          borderRadius: BorderRadius.circular(24),
                          borderSide: BorderSide.none,
                        ),
                      ),
                    ),
                  ),
                  IconButton.filled(
                    onPressed: _send,
                    icon: const Icon(Icons.send),
                  ),
                ],
              ),
            ),
          ),
        ],
      );
    },
  );

  void _send() {
    final text = _text.text;
    _text.clear();
    widget.model.sendChat(text);
  }
}
