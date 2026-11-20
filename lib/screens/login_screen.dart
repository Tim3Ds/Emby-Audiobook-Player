import 'package:flutter/material.dart';

import '../emby_api.dart';
import '../session_store.dart';

class LoginScreen extends StatefulWidget {
  final SessionStore store;
  final void Function(EmbyApi api) onSignedIn;
  const LoginScreen({super.key, required this.store, required this.onSignedIn});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final TextEditingController _server =
      TextEditingController(text: widget.store.server);
  late final TextEditingController _username =
      TextEditingController(text: widget.store.username);
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _server.dispose();
    _username.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _signIn() async {
    var server = _server.text.trim();
    if (server.isEmpty) {
      setState(() =>
          _error = 'Enter your Emby server address first, e.g. '
              'https://emby.example.com');
      return;
    }
    if (_username.text.trim().isEmpty) {
      setState(() => _error = 'Enter your Emby username.');
      return;
    }
    // A bare host name gets https:// - without a scheme the
    // address parses as a relative path and every request fails
    // with a network error that never mentions why.
    if (!server.contains('://')) server = 'https://$server';
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final api = EmbyApi(server, widget.store.deviceId);
      final result =
          await api.authenticate(_username.text.trim(), _password.text);
      widget.store.server = server;
      widget.store.username = _username.text.trim();
      widget.store.userId = result.user.id;
      widget.store.token = result.accessToken;
      widget.onSignedIn(api);
    } catch (e) {
      setState(() => _error = 'Sign-in failed: $e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('Emby Audiobook Player',
                  style: Theme.of(context).textTheme.headlineMedium),
              const SizedBox(height: 8),
              Text(
                "Sign in to your Emby server. This app shows only your "
                "favorite audiobooks and the book you're in the middle of.",
                style: Theme.of(context).textTheme.bodyMedium,
              ),
              const SizedBox(height: 24),
              TextField(
                controller: _server,
                decoration: const InputDecoration(
                    labelText: 'Server',
                    hintText: 'https://your-emby-server',
                    border: OutlineInputBorder()),
                keyboardType: TextInputType.url,
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _username,
                decoration: const InputDecoration(
                    labelText: 'Username', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _password,
                decoration: const InputDecoration(
                    labelText: 'Password', border: OutlineInputBorder()),
                obscureText: true,
                onSubmitted: (_) {
                  if (!_busy && _username.text.isNotBlank) _signIn();
                },
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(_error!,
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.error)),
              ],
              const SizedBox(height: 20),
              FilledButton(
                // Always enabled while idle: the button used to key
                // off the username field's text at build time, but
                // typing never rebuilt the screen, so it sat
                // disabled until something else forced a rebuild.
                // Validation lives in _signIn instead.
                onPressed: _busy ? null : _signIn,
                child: Text(_busy ? 'Signing in…' : 'Sign in'),
              ),
              const SizedBox(height: 12),
              Text(
                "Your password goes only to your Emby server. The app keeps "
                "a sign-in token on this device so you don't have to repeat this.",
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

extension on String {
  bool get isNotBlank => trim().isNotEmpty;
}
