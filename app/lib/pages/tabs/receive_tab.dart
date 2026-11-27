import 'dart:async';

import 'package:flutter/material.dart';
import 'package:localsend_app/gen/strings.g.dart';
import 'package:localsend_app/model/state/server/server_state.dart';
import 'package:localsend_app/pages/home_page.dart';
import 'package:localsend_app/pages/home_page_controller.dart';
import 'package:localsend_app/pages/receive_history_page.dart';
import 'package:localsend_app/pages/web_share_page.dart';
import 'package:localsend_app/provider/animation_provider.dart';
import 'package:localsend_app/provider/local_ip_provider.dart';
import 'package:localsend_app/provider/network/server/server_provider.dart';
import 'package:localsend_app/provider/settings_provider.dart';
import 'package:localsend_app/provider/tv_provider.dart';
import 'package:localsend_app/util/ip_helper.dart';
import 'package:localsend_app/util/native/channel/android_channel.dart';
import 'package:localsend_app/widget/animations/initial_fade_transition.dart';
import 'package:localsend_app/widget/column_list_view.dart';
import 'package:localsend_app/widget/custom_icon_button.dart';
import 'package:localsend_app/widget/local_send_logo.dart';
import 'package:localsend_app/widget/responsive_list_view.dart';
import 'package:localsend_app/widget/rotating_widget.dart';
import 'package:localsend_isolates/util/sleep.dart';
import 'package:pretty_qr_code/pretty_qr_code.dart';
import 'package:refena_flutter/addons.dart';
import 'package:refena_flutter/refena_flutter.dart';
import 'package:routerino/routerino.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ReceiveTab extends StatefulWidget {
  const ReceiveTab();

  @override
  State<ReceiveTab> createState() => _ReceiveTabState();
}

class _ReceiveTabState extends State<ReceiveTab> {
  /// Whether the advanced network info is shown
  bool _showAdvanced = false;

  /// Whether the history button is shown
  /// This extra boolean is needed to delay the animation
  bool _showHistoryButton = true;

  Future<void> _toggleAdvanced() async {
    if (_showAdvanced) {
      setState(() => _showAdvanced = false);
      await sleepAsync(200);
      if (mounted) {
        setState(() => _showHistoryButton = true);
      }
    } else {
      setState(() {
        _showAdvanced = true;
        _showHistoryButton = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final alias = context.watch(settingsProvider.select((s) => s.alias));
    final serverState = context.watch(serverProvider);
    final localIps = context.watch(localIpProvider.select((s) => s.localIps));

    return Stack(
      children: [
        Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: ResponsiveListView.defaultMaxWidth),
            child: Padding(
              padding: const EdgeInsets.all(30),
              child: ColumnListView(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        InitialFadeTransition(
                          duration: const Duration(milliseconds: 300),
                          delay: const Duration(milliseconds: 200),
                          child: Consumer(
                            builder: (context, ref) {
                              final animations = ref.watch(animationProvider);
                              final activeTab = ref.watch(homePageControllerProvider.select((state) => state.currentTab));
                              return RotatingWidget(
                                duration: const Duration(seconds: 15),
                                spinning: serverState != null && animations && activeTab == HomeTab.receive,
                                child: const LocalSendLogo(withText: false),
                              );
                            },
                          ),
                        ),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(serverState?.alias ?? alias, style: const TextStyle(fontSize: 48)),
                        ),
                        InitialFadeTransition(
                          duration: const Duration(milliseconds: 300),
                          delay: const Duration(milliseconds: 500),
                          child: Text(
                            serverState == null ? t.general.offline : localIps.map((ip) => '#${ip.visualId}').toSet().join(' '),
                            style: const TextStyle(fontSize: 24),
                            textAlign: TextAlign.center,
                          ),
                        ),
                        if (context.ref.read(tvProvider) && serverState != null && localIps.isNotEmpty)
                          Flexible(
                            child: FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Padding(
                                padding: const EdgeInsets.only(top: 15),
                                child: _TvReceiveQr(serverState: serverState, ip: localIps.first),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(top: 10),
                    child: Center(
                      child: OutlinedButton.icon(
                        onPressed: () async {
                          await context.global.dispatchAsync(NavigateAction.push(const WebSharePage()));
                        },
                        icon: Icon(Icons.language),
                        label: Text(t.receiveTab.link),
                      ),
                    ),
                  ),
                  const SizedBox(height: 15),
                ],
              ),
            ),
          ),
        ),
        _InfoBox(
          serverState: serverState,
          localIps: localIps,
          showAdvanced: _showAdvanced,
        ),
        _CornerButtons(
          showAdvanced: _showAdvanced,
          showHistoryButton: _showHistoryButton,
          toggleAdvanced: _toggleAdvanced,
        ),
        if (context.watch(tvProvider)) const _TvDebugLine(),
      ],
    );
  }
}

/// Temporary TV diagnostic line (remove once background receiving is verified).
/// Renders the server state plus the native keep-alive locks in a single row,
/// so one screenshot of the receive page pins down where the receiving chain breaks.
class _TvDebugLine extends StatefulWidget {
  const _TvDebugLine();

  @override
  State<_TvDebugLine> createState() => _TvDebugLineState();
}

class _TvDebugLineState extends State<_TvDebugLine> {
  Map<String, bool>? _status;
  String _log = '';
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _refresh();
    _timer = Timer.periodic(const Duration(seconds: 3), (_) => _refresh());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final status = await keepAliveStatusAndroid();
    final log = await keepAliveLogAndroid();
    if (mounted) {
      setState(() {
        _status = status;
        _log = log;
      });
    }
  }

  String _flag(bool? value) => value == true ? '1' : '0';

  @override
  Widget build(BuildContext context) {
    final serverState = context.watch(serverProvider);
    final localIps = context.watch(localIpProvider.select((s) => s.localIps));
    final status = _status;
    final endpoint = serverState == null ? '-' : '${serverState.https ? 'https' : 'http'}:${serverState.port}';
    final ip = localIps.isEmpty ? '-' : localIps.first;
    final log = _log.isEmpty ? '-' : _log.replaceAll('\n', ' | ');
    return Align(
      alignment: Alignment.bottomCenter,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'DBG srv=${_flag(serverState != null)} $endpoint '
              'fgs=${_flag(status?['fgs'])} mc=${_flag(status?['multicast'])} '
              'wl=${_flag(status?['wake'])} wifi=${_flag(status?['wifi'])} ip=$ip',
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
            Text(
              log,
              style: TextStyle(
                fontSize: 11,
                fontFamily: 'monospace',
                color: Theme.of(context).colorScheme.onSurface.withOpacity(0.4),
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

/// TV: the receive service URL + QR code, always visible so a phone can join
/// the web send page without any interaction on the TV side.
/// Next to the QR code there is an equally sized tile that opens the
/// transfer history page (easier to reach with a remote than the corner icon).
class _TvReceiveQr extends StatefulWidget {
  final ServerState serverState;
  final String ip;

  const _TvReceiveQr({required this.serverState, required this.ip});

  @override
  State<_TvReceiveQr> createState() => _TvReceiveQrState();
}

class _TvReceiveQrState extends State<_TvReceiveQr> {
  static const _transferUrlKey = 'ls_tv_transfer_url';

  String get _urlWithPin {
    final pin = widget.serverState.web?.pin;
    final transferScheme = widget.serverState.https ? 'https' : 'http';
    final query = <String, String>{
      'transferScheme': transferScheme,
      'transferPort': widget.serverState.port.toString(),
      if (pin != null) 'pin': pin,
    };
    return 'http://${widget.ip}:53318/kb?${Uri(queryParameters: query).query}';
  }

  @override
  void initState() {
    super.initState();
    _saveCanonicalUrl();
  }

  @override
  void didUpdateWidget(covariant _TvReceiveQr oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.serverState != widget.serverState || oldWidget.ip != widget.ip) {
      _saveCanonicalUrl();
    }
  }

  Future<void> _saveCanonicalUrl() async {
    final preferences = await SharedPreferences.getInstance();
    await preferences.setString(_transferUrlKey, _urlWithPin);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(t.receiveTab.qrHint, style: const TextStyle(fontSize: 18), textAlign: TextAlign.center),
        const SizedBox(height: 10),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(12)),
              child: SizedBox(
                width: 200,
                height: 200,
                child: PrettyQrView.data(
                  data: _urlWithPin,
                  errorCorrectLevel: QrErrorCorrectLevel.M,
                  decoration: PrettyQrDecoration(shape: PrettyQrSmoothSymbol(roundFactor: 0, color: Colors.black)),
                ),
              ),
            ),
            const SizedBox(width: 20),
            _TvHistoryTile(),
          ],
        ),
        const SizedBox(height: 10),
        Text('http://${widget.ip}:53318/kb', style: const TextStyle(fontSize: 20), textAlign: TextAlign.center),
      ],
    );
  }
}

/// TV: a tile next to the QR code that opens the receive history page.
/// Styled like the QR container (white, same size) with a file icon.
class _TvHistoryTile extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () async {
          await context.push(() => const ReceiveHistoryPage());
        },
        child: SizedBox(
          width: 200,
          height: 200,
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.insert_drive_file, size: 100, color: Colors.black54),
              const SizedBox(height: 12),
              Text(
                t.receiveHistoryPage.title,
                style: const TextStyle(fontSize: 18, color: Colors.black87),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CornerButtons extends StatelessWidget {
  final bool showAdvanced;
  final bool showHistoryButton;
  final Future<void> Function() toggleAdvanced;

  const _CornerButtons({
    required this.showAdvanced,
    required this.showHistoryButton,
    required this.toggleAdvanced,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topRight,
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            if (!showAdvanced)
              AnimatedOpacity(
                opacity: showHistoryButton ? 1 : 0,
                duration: const Duration(milliseconds: 200),
                child: ExcludeFocus(
                  // The faded-out button must not be reachable by D-pad traversal.
                  excluding: !showHistoryButton,
                  child: CustomIconButton(
                    onPressed: () async {
                      await context.push(() => const ReceiveHistoryPage());
                    },
                    child: const Icon(Icons.history),
                  ),
                ),
              ),
            CustomIconButton(
              key: const ValueKey('info-btn'),
              onPressed: toggleAdvanced,
              child: const Icon(Icons.info),
            ),
          ],
        ),
      ),
    );
  }
}

class _InfoBox extends StatelessWidget {
  final ServerState? serverState;
  final List<String> localIps;
  final bool showAdvanced;

  const _InfoBox({
    required this.serverState,
    required this.localIps,
    required this.showAdvanced,
  });

  @override
  Widget build(BuildContext context) {
    return ExcludeFocus(
      // The faded-out info box contains selectable texts that would otherwise
      // still be reachable by D-pad traversal.
      excluding: !showAdvanced,
      child: AnimatedCrossFade(
        crossFadeState: showAdvanced ? CrossFadeState.showSecond : CrossFadeState.showFirst,
        duration: const Duration(milliseconds: 200),
        firstChild: Container(),
        secondChild: Align(
        alignment: Alignment.topRight,
        child: Padding(
          padding: const EdgeInsets.all(15),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(15),
              child: Table(
                columnWidths: const {
                  0: IntrinsicColumnWidth(),
                  1: IntrinsicColumnWidth(),
                  2: IntrinsicColumnWidth(),
                },
                children: [
                  TableRow(
                    children: [
                      Text(t.receiveTab.infoBox.alias),
                      const SizedBox(width: 10),
                      Padding(
                        padding: const EdgeInsets.only(right: 30),
                        child: SelectableText(serverState?.alias ?? '-'),
                      ),
                    ],
                  ),
                  TableRow(
                    children: [
                      Text(t.receiveTab.infoBox.ip),
                      const SizedBox(width: 10),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          if (localIps.isEmpty) Text(t.general.unknown),
                          ...localIps.map((ip) => SelectableText(ip)),
                        ],
                      ),
                    ],
                  ),
                  TableRow(
                    children: [
                      Text(t.receiveTab.infoBox.port),
                      const SizedBox(width: 10),
                      SelectableText(serverState?.port.toString() ?? '-'),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
      ),
    );
  }
}
