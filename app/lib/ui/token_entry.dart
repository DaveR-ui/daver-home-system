import 'package:flutter/material.dart';

/// Asks the owner for the long-lived Home Assistant token.
///
/// The field is obscured and the text is handed straight to [onSubmit]; it is
/// never stored or logged here. Storage is the controller's job.
class TokenEntryField extends StatefulWidget {
  const TokenEntryField({super.key, required this.onSubmit});

  /// Receives the trimmed token when the owner taps "Save token".
  final ValueChanged<String> onSubmit;

  @override
  State<TokenEntryField> createState() => _TokenEntryFieldState();
}

class _TokenEntryFieldState extends State<TokenEntryField> {
  final TextEditingController _controller = TextEditingController();

  void _submit() {
    final String token = _controller.text.trim();
    if (token.isEmpty) {
      return;
    }
    widget.onSubmit(token);
    _controller.clear();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              'Home Assistant access token',
              style: Theme.of(context).textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                  ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(
                labelText: 'Long-lived token',
                border: OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 12),
            // Rebuilds from the controller alone, so the button tracks the text.
            ValueListenableBuilder<TextEditingValue>(
              valueListenable: _controller,
              builder: (BuildContext context, TextEditingValue value, _) {
                final bool canSubmit = value.text.trim().isNotEmpty;
                return FilledButton(
                  onPressed: canSubmit ? _submit : null,
                  child: const Text('Save token'),
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}
