import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'benchmark_models.dart';

/// Modal dialog for configuring, starting, and reviewing benchmark suite results.
class BenchmarkDialog extends StatefulWidget {
  final BenchmarkSummary? lastSummary;
  final BenchmarkConfig initialConfig;

  const BenchmarkDialog({
    super.key,
    this.lastSummary,
    this.initialConfig = const BenchmarkConfig(),
  });

  @override
  State<BenchmarkDialog> createState() => _BenchmarkDialogState();
}

class _BenchmarkDialogState extends State<BenchmarkDialog> {
  late bool _isViewingResults;
  late BenchmarkTier _selectedTier;
  late int _selectedScale;
  late int _selectedIterations;
  late Set<BenchmarkOperation> _selectedOperations;

  static const List<int> _scalarScaleOptions = [10000, 50000, 100000];
  static const List<int> _vectorScaleOptions = [1000, 5000, 10000];
  static const List<int> _iterationOptions = [1, 3, 5];

  List<int> get _scaleOptions => _selectedTier == BenchmarkTier.vector
      ? _vectorScaleOptions
      : _scalarScaleOptions;

  List<BenchmarkOperation> get _visibleOperations => BenchmarkOperation.values
      .where((op) => op.appliesTo(_selectedTier))
      .toList();

  @override
  void initState() {
    super.initState();
    _isViewingResults = widget.lastSummary != null;
    final config = widget.lastSummary?.config ?? widget.initialConfig;
    _selectedTier = config.tier;
    _selectedIterations = config.iterations;
    _selectedOperations = Set.from(
      config.operations.where((op) => op.appliesTo(_selectedTier)),
    );
    if (_selectedOperations.isEmpty) {
      _selectedOperations = _defaultOpsForTier(_selectedTier);
    }
    _selectedScale = _clampScale(config.scale, _selectedTier);
  }

  Set<BenchmarkOperation> _defaultOpsForTier(BenchmarkTier tier) {
    if (tier == BenchmarkTier.vector) {
      return Set.from(BenchmarkOperation.defaultVectorOps);
    }
    if (tier == BenchmarkTier.all) {
      return {
        ...BenchmarkOperation.defaultScalarOps,
        ...BenchmarkOperation.defaultVectorOps,
      };
    }
    return Set.from(BenchmarkOperation.defaultScalarOps);
  }

  int _clampScale(int scale, BenchmarkTier tier) {
    final options = tier == BenchmarkTier.vector
        ? _vectorScaleOptions
        : _scalarScaleOptions;
    if (options.contains(scale)) return scale;
    // Pick nearest option.
    return options.reduce(
      (a, b) => (a - scale).abs() <= (b - scale).abs() ? a : b,
    );
  }

  void _onTierSelected(BenchmarkTier tier) {
    setState(() {
      _selectedTier = tier;
      _selectedScale = _clampScale(_selectedScale, tier);
      _selectedOperations = _defaultOpsForTier(tier);
    });
  }

  void _onStart([BenchmarkConfig? overrideConfig]) {
    if (overrideConfig == null && _selectedOperations.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Please select at least one benchmark operation.'),
          backgroundColor: Colors.redAccent,
        ),
      );
      return;
    }

    final config = overrideConfig ??
        BenchmarkConfig(
          tier: _selectedTier,
          scale: _selectedScale,
          iterations: _selectedIterations,
          operations: _selectedOperations,
        );

    Navigator.of(context).pop(config);
  }

  String _formatScaleLabel(int scale) {
    if (scale >= 1000) {
      return '${scale ~/ 1000}k';
    }
    return '$scale';
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return AlertDialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      titlePadding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(
                _isViewingResults
                    ? Icons.insights_rounded
                    : Icons.speed_rounded,
                color: primaryColor,
                size: 26,
              ),
              const SizedBox(width: 10),
              Text(
                _isViewingResults
                    ? 'Benchmark Results'
                    : 'Performance Benchmark',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
              ),
            ],
          ),
          if (widget.lastSummary != null)
            TextButton.icon(
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                visualDensity: VisualDensity.compact,
              ),
              icon: Icon(
                _isViewingResults
                    ? Icons.tune_rounded
                    : Icons.bar_chart_rounded,
                size: 16,
              ),
              label: Text(
                _isViewingResults ? 'Configure' : 'View Results',
                style: const TextStyle(fontSize: 13),
              ),
              onPressed: () {
                setState(() {
                  _isViewingResults = !_isViewingResults;
                });
              },
            ),
        ],
      ),
      content: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: _isViewingResults ? 760.0 : 620.0,
        ),
        child: _isViewingResults
            ? _buildResultsView(context, widget.lastSummary!)
            : _buildConfigView(context),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: [
        _buildActionBar(
          _isViewingResults
              ? _buildResultsActionButtons(context, widget.lastSummary!)
              : _buildConfigActionButtons(context),
        ),
      ],
    );
  }

  bool _isCompactActions(BuildContext context) =>
      MediaQuery.sizeOf(context).width < 420;

  /// Responsive action row: wraps on narrow screens instead of overlapping.
  Widget _buildActionBar(List<Widget> children) {
    return SizedBox(
      width: double.infinity,
      child: Wrap(
        spacing: 8,
        runSpacing: 10,
        alignment: WrapAlignment.end,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: children,
      ),
    );
  }

  // --- Results View Widgets ---

  Widget _buildResultsView(BuildContext context, BenchmarkSummary summary) {
    final primaryColor = Theme.of(context).colorScheme.primary;
    final dateStr = summary.timestamp.toIso8601String().split('T').first;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Header summary bar
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: const Color(0xFFE2E8F0)),
            ),
            child: Wrap(
              spacing: 12,
              runSpacing: 8,
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Wrap(
                  spacing: 8,
                  runSpacing: 6,
                  children: [
                    _buildBadge('Tier: ${summary.config.tier.label}',
                        primaryColor.withAlpha(25), primaryColor),
                    _buildBadge(
                        'Scale: ${_formatScaleLabel(summary.config.scale)} records',
                        Colors.grey.shade100,
                        const Color(0xFF334155)),
                    _buildBadge('${summary.config.iterations} Rounds',
                        Colors.grey.shade100, const Color(0xFF334155)),
                    _buildBadge(
                        dateStr, Colors.grey.shade100, const Color(0xFF64748B)),
                  ],
                ),
                OutlinedButton.icon(
                  style: OutlinedButton.styleFrom(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    visualDensity: VisualDensity.compact,
                    side: const BorderSide(color: Color(0xFFCBD5E1)),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  icon: const Icon(Icons.copy_rounded, size: 15),
                  label: const Text('Copy Markdown',
                      style: TextStyle(fontSize: 12.5)),
                  onPressed: () {
                    Clipboard.setData(
                        ClipboardData(text: summary.toMarkdownTable()));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content:
                            Text('✅ Benchmark Markdown copied to clipboard!'),
                        duration: Duration(seconds: 2),
                        backgroundColor: Color(0xFF006CC3),
                      ),
                    );
                  },
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),

          // Data Table
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: const Color(0xFFE2E8F0)),
                borderRadius: BorderRadius.circular(10),
              ),
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: DataTable(
                  headingRowColor: WidgetStateProperty.all(
                    const Color(0xFFF1F5F9),
                  ),
                  headingTextStyle: const TextStyle(
                    fontWeight: FontWeight.w700,
                    fontSize: 13,
                    color: Color(0xFF1E293B),
                  ),
                  dataRowMinHeight: 40,
                  dataRowMaxHeight: 48,
                  columnSpacing: 18,
                  horizontalMargin: 14,
                  columns: const [
                    DataColumn(label: Text('Model')),
                    DataColumn(label: Text('Operation')),
                    DataColumn(label: Text('Count'), numeric: true),
                    DataColumn(label: Text('Avg Time'), numeric: true),
                    DataColumn(label: Text('Result')),
                    DataColumn(label: Text('Avg Latency'), numeric: true),
                    DataColumn(label: Text('Min / Max'), numeric: true),
                  ],
                  rows: summary.metrics.map((m) {
                    final isQuality = m.compactHighlight != null;
                    return DataRow(
                      cells: [
                        DataCell(Text(m.tierName,
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w600))),
                        DataCell(Text(m.name,
                            style: const TextStyle(fontSize: 12.5))),
                        DataCell(Text('${m.recordCount}',
                            style: const TextStyle(
                                fontSize: 12.5, color: Color(0xFF64748B)))),
                        DataCell(Text(
                            isQuality
                                ? '—'
                                : '${m.avgMilliseconds.toStringAsFixed(2)} ms',
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w500))),
                        DataCell(
                          Tooltip(
                            message: m.qualityNote ?? m.highlightLabel,
                            waitDuration: const Duration(milliseconds: 400),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 6, vertical: 2),
                              decoration: BoxDecoration(
                                color: primaryColor.withAlpha(20),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                m.highlightLabel,
                                style: TextStyle(
                                  fontSize: 12.5,
                                  fontWeight: FontWeight.bold,
                                  color: primaryColor,
                                ),
                              ),
                            ),
                          ),
                        ),
                        DataCell(Text(
                            isQuality
                                ? '—'
                                : '${m.avgLatencyUs.toStringAsFixed(2)} μs',
                            style: const TextStyle(
                                fontSize: 12.5, color: Color(0xFF475569)))),
                        DataCell(Text(
                          isQuality
                              ? '—'
                              : '${(m.minMicroseconds / 1000.0).toStringAsFixed(1)} / ${(m.maxMicroseconds / 1000.0).toStringAsFixed(1)} ms',
                          style: const TextStyle(
                              fontSize: 12, color: Color(0xFF94A3B8)),
                        )),
                      ],
                    );
                  }).toList(),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBadge(String text, Color bgColor, Color textColor) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
            fontSize: 11.5, fontWeight: FontWeight.w600, color: textColor),
      ),
    );
  }

  List<Widget> _buildResultsActionButtons(
      BuildContext context, BenchmarkSummary summary) {
    final compact = _isCompactActions(context);
    final buttonPadding = EdgeInsets.symmetric(
      horizontal: compact ? 10 : 14,
      vertical: compact ? 8 : 10,
    );

    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          padding: buttonPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        icon: const Icon(Icons.tune_rounded, size: 18),
        label: Text(compact ? 'New' : 'New Benchmark'),
        onPressed: () {
          setState(() {
            _isViewingResults = false;
          });
        },
      ),
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: const Color.fromARGB(255, 10, 150, 210),
          padding: buttonPadding,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: Text(
          compact ? 'Re-run' : 'Re-run Test',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        onPressed: () => _onStart(summary.config),
      ),
    ];
  }

  // --- Configuration View Widgets ---

  Widget _buildConfigView(BuildContext context) {
    final theme = Theme.of(context);
    final primaryColor = theme.colorScheme.primary;

    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 1. Model Tier Selection
          _buildSectionTitle('1. Benchmark Model Tier'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: BenchmarkTier.values.map((tier) {
              final isSelected = _selectedTier == tier;
              return ChoiceChip(
                label: Text(tier.label),
                selected: isSelected,
                selectedColor: primaryColor.withAlpha(40),
                side: BorderSide(
                  color: isSelected ? primaryColor : Colors.grey.shade300,
                ),
                onSelected: (selected) {
                  if (selected) {
                    _onTierSelected(tier);
                  }
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // 2. Data Scale Selection
          _buildSectionTitle('2. Dataset Scale (Records)'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _scaleOptions.map((scale) {
              final isSelected = _selectedScale == scale;
              return ChoiceChip(
                label: Text('${_formatScaleLabel(scale)} records'),
                selected: isSelected,
                selectedColor: primaryColor.withAlpha(40),
                side: BorderSide(
                  color: isSelected ? primaryColor : Colors.grey.shade300,
                ),
                onSelected: (selected) {
                  if (selected) {
                    setState(() => _selectedScale = scale);
                  }
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // 3. Iteration Rounds
          _buildSectionTitle('3. Sampling Iterations'),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _iterationOptions.map((iter) {
              final isSelected = _selectedIterations == iter;
              return ChoiceChip(
                label: Text('$iter ${iter == 1 ? 'Round' : 'Rounds (Avg)'}'),
                selected: isSelected,
                selectedColor: primaryColor.withAlpha(40),
                side: BorderSide(
                  color: isSelected ? primaryColor : Colors.grey.shade300,
                ),
                onSelected: (selected) {
                  if (selected) {
                    setState(() => _selectedIterations = iter);
                  }
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // 4. Operations Selection
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildSectionTitle('4. Operations to Evaluate'),
              TextButton(
                onPressed: () {
                  setState(() {
                    final visible = _visibleOperations;
                    if (_selectedOperations.length == visible.length &&
                        visible.every(_selectedOperations.contains)) {
                      _selectedOperations.clear();
                    } else {
                      _selectedOperations = Set.from(visible);
                    }
                  });
                },
                child: Text(
                  _selectedOperations.length == _visibleOperations.length &&
                          _visibleOperations.every(_selectedOperations.contains)
                      ? 'Deselect All'
                      : 'Select All',
                  style: const TextStyle(fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: _visibleOperations.map((op) {
              final isSelected = _selectedOperations.contains(op);
              return FilterChip(
                label: Text(op.label),
                selected: isSelected,
                selectedColor: primaryColor.withAlpha(35),
                checkmarkColor: primaryColor,
                side: BorderSide(
                  color: isSelected ? primaryColor : Colors.grey.shade300,
                ),
                onSelected: (selected) {
                  setState(() {
                    if (selected) {
                      _selectedOperations.add(op);
                    } else {
                      _selectedOperations.remove(op);
                    }
                  });
                },
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildConfigActionButtons(BuildContext context) {
    final compact = _isCompactActions(context);

    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: const Color.fromARGB(255, 10, 150, 210),
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 14 : 20,
            vertical: compact ? 10 : 12,
          ),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: const Icon(Icons.play_arrow_rounded, size: 20),
        label: Text(
          compact ? 'Start' : 'Start Benchmark',
          style: const TextStyle(fontWeight: FontWeight.bold),
        ),
        onPressed: () => _onStart(),
      ),
    ];
  }

  Widget _buildSectionTitle(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: Color(0xFF334155),
      ),
    );
  }
}
