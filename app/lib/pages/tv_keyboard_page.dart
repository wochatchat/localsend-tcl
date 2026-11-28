import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/cross_file.dart';
import 'package:localsend_app/provider/network/nearby_devices_provider.dart';
import 'package:localsend_app/provider/network/scan_facade.dart';
import 'package:localsend_app/provider/network/send_provider.dart';
import 'package:localsend_app/pages/tv_keyboard_client.dart';
import 'package:localsend_app/widget/dialogs/message_input_dialog.dart';
import 'package:localsend_app/widget/dialogs/pin_dialog.dart';
import 'package:localsend_app/provider/selection/selected_sending_files_provider.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart' as android_channel;
import 'package:localsend_app/util/native/cross_file_converters.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_isolates/model/device.dart';
import 'package:localsend_isolates/model/file_type.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

const _keyboardPort = 53318;
const _uuid = Uuid();

class TvKeyboardPage extends StatefulWidget {
  final Device? initialDevice;

  const TvKeyboardPage({this.initialDevice, super.key});

  @override
  State<TvKeyboardPage> createState() => _TvKeyboardPageState();
}

class _TvKeyboardPageState extends State<TvKeyboardPage> {
  final _controller = TextEditingController();
  final _focusNode = FocusNode();
  final _client = KeyboardClient();
  final _pinPreferences = <String, String>{};

  Device? _device;
  _KeyboardStatus _status = _KeyboardStatus.disconnected;
  String? _statusDetail;
  String _tvText = '';
  Future<void> _writeChain = Future<void>.value();
  bool _applyingSnapshot = false;
  bool _pinsLoaded = false;
  bool _autoConnectScheduled = false;
  bool _autoConnectInFlight = false;
  int _lastSelectionStart = 0;
  int _lastSelectionEnd = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerChanged);
    _device = widget.initialDevice;
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      await _loadSavedPins();
      _pinsLoaded = true;
      if (!mounted) return;
      if (_device != null) {
        await _connect(_device!);
      } else {
        context.global.dispatchAsync(StartSmartScan());
      }
    });
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    _controller.dispose();
    _focusNode.dispose();
    _client.dispose();
    super.dispose();
  }

  Future<void> _loadSavedPins() async {
    final preferences = await SharedPreferences.getInstance();
    for (final key in preferences.getKeys()) {
      if (key.startsWith('ls_tv_keyboard_pin_')) {
        final value = preferences.getString(key);
        if (value != null && value.isNotEmpty) {
          _pinPreferences[key.substring('ls_tv_keyboard_pin_'.length)] = value;
        }
      }
    }
  }

  String _deviceKey(Device device) => '${device.ip}:$_keyboardPort';

  Future<void> _connect(Device device, {bool allowPinPrompt = true}) async {
    final ip = device.ip;
    if (ip == null) return;
    setState(() {
      _device = device;
      _status = _KeyboardStatus.connecting;
      _statusDetail = null;
    });
    _client.close();
    _client.host = ip;
    _client.pin = _pinPreferences[_deviceKey(device)];

    try {
      await _client.state();
      await _sync();
      if (mounted) {
        setState(() => _status = _KeyboardStatus.connected);
        _focusNode.requestFocus();
      }
      return;
    } on KeyboardUnauthorized {
      if (!allowPinPrompt || !mounted) {
        _setDisconnected(t.tvKeyboardPage.pinFailed);
        return;
      }
      final pin = await showDialog<String>(
        context: context,
        builder: (_) => PinDialog(
          obscureText: false,
          pin: _client.pin,
        ),
      );
      if (pin == null || pin.isEmpty) {
        _setDisconnected(null);
        return;
      }
      _pinPreferences[_deviceKey(device)] = pin;
      final preferences = await SharedPreferences.getInstance();
      await preferences.setString('ls_tv_keyboard_pin_${_deviceKey(device)}', pin);
      _client.pin = pin;
      await _connect(device, allowPinPrompt: false);
    } catch (e) {
      _setDisconnected(e.toString());
    }
  }

  void _setDisconnected(String? detail) {
    if (!mounted) return;
    setState(() {
      _status = _KeyboardStatus.disconnected;
      _statusDetail = detail;
    });
  }

  Future<void> _sync() async {
    final snapshot = await _client.snapshot();
    if (snapshot['ok'] != true) {
      throw StateError(snapshot['error']?.toString() ?? 'snapshot unavailable');
    }
    final text = snapshot['text']?.toString() ?? '';
    final startOffset = (snapshot['startOffset'] as num?)?.toInt() ?? 0;
    final selectionStart = (snapshot['selectionStart'] as num?)?.toInt() ?? startOffset;
    final localSelection = (selectionStart - startOffset).clamp(0, text.length).toInt();
    _tvText = text;
    _applyingSnapshot = true;
    _lastSelectionStart = localSelection;
    _lastSelectionEnd = localSelection;
    _controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: localSelection),
    );
    _applyingSnapshot = false;
  }

  void _onControllerChanged() {
    if (_applyingSnapshot || _status != _KeyboardStatus.connected) return;
    final selection = _controller.selection;
    if (!selection.isValid || (selection.start == _lastSelectionStart && selection.end == _lastSelectionEnd)) return;
    _lastSelectionStart = selection.start;
    _lastSelectionEnd = selection.end;
    _enqueue(() async {
      final result = await _client.text({'op': 'sel', 'a': selection.start, 'b': selection.end});
      if (result['applied'] == false) throw StateError('selection was not applied');
    }).catchError((e) => _setDisconnected(e.toString()));
  }

  Future<void> _enqueue(Future<void> Function() operation) {
    final next = _writeChain.then((_) => operation());
    _writeChain = next.catchError((_) {});
    return next;
  }

  void _onTextChanged(String value) {
    if (_applyingSnapshot) return;
    final old = _tvText;
    var prefix = 0;
    while (prefix < old.length && prefix < value.length && old.codeUnitAt(prefix) == value.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < old.length - prefix && suffix < value.length - prefix && old.codeUnitAt(old.length - suffix - 1) == value.codeUnitAt(value.length - suffix - 1)) {
      suffix++;
    }
    final removed = old.length - prefix - suffix;
    final inserted = value.substring(prefix, value.length - suffix);
    _tvText = value;
    _enqueue(() async {
      if (removed > 0) {
        await _client.text({'op': 'sel', 'a': prefix + removed, 'b': prefix + removed});
        await _client.text({'op': 'del', 'before': removed, 'after': 0});
      }
      if (inserted.isNotEmpty) {
        await _client.text({'op': 'sel', 'a': prefix, 'b': prefix});
        await _client.text({'op': 'ins', 'text': inserted});
      }
    }).catchError((e) => _setDisconnected(e.toString()));
  }

  Future<void> _runAction(String action) async {
    if (_status != _KeyboardStatus.connected) return;
    try {
      await _enqueue(() async {
        final result = await _client.action(action);
        if (result['applied'] == false) throw StateError('action was not applied');
        await _sync();
      });
      _focusNode.requestFocus();
    } catch (e) {
      _setDisconnected(e.toString());
    }
  }

  Future<void> _runTextAction(Map<String, dynamic> operation) async {
    if (_status != _KeyboardStatus.connected) return;
    try {
      await _enqueue(() async {
        final result = await _client.text(operation);
        if (result['applied'] == false) throw StateError('operation was not applied');
        await _sync();
      });
      _focusNode.requestFocus();
    } catch (e) {
      _setDisconnected(e.toString());
    }
  }

  Future<void> _transferFiles() async {
    final device = _device;
    if (device == null || _status != _KeyboardStatus.connected) return;

    final ref = context.ref;
    final selectedFiles = ref.redux(selectedSendingFilesProvider);
    selectedFiles.dispatch(ClearSelectionAction());
    try {
      final picked = await android_channel.pickFilesAndroid();
      if (picked == null || picked.isEmpty || !mounted) return;
      await selectedFiles.dispatchAsync(
        AddFilesAction(
          files: picked,
          converter: CrossFileConverters.convertFileInfo,
        ),
      );
      final files = ref.read(selectedSendingFilesProvider);
      if (files.isNotEmpty) {
        await ref.notifier(sendProvider).startSession(target: device, files: files, background: false);
      }
    } finally {
      selectedFiles.dispatch(ClearSelectionAction());
    }
  }

  Future<void> _readTvClipboard() async {
    if (_status != _KeyboardStatus.connected) return;
    try {
      final result = await _client.clipboard();
      final text = result['text']?.toString() ?? '';
      _applyingSnapshot = true;
      _controller.value = TextEditingValue(text: text, selection: TextSelection.collapsed(offset: text.length));
      _applyingSnapshot = false;
    } catch (e) {
      _setDisconnected(e.toString());
    }
  }

  Future<void> _sendAsMessage() async {
    final device = _device;
    if (device == null || _controller.text.isEmpty) return;
    final message = await showDialog<String>(
      context: context,
      builder: (_) => MessageInputDialog(initialText: _controller.text),
    );
    if (message == null || message.isEmpty || !mounted) return;
    final bytes = Uint8List.fromList(utf8.encode(message));
    final file = CrossFile(
      name: '${_uuid.v4()}.txt',
      fileType: FileType.text,
      size: bytes.length,
      thumbnail: null,
      asset: null,
      path: null,
      bytes: bytes,
      lastModified: null,
      lastAccessed: null,
    );
    await context.ref.notifier(sendProvider).startSession(target: device, files: [file], background: false);
  }

  @override
  Widget build(BuildContext context) {
    return Consumer(
      builder: (context, ref) {
        final nearby = ref.watch(nearbyDevicesProvider).allDevices.values.where((device) => device.ip != null).toList();
        final devices = <Device>[if (_device != null && !nearby.any((item) => item.ip == _device!.ip)) _device!, ...nearby];
        _scheduleAutoConnect(devices);
        return _buildPage(context, devices);
      },
    );
  }

  Widget _buildPage(BuildContext context, List<Device> devices) {
    final selectedKey = _device == null ? null : _deviceKey(_device!);
    return Scaffold(
      appBar: AppBar(
        title: Text(t.tvKeyboardPage.title),
        actions: [
          IconButton(onPressed: _sendAsMessage, icon: const Icon(Icons.sms_outlined), tooltip: t.tvKeyboardPage.sendAsMessage),
          IconButton(onPressed: _showHelp, icon: const Icon(Icons.help_outline), tooltip: t.tvKeyboardPage.help),
        ],
      ),
      body: ResponsiveListView(
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 20),
        children: [
          Row(
            children: [
              Expanded(
                child: DropdownButtonFormField<String>(
                  value: devices.any((device) => _deviceKey(device) == selectedKey) ? selectedKey : null,
                  decoration: InputDecoration(labelText: t.tvKeyboardPage.deviceLabel),
                  items: devices.map((device) {
                    return DropdownMenuItem(value: _deviceKey(device), child: Text(device.alias, overflow: TextOverflow.ellipsis));
                  }).toList(),
                  onChanged: (key) {
                    final device = devices.firstWhere((item) => _deviceKey(item) == key);
                    _connect(device);
                  },
                ),
              ),
              const SizedBox(width: 8),
              _StatusDot(status: _status, label: _statusLabel),
              IconButton(onPressed: _status == _KeyboardStatus.connecting || _device == null ? null : () => _connect(_device!), icon: const Icon(Icons.sync), tooltip: t.tvKeyboardPage.syncNow),
            ],
          ),
          if (_statusDetail != null && _status == _KeyboardStatus.disconnected)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_statusDetail!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ),
          const SizedBox(height: 15),
          SizedBox(
            width: double.infinity,
            child: FilledButton.icon(
              onPressed: _status == _KeyboardStatus.connected ? _transferFiles : null,
              icon: const Icon(Icons.upload_file),
              label: Text(t.tvKeyboardPage.transferFiles),
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _controller,
            focusNode: _focusNode,
            autofocus: true,
            minLines: 6,
            maxLines: null,
            onChanged: _onTextChanged,
            decoration: InputDecoration(
              helperText: t.tvKeyboardPage.realtimeHint,
            ),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _ToolButton(label: t.tvKeyboardPage.toolBackspace, icon: Icons.backspace_outlined, onPressed: () => _runTextAction({'op': 'del', 'before': 1, 'after': 0})),
              _ToolButton(label: t.tvKeyboardPage.toolDeleteWord, icon: Icons.backspace, onPressed: () => _runAction('deleteWord')),
              _ToolButton(label: t.tvKeyboardPage.toolDeleteForward, icon: Icons.delete_outline, onPressed: () => _runTextAction({'op': 'del', 'before': 0, 'after': 1})),
              _ToolButton(label: t.tvKeyboardPage.toolEnter, icon: Icons.keyboard_return, primary: true, onPressed: () => _runAction('enter')),
              _ToolButton(label: t.tvKeyboardPage.toolTab, icon: Icons.keyboard_tab, onPressed: () => _runAction('tab')),
              _ToolButton(label: t.tvKeyboardPage.toolLeft, icon: Icons.chevron_left, onPressed: () => _runTextAction({'op': 'relmove', 'dx': -1})),
              _ToolButton(label: t.tvKeyboardPage.toolRight, icon: Icons.chevron_right, onPressed: () => _runTextAction({'op': 'relmove', 'dx': 1})),
              _ToolButton(label: t.tvKeyboardPage.toolHome, icon: Icons.first_page, onPressed: () => _runAction('home')),
              _ToolButton(label: t.tvKeyboardPage.toolEnd, icon: Icons.last_page, onPressed: () => _runAction('end')),
              _ToolButton(label: t.tvKeyboardPage.toolSelectAll, icon: Icons.select_all, onPressed: () => _runAction('selectAll')),
              _ToolButton(label: t.tvKeyboardPage.toolCopy, icon: Icons.copy, onPressed: () => _runAction('copy')),
              _ToolButton(label: t.tvKeyboardPage.toolCut, icon: Icons.content_cut, onPressed: () => _runAction('cut')),
              _ToolButton(label: t.tvKeyboardPage.toolPaste, icon: Icons.content_paste, onPressed: () => _runAction('paste')),
              _ToolButton(label: t.tvKeyboardPage.toolTvClipboard, icon: Icons.content_paste_go, onPressed: _readTvClipboard),
            ],
          ),
          const SizedBox(height: 15),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [Icon(Icons.lightbulb_outline, color: Theme.of(context).colorScheme.primary), const SizedBox(width: 8), Expanded(child: Text(t.tvKeyboardPage.resyncHint))]),
            ),
          ),
          if (devices.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 20),
              child: Column(
                children: [
                  const Icon(Icons.keyboard, size: 48),
                  const SizedBox(height: 8),
                  Text(t.tvKeyboardPage.noDevices),
                  TextButton(onPressed: _rescan, child: Text(t.tvKeyboardPage.rescan)),
                ],
              ),
            ),
        ],
      ),
    );
  }

  String get _statusLabel {
    return switch (_status) {
      _KeyboardStatus.connecting => t.tvKeyboardPage.statusConnecting(alias: _device?.alias ?? ''),
      _KeyboardStatus.connected => t.tvKeyboardPage.statusConnected,
      _KeyboardStatus.disconnected => t.tvKeyboardPage.statusDisconnected,
    };
  }

  void _scheduleAutoConnect(List<Device> devices) {
    if (!_pinsLoaded || widget.initialDevice != null || _device != null || _autoConnectScheduled || _autoConnectInFlight) return;
    _autoConnectScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _autoConnectScheduled = false;
      if (mounted) unawaited(_autoConnect(devices));
    });
  }

  Future<void> _autoConnect(List<Device> devices) async {
    if (_autoConnectInFlight || _device != null || _status == _KeyboardStatus.connected) return;
    _autoConnectInFlight = true;
    try {
      final candidates = devices.where((device) => device.ip != null).toList();
      final reachable = await Future.wait(
        candidates.map((device) async => await KeyboardClient.probeHost(device.ip!) ? device : null),
      );
      if (!mounted || _device != null) return;
      final reachableDevices = reachable.whereType<Device>().toList();
      if (reachableDevices.isNotEmpty) await _connect(reachableDevices.first);
    } finally {
      _autoConnectInFlight = false;
    }
  }

  void _rescan() {
    context.redux(nearbyDevicesProvider).dispatch(ClearFoundDevicesAction());
    context.global.dispatchAsync(StartSmartScan());
  }

  void _showHelp() {
    showDialog<void>(
      context: context,
      builder: (_) => AlertDialog(
        title: Text(t.tvKeyboardPage.help),
        content: Text(t.tvKeyboardPage.helpBody),
        actions: [TextButton(onPressed: () => context.pop(), child: Text(t.general.close))],
      ),
    );
  }
}

enum _KeyboardStatus { connecting, connected, disconnected }

class _StatusDot extends StatelessWidget {
  final _KeyboardStatus status;
  final String label;

  const _StatusDot({required this.status, required this.label});

  @override
  Widget build(BuildContext context) {
    final color = switch (status) {
      _KeyboardStatus.connecting => Colors.orange,
      _KeyboardStatus.connected => Colors.green,
      _KeyboardStatus.disconnected => Theme.of(context).colorScheme.error,
    };
    return Flexible(child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.circle, size: 10, color: color), const SizedBox(width: 5), Flexible(child: Text(label, overflow: TextOverflow.ellipsis))]));
  }
}

class _ToolButton extends StatelessWidget {
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool primary;

  const _ToolButton({required this.label, required this.icon, required this.onPressed, this.primary = false});

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    if (primary) {
      return FilledButton.icon(
        onPressed: onPressed,
        style: FilledButton.styleFrom(backgroundColor: colorScheme.primary, foregroundColor: colorScheme.onPrimary),
        icon: Icon(icon, size: 17),
        label: Text(label),
      );
    }
    return OutlinedButton.icon(
      onPressed: onPressed,
      style: OutlinedButton.styleFrom(foregroundColor: colorScheme.onSurfaceVariant),
      icon: Icon(icon, size: 17),
      label: Text(label),
    );
  }
}
