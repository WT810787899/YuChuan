import 'dart:async';

import 'package:flutter/material.dart' hide Notification;
import 'package:rust_flutter_ui/src/rust/api/dashboard.dart';
import 'package:rust_flutter_ui/src/rust/frb_generated.dart';

/// Global theme controller so the Settings page can toggle light/dark mode.
final ValueNotifier<ThemeMode> themeModeNotifier = ValueNotifier(ThemeMode.light);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await RustLib.init();
  runApp(const MyApp());
}

// ============================================================
// App shell
// ============================================================

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeModeNotifier,
      builder: (context, mode, _) {
        return MaterialApp(
          title: 'Rust + Flutter Dashboard',
          debugShowCheckedModeBanner: false,
          theme: _buildTheme(Brightness.light),
          darkTheme: _buildTheme(Brightness.dark),
          themeMode: mode,
          home: const MainScreen(),
        );
      },
    );
  }
}

ThemeData _buildTheme(Brightness brightness) {
  final scheme = ColorScheme.fromSeed(
    seedColor: const Color(0xFF6366F1),
    brightness: brightness,
  );
  final isLight = brightness == Brightness.light;
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor:
        isLight ? const Color(0xFFF6F7FB) : const Color(0xFF101116),
    cardTheme: CardThemeData(
      elevation: 0,
      margin: EdgeInsets.zero,
      color: isLight ? Colors.white : const Color(0xFF1A1B22),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: isLight ? Colors.black.withValues(alpha: 0.06) : Colors.white.withValues(alpha: 0.06),
        ),
      ),
    ),
    appBarTheme: AppBarTheme(
      backgroundColor: Colors.transparent,
      elevation: 0,
      scrolledUnderElevation: 0,
      foregroundColor: scheme.onSurface,
    ),
    navigationRailTheme: NavigationRailThemeData(
      backgroundColor: isLight ? Colors.white : const Color(0xFF15161C),
      indicatorColor: const Color(0xFF6366F1).withValues(alpha: 0.14),
      selectedIconTheme: const IconThemeData(color: Color(0xFF6366F1)),
      unselectedIconTheme: IconThemeData(color: Colors.grey.shade500),
      labelType: NavigationRailLabelType.all,
      selectedLabelTextStyle: const TextStyle(
        fontWeight: FontWeight.w600,
        color: Color(0xFF6366F1),
      ),
      unselectedLabelTextStyle: TextStyle(color: Colors.grey.shade600),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: scheme.surfaceContainerHighest.withValues(alpha: 0.5),
      isDense: true,
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: scheme.primary, width: 1.4),
      ),
    ),
    chipTheme: ChipThemeData(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      side: BorderSide.none,
    ),
  );
}

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int _selectedIndex = 0;

  static const _titles = ['Dashboard', 'Users', 'Products', 'Alerts', 'Settings'];
  static const _subtitles = [
    'Overview of your platform',
    'Manage team members',
    'Catalog inventory',
    'Recent notifications',
    'Preferences & about',
  ];

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Row(
        children: [
          NavigationRail(
            selectedIndex: _selectedIndex,
            onDestinationSelected: (i) => setState(() => _selectedIndex = i),
            leading: const _RailLogo(),
            trailing: Expanded(
              child: Align(
                alignment: Alignment.bottomCenter,
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 16),
                  child: ValueListenableBuilder<ThemeMode>(
                    valueListenable: themeModeNotifier,
                    builder: (context, mode, _) {
                      final dark = mode == ThemeMode.dark ||
                          (mode == ThemeMode.system &&
                              Theme.of(context).brightness == Brightness.dark);
                      return IconButton(
                        tooltip: dark ? 'Switch to light mode' : 'Switch to dark mode',
                        icon: Icon(dark ? Icons.light_mode_outlined : Icons.dark_mode_outlined),
                        onPressed: () {
                          themeModeNotifier.value =
                              dark ? ThemeMode.light : ThemeMode.dark;
                        },
                      );
                    },
                  ),
                ),
              ),
            ),
            destinations: const [
              NavigationRailDestination(
                icon: Icon(Icons.dashboard_outlined),
                selectedIcon: Icon(Icons.dashboard),
                label: Text('Dashboard'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.people_outline),
                selectedIcon: Icon(Icons.people),
                label: Text('Users'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.inventory_2_outlined),
                selectedIcon: Icon(Icons.inventory_2),
                label: Text('Products'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.notifications_outlined),
                selectedIcon: Icon(Icons.notifications),
                label: Text('Alerts'),
              ),
              NavigationRailDestination(
                icon: Icon(Icons.settings_outlined),
                selectedIcon: Icon(Icons.settings),
                label: Text('Settings'),
              ),
            ],
          ),
          const VerticalDivider(width: 1, thickness: 1),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(28, 24, 28, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              _titles[_selectedIndex],
                              style: Theme.of(context)
                                  .textTheme
                                  .headlineSmall
                                  ?.copyWith(fontWeight: FontWeight.w700),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              _subtitles[_selectedIndex],
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
                            ),
                          ],
                        ),
                      ),
                      const _RustBadge(),
                    ],
                  ),
                ),
                Expanded(
                  child: IndexedStack(
                    index: _selectedIndex,
                    children: const [
                      DashboardPage(),
                      UsersPage(),
                      ProductsPage(),
                      NotificationsPage(),
                      SettingsPage(),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RailLogo extends StatelessWidget {
  const _RailLogo();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 16, 0, 24),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(14),
          gradient: const LinearGradient(
            colors: [Color(0xFF6366F1), Color(0xFF8B5CF6)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
        ),
        child: const Icon(Icons.terminal, color: Colors.white, size: 24),
      ),
    );
  }
}

class _RustBadge extends StatelessWidget {
  const _RustBadge();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      decoration: BoxDecoration(
        color: scheme.primaryContainer,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.bolt, size: 16, color: scheme.onPrimaryContainer),
          const SizedBox(width: 6),
          Text(
            'Powered by Rust',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onPrimaryContainer,
            ),
          ),
        ],
      ),
    );
  }
}

// ============================================================
// Shared helpers
// ============================================================

String fmtInt(int n) {
  final s = n.toString();
  final buf = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) {
      buf.write(',');
    }
    buf.write(s[i]);
  }
  return buf.toString();
}

Color colorFromInt(int value) => Color(value);

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.cloud_off_outlined, size: 48, color: Colors.grey.shade400),
          const SizedBox(height: 12),
          Text('Failed to load data from Rust backend',
              style: TextStyle(color: Colors.grey.shade600)),
          const SizedBox(height: 4),
          Text(message,
              style: TextStyle(fontSize: 12, color: Colors.grey.shade500)),
          const SizedBox(height: 16),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Retry'),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.title, this.trailing});

  final String title;
  final Widget? trailing;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 14),
      child: Row(
        children: [
          Expanded(
            child: Text(
              title,
              style: Theme.of(context)
                  .textTheme
                  .titleMedium
                  ?.copyWith(fontWeight: FontWeight.w700),
            ),
          ),
          if (trailing != null) trailing!,
        ],
      ),
    );
  }
}

// ============================================================
// Dashboard page
// ============================================================

class DashboardPage extends StatefulWidget {
  const DashboardPage({super.key});

  @override
  State<DashboardPage> createState() => _DashboardPageState();
}

class _DashboardPageState extends State<DashboardPage>
    with AutomaticKeepAliveClientMixin {
  late Future<DashboardStats> _stats;
  late Future<List<ActivityLog>> _activity;
  late Future<Map<String, String>> _health;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  void _load() {
    setState(() {
      _stats = getDashboardStats();
      _activity = getActivityLogs();
      _health = getSystemHealth();
    });
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
      children: [
        Row(
          children: [
            const Expanded(child: SizedBox()),
            OutlinedButton.icon(
              onPressed: _load,
              icon: const Icon(Icons.refresh, size: 18),
              label: const Text('Refresh'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        FutureBuilder<DashboardStats>(
          future: _stats,
          builder: (context, snap) {
            if (snap.connectionState == ConnectionState.waiting) {
              return const _StatsSkeleton();
            }
            if (snap.hasError) {
              return SizedBox(
                height: 220,
                child: _ErrorView(message: '${snap.error}', onRetry: _load),
              );
            }
            final stats = snap.data!;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _StatsGrid(stats: stats),
                const SizedBox(height: 20),
                LayoutBuilder(
                  builder: (context, constraints) {
                    final chart = _ChartCard(points: stats.chartData);
                    final health = _HealthCard(future: _health, onRetry: _load);
                    if (constraints.maxWidth < 940) {
                      return Column(
                        children: [
                          chart,
                          const SizedBox(height: 20),
                          health,
                        ],
                      );
                    }
                    return Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(flex: 3, child: chart),
                        const SizedBox(width: 20),
                        Expanded(flex: 2, child: health),
                      ],
                    );
                  },
                ),
                const SizedBox(height: 20),
                _ActivityCard(future: _activity, onRetry: _load),
              ],
            );
          },
        ),
      ],
    );
  }
}

class _StatsSkeleton extends StatelessWidget {
  const _StatsSkeleton();

  @override
  Widget build(BuildContext context) {
    return const SizedBox(
      height: 120,
      child: Center(child: CircularProgressIndicator()),
    );
  }
}

class _StatsGrid extends StatelessWidget {
  const _StatsGrid({required this.stats});

  final DashboardStats stats;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth < 760
            ? 2
            : constraints.maxWidth < 1100
                ? 4
                : 4;
        return GridView.count(
          crossAxisCount: columns,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 16,
          crossAxisSpacing: 16,
          childAspectRatio: 2.35,
          children: [
            _StatCard(
              title: 'Total Users',
              value: fmtInt(stats.totalUsers),
              caption: 'All registered accounts',
              icon: Icons.people_alt_outlined,
              color: const Color(0xFF6366F1),
            ),
            _StatCard(
              title: 'Active Users',
              value: fmtInt(stats.activeUsers),
              caption: 'Active in the last 30 days',
              icon: Icons.bolt_outlined,
              color: const Color(0xFF10B981),
            ),
            _StatCard(
              title: 'Revenue',
              value: '\$${fmtInt(stats.totalRevenue.toInt())}',
              caption: 'Current billing period',
              icon: Icons.payments_outlined,
              color: const Color(0xFFF59E0B),
            ),
            _StatCard(
              title: 'Growth',
              value: '+${stats.growthRate}%',
              caption: 'vs. previous quarter',
              icon: Icons.trending_up,
              color: const Color(0xFF8B5CF6),
            ),
          ],
        );
      },
    );
  }
}

class _StatCard extends StatelessWidget {
  const _StatCard({
    required this.title,
    required this.value,
    required this.caption,
    required this.icon,
    required this.color,
  });

  final String title;
  final String value;
  final String caption;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                color: color.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(14),
              ),
              child: Icon(icon, color: color, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.outline,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 2),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      value,
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  Text(
                    caption,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11, color: scheme.outline),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ChartCard extends StatelessWidget {
  const _ChartCard({required this.points});

  final List<ChartPoint> points;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final maxV = points.isEmpty
        ? 1.0
        : points.map((p) => p.value).reduce((a, b) => a > b ? a : b);

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(
              title: 'Revenue Trend',
              trailing: Chip(
                avatar: const Icon(Icons.show_chart, size: 16),
                label: const Text('8 months'),
                backgroundColor: scheme.primaryContainer,
                labelStyle: TextStyle(
                  fontSize: 12,
                  color: scheme.onPrimaryContainer,
                ),
              ),
            ),
            SizedBox(
              height: 230,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  for (final p in points)
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 7),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Text(
                              '${(p.value / 1000).toStringAsFixed(1)}k',
                              style: TextStyle(
                                fontSize: 10.5,
                                color: scheme.outline,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Expanded(
                              child: Align(
                                alignment: Alignment.bottomCenter,
                                child: FractionallySizedBox(
                                  heightFactor:
                                      0.12 + 0.88 * (p.value / maxV),
                                  widthFactor: 0.72,
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(
                                      gradient: LinearGradient(
                                        begin: Alignment.bottomCenter,
                                        end: Alignment.topCenter,
                                        colors: [
                                          colorFromInt(p.color),
                                          colorFromInt(p.color)
                                              .withValues(alpha: 0.55),
                                        ],
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Text(
                              p.label,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.outline,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthCard extends StatelessWidget {
  const _HealthCard({required this.future, required this.onRetry});

  final Future<Map<String, String>> future;
  final VoidCallback onRetry;

  static const _rows = [
    ('CPU usage', 'cpu_usage'),
    ('Memory usage', 'memory_usage'),
    ('Disk usage', 'disk_usage'),
    ('Network latency', 'network_latency'),
    ('Uptime', 'uptime'),
  ];

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SectionHeader(title: 'System Health'),
            FutureBuilder<Map<String, String>>(
              future: future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return SizedBox(
                    height: 160,
                    child: _ErrorView(message: '${snap.error}', onRetry: onRetry),
                  );
                }
                final health = snap.data!;
                final status = health['status'] ?? 'Unknown';
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 7),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle,
                              size: 16, color: Color(0xFF10B981)),
                          const SizedBox(width: 6),
                          Text(
                            status,
                            style: const TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w700,
                              color: Color(0xFF10B981),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    for (final (label, key) in _rows)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 14),
                        child: _HealthRow(
                          label: label,
                          value: health[key] ?? '--',
                        ),
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _HealthRow extends StatelessWidget {
  const _HealthRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pct = value.endsWith('%')
        ? (double.tryParse(value.replaceAll('%', '')) ?? 0) / 100
        : null;
    final color = pct == null
        ? scheme.primary
        : pct > 0.8
            ? const Color(0xFFEF4444)
            : pct > 0.6
                ? const Color(0xFFF59E0B)
                : const Color(0xFF10B981);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(label,
                  style: TextStyle(fontSize: 12.5, color: scheme.outline)),
            ),
            Text(
              value,
              style: const TextStyle(fontSize: 12.5, fontWeight: FontWeight.w700),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(99),
          child: LinearProgressIndicator(
            value: pct,
            minHeight: 6,
            backgroundColor: scheme.primary.withValues(alpha: 0.1),
            valueColor: AlwaysStoppedAnimation(color),
          ),
        ),
      ],
    );
  }
}

class _ActivityCard extends StatelessWidget {
  const _ActivityCard({required this.future, required this.onRetry});

  final Future<List<ActivityLog>> future;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const _SectionHeader(title: 'Recent Activity'),
            FutureBuilder<List<ActivityLog>>(
              future: future,
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(child: CircularProgressIndicator()),
                  );
                }
                if (snap.hasError) {
                  return SizedBox(
                    height: 160,
                    child: _ErrorView(message: '${snap.error}', onRetry: onRetry),
                  );
                }
                final items = snap.data!;
                return Column(
                  children: [
                    for (var i = 0; i < items.length; i++)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: _SeverityDot(severity: items[i].severity),
                        title: Text(
                          '${items[i].user} — ${items[i].action}',
                          style: const TextStyle(
                              fontWeight: FontWeight.w600, fontSize: 14),
                        ),
                        subtitle: Text(
                          '${items[i].target}  •  ${items[i].timestamp}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: Theme.of(context).colorScheme.outline,
                          ),
                        ),
                        trailing: _SeverityChip(severity: items[i].severity),
                        onTap: () {
                          ScaffoldMessenger.of(context).showSnackBar(
                            SnackBar(
                              content: Text(
                                  '${items[i].user}: ${items[i].action} (${items[i].target})'),
                              behavior: SnackBarBehavior.floating,
                            ),
                          );
                        },
                      ),
                  ],
                );
              },
            ),
          ],
        ),
      ),
    );
  }
}

const _severityColors = {
  Severity.low: Color(0xFF3B82F6),
  Severity.medium: Color(0xFFF59E0B),
  Severity.high: Color(0xFFEF4444),
  Severity.critical: Color(0xFF8B5CF6),
};

const _severityLabels = {
  Severity.low: 'Low',
  Severity.medium: 'Medium',
  Severity.high: 'High',
  Severity.critical: 'Critical',
};

class _SeverityDot extends StatelessWidget {
  const _SeverityDot({required this.severity});

  final Severity severity;

  @override
  Widget build(BuildContext context) {
    final color = _severityColors[severity] ?? Colors.grey;
    return Container(
      width: 38,
      height: 38,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        shape: BoxShape.circle,
      ),
      child: Icon(
        severity == Severity.critical
            ? Icons.warning_amber
            : severity == Severity.high
                ? Icons.error_outline
                : Icons.info_outline,
        color: color,
        size: 20,
      ),
    );
  }
}

class _SeverityChip extends StatelessWidget {
  const _SeverityChip({required this.severity});

  final Severity severity;

  @override
  Widget build(BuildContext context) {
    final color = _severityColors[severity] ?? Colors.grey;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        _severityLabels[severity] ?? '?',
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

// ============================================================
// Users page
// ============================================================

class UsersPage extends StatefulWidget {
  const UsersPage({super.key});

  @override
  State<UsersPage> createState() => _UsersPageState();
}

class _UsersPageState extends State<UsersPage>
    with AutomaticKeepAliveClientMixin {
  final _controller = TextEditingController();
  Timer? _debounce;
  List<User> _users = [];
  bool _loading = true;
  String? _error;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _search('');
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    super.dispose();
  }

  Future<void> _search(String query) async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final result = await searchUsers(query: query);
      if (!mounted) return;
      setState(() => _users = result);
    } catch (e) {
      if (!mounted) return;
      setState(() => _error = '$e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _onQueryChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 350), () => _search(query));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _controller,
                  onChanged: _onQueryChanged,
                  decoration: InputDecoration(
                    hintText: 'Search by name or email…',
                    prefixIcon: const Icon(Icons.search, size: 20),
                    suffixIcon: _controller.text.isEmpty
                        ? null
                        : IconButton(
                            icon: const Icon(Icons.clear, size: 18),
                            onPressed: () {
                              _controller.clear();
                              _onQueryChanged('');
                              setState(() {});
                            },
                          ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(
                '${_users.length} users',
                style: TextStyle(color: scheme.outline, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _error != null
                    ? _ErrorView(message: _error!, onRetry: () => _search(_controller.text))
                    : _users.isEmpty
                        ? Center(
                            child: Text(
                              'No users match "${_controller.text}"',
                              style: TextStyle(color: scheme.outline),
                            ),
                          )
                        : ListView.separated(
                            itemCount: _users.length,
                            separatorBuilder: (_, __) => const SizedBox(height: 10),
                            itemBuilder: (context, i) => _UserTile(user: _users[i]),
                          ),
          ),
        ],
      ),
    );
  }
}

class _UserTile extends StatelessWidget {
  const _UserTile({required this.user});

  final User user;

  static const _roleLabels = {
    UserRole.admin: 'Admin',
    UserRole.editor: 'Editor',
    UserRole.viewer: 'Viewer',
  };

  static const _roleColors = {
    UserRole.admin: Color(0xFF6366F1),
    UserRole.editor: Color(0xFF10B981),
    UserRole.viewer: Color(0xFFF59E0B),
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final roleColor = _roleColors[user.role] ?? scheme.primary;
    final initials = user.name
        .split(' ')
        .map((w) => w.isEmpty ? '' : w[0])
        .take(2)
        .join()
        .toUpperCase();

    return Card(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            CircleAvatar(
              radius: 24,
              backgroundColor: colorFromInt(user.avatarColor),
              child: Text(
                initials,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.w700,
                  fontSize: 15,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.name,
                    style: const TextStyle(
                        fontWeight: FontWeight.w700, fontSize: 15),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    user.email,
                    style:
                        TextStyle(fontSize: 12.5, color: scheme.outline),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: roleColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(999),
              ),
              child: Text(
                _roleLabels[user.role] ?? '?',
                style: TextStyle(
                  fontSize: 11.5,
                  fontWeight: FontWeight.w700,
                  color: roleColor,
                ),
              ),
            ),
            const SizedBox(width: 14),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      user.isActive ? Icons.check_circle : Icons.cancel,
                      size: 15,
                      color: user.isActive
                          ? const Color(0xFF10B981)
                          : Colors.grey.shade400,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      user.isActive ? 'Active' : 'Inactive',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: user.isActive
                            ? const Color(0xFF10B981)
                            : Colors.grey.shade500,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  'Joined ${user.createdAt}',
                  style: TextStyle(fontSize: 11, color: scheme.outline),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Products page
// ============================================================

class ProductsPage extends StatefulWidget {
  const ProductsPage({super.key});

  @override
  State<ProductsPage> createState() => _ProductsPageState();
}

class _ProductsPageState extends State<ProductsPage>
    with AutomaticKeepAliveClientMixin {
  late Future<List<Product>> _products;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _products = getProducts();
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return FutureBuilder<List<Product>>(
      future: _products,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorView(
            message: '${snap.error}',
            onRetry: () => setState(() => _products = getProducts()),
          );
        }
        final products = snap.data!;
        return GridView.builder(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 300,
            mainAxisSpacing: 16,
            crossAxisSpacing: 16,
            childAspectRatio: 0.74,
          ),
          itemCount: products.length,
          itemBuilder: (context, i) => _ProductCard(product: products[i]),
        );
      },
    );
  }
}

class _ProductCard extends StatelessWidget {
  const _ProductCard({required this.product});

  final Product product;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final lowStock = product.stock < 20;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
                  decoration: BoxDecoration(
                    color: scheme.primaryContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    product.category,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: scheme.onPrimaryContainer,
                    ),
                  ),
                ),
                const Spacer(),
                const Icon(Icons.star_rounded, size: 17, color: Color(0xFFF59E0B)),
                const SizedBox(width: 3),
                Text(
                  product.rating.toStringAsFixed(1),
                  style: const TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w700),
                ),
              ],
            ),
            const SizedBox(height: 14),
            Text(
              product.name,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
            ),
            const SizedBox(height: 6),
            Text(
              '\$${product.price.toStringAsFixed(2)}',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: scheme.primary,
              ),
            ),
            const Spacer(),
            Row(
              children: [
                Icon(Icons.inventory_2_outlined,
                    size: 15,
                    color: lowStock
                        ? const Color(0xFFEF4444)
                        : scheme.outline),
                const SizedBox(width: 5),
                Text(
                  lowStock ? 'Low stock · ${product.stock}' : '${product.stock} in stock',
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: lowStock
                        ? const Color(0xFFEF4444)
                        : scheme.outline,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final tag in product.tags)
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: scheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(7),
                    ),
                    child: Text(
                      '#$tag',
                      style: TextStyle(fontSize: 11, color: scheme.outline),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ============================================================
// Notifications page
// ============================================================

class NotificationsPage extends StatefulWidget {
  const NotificationsPage({super.key});

  @override
  State<NotificationsPage> createState() => _NotificationsPageState();
}

class _NotificationsPageState extends State<NotificationsPage>
    with AutomaticKeepAliveClientMixin {
  late Future<List<Notification>> _notifications;
  final Set<String> _readIds = {};

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _notifications = getNotifications();
  }

  static const _typeIcons = {
    NotificationType.info: Icons.info_outline,
    NotificationType.success: Icons.check_circle_outline,
    NotificationType.warning: Icons.warning_amber_outlined,
    NotificationType.error: Icons.error_outline,
  };

  static const _typeColors = {
    NotificationType.info: Color(0xFF3B82F6),
    NotificationType.success: Color(0xFF10B981),
    NotificationType.warning: Color(0xFFF59E0B),
    NotificationType.error: Color(0xFFEF4444),
  };

  bool _isUnread(Notification n) => !n.isRead && !_readIds.contains(n.id);

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    return FutureBuilder<List<Notification>>(
      future: _notifications,
      builder: (context, snap) {
        if (snap.connectionState == ConnectionState.waiting) {
          return const Center(child: CircularProgressIndicator());
        }
        if (snap.hasError) {
          return _ErrorView(
            message: '${snap.error}',
            onRetry: () =>
                setState(() => _notifications = getNotifications()),
          );
        }
        final items = snap.data!;
        final unread = items.where(_isUnread).length;
        return ListView(
          padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
                  decoration: BoxDecoration(
                    color: unread > 0
                        ? const Color(0xFFEF4444).withValues(alpha: 0.12)
                        : scheme.surfaceContainerHighest,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '$unread unread',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: unread > 0
                          ? const Color(0xFFEF4444)
                          : scheme.outline,
                    ),
                  ),
                ),
                const Spacer(),
                TextButton.icon(
                  onPressed: unread == 0
                      ? null
                      : () => setState(() {
                            for (final n in items) {
                              _readIds.add(n.id);
                            }
                          }),
                  icon: const Icon(Icons.done_all, size: 18),
                  label: const Text('Mark all read'),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: () =>
                      setState(() => _notifications = getNotifications()),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            const SizedBox(height: 12),
            for (final n in items)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _NotificationTile(
                  notification: n,
                  unread: _isUnread(n),
                  icon: _typeIcons[n.notificationType] ?? Icons.info_outline,
                  color: _typeColors[n.notificationType] ?? scheme.primary,
                  onTap: () => setState(() => _readIds.add(n.id)),
                ),
              ),
          ],
        );
      },
    );
  }
}

class _NotificationTile extends StatelessWidget {
  const _NotificationTile({
    required this.notification,
    required this.unread,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  final Notification notification;
  final bool unread;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(18),
        side: BorderSide(
          color: unread
              ? color.withValues(alpha: 0.45)
              : scheme.outlineVariant.withValues(alpha: 0.4),
          width: unread ? 1.4 : 1,
        ),
      ),
      child: InkWell(
        borderRadius: BorderRadius.circular(18),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(icon, color: color, size: 21),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            notification.title,
                            style: TextStyle(
                              fontWeight:
                                  unread ? FontWeight.w800 : FontWeight.w600,
                              fontSize: 14.5,
                            ),
                          ),
                        ),
                        if (unread)
                          Container(
                            width: 9,
                            height: 9,
                            decoration: BoxDecoration(
                              color: color,
                              shape: BoxShape.circle,
                            ),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      notification.message,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.outline,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      notification.timestamp,
                      style: TextStyle(fontSize: 11.5, color: scheme.outline),
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

// ============================================================
// Settings page
// ============================================================

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage>
    with AutomaticKeepAliveClientMixin {
  bool _emailAlerts = true;
  bool _desktopPush = false;
  bool _compactDensity = false;
  double _refreshMinutes = 15;

  late Future<double> _projection;

  @override
  bool get wantKeepAlive => true;

  @override
  void initState() {
    super.initState();
    _projection = calculateRevenue(months: 12);
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 16, 28, 28),
      children: [
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 760),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const _SectionHeader(title: 'Appearance'),
              Card(
                child: Column(
                  children: [
                    ValueListenableBuilder<ThemeMode>(
                      valueListenable: themeModeNotifier,
                      builder: (context, mode, _) {
                        return SwitchListTile(
                          secondary:
                              const Icon(Icons.dark_mode_outlined),
                          title: const Text('Dark mode'),
                          subtitle: const Text(
                              'Switch between light and dark themes'),
                          value: mode == ThemeMode.dark,
                          onChanged: (v) {
                            themeModeNotifier.value =
                                v ? ThemeMode.dark : ThemeMode.light;
                          },
                        );
                      },
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                      secondary: const Icon(Icons.compress_outlined),
                      title: const Text('Compact density'),
                      subtitle:
                          const Text('Reduce spacing across lists and cards'),
                      value: _compactDensity,
                      onChanged: (v) =>
                          setState(() => _compactDensity = v),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const _SectionHeader(title: 'Notifications'),
              Card(
                child: Column(
                  children: [
                    SwitchListTile(
                      secondary: const Icon(Icons.mail_outline),
                      title: const Text('Email alerts'),
                      subtitle: const Text(
                          'Receive a daily digest of platform activity'),
                      value: _emailAlerts,
                      onChanged: (v) => setState(() => _emailAlerts = v),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    SwitchListTile(
                      secondary: const Icon(Icons.notifications_active_outlined),
                      title: const Text('Desktop push'),
                      subtitle:
                          const Text('Show native push notifications'),
                      value: _desktopPush,
                      onChanged: (v) =>
                          setState(() => _desktopPush = v),
                    ),
                    const Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: const Icon(Icons.timer_outlined),
                      title: const Text('Auto refresh interval'),
                      subtitle: Slider(
                        value: _refreshMinutes,
                        min: 5,
                        max: 60,
                        divisions: 11,
                        label: '${_refreshMinutes.round()} min',
                        onChanged: (v) =>
                            setState(() => _refreshMinutes = v),
                      ),
                      trailing: Text(
                        '${_refreshMinutes.round()} min',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: scheme.primary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const _SectionHeader(title: 'Rust Backend'),
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(20),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      _InfoRow(label: 'Bridge', value: 'flutter_rust_bridge 2.8.0'),
                      _InfoRow(label: 'Rust toolchain', value: 'rustc 1.95.0'),
                      _InfoRow(label: 'Codec', value: 'PDE (dart ⇄ rust)'),
                      const Divider(height: 26),
                      FutureBuilder<double>(
                        future: _projection,
                        builder: (context, snap) {
                          final value = snap.hasData
                              ? '\$${fmtInt(snap.data!.toInt())}'
                              : snap.hasError
                                  ? 'error'
                                  : 'computing…';
                          return Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.start,
                                  children: [
                                    Text(
                                      'Projected revenue (12 months)',
                                      style: TextStyle(
                                        fontSize: 12.5,
                                        color: scheme.outline,
                                      ),
                                    ),
                                    const SizedBox(height: 4),
                                    Text(
                                      value,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.w800,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              FilledButton.tonalIcon(
                                onPressed: () => setState(() =>
                                    _projection = calculateRevenue(
                                        months: 12)),
                                icon: const Icon(Icons.cached, size: 18),
                                label: const Text('Recalculate in Rust'),
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 24),
              const _SectionHeader(title: 'About'),
              Card(
                child: Column(
                  children: const [
                    ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text('Rust + Flutter UI Showcase'),
                      subtitle: Text('Version 1.0.0+1'),
                    ),
                    Divider(height: 1, indent: 16, endIndent: 16),
                    ListTile(
                      leading: Icon(Icons.code_outlined),
                      title: Text('Flutter 3.32.8 · Dart 3.8.1'),
                      subtitle:
                          Text('Desktop target: Windows x64'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 40),
            ],
          ),
        ),
      ],
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        children: [
          Expanded(
            child: Text(label,
                style: TextStyle(fontSize: 13, color: scheme.outline)),
          ),
          Text(
            value,
            style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
          ),
        ],
      ),
    );
  }
}
