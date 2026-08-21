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

  static const List<int> _scaleOptions = [1000, 10000, 50000, 100000];
  static const List<int> _iterationOptions = [1, 3, 5];

  @override
  void initState() {
    super.initState();
    _isViewingResults = widget.lastSummary != null;
    final config = widget.lastSummary?.config ?? widget.initialConfig;
    _selectedTier = config.tier;
    _selectedScale = config.scale;
    _selectedIterations = config.iterations;
    _selectedOperations = Set.from(config.operations);
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
      actionsAlignment: MainAxisAlignment.end,
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 20),
      actions: _isViewingResults
          ? _buildResultsActions(context, widget.lastSummary!)
          : _buildConfigActions(context),
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
                  dataRowMaxHeight: 46,
                  columnSpacing: 18,
                  horizontalMargin: 14,
                  columns: const [
                    DataColumn(label: Text('Model')),
                    DataColumn(label: Text('Operation')),
                    DataColumn(label: Text('Count'), numeric: true),
                    DataColumn(label: Text('Avg Time'), numeric: true),
                    DataColumn(label: Text('Throughput'), numeric: true),
                    DataColumn(label: Text('Avg Latency'), numeric: true),
                    DataColumn(label: Text('Min / Max'), numeric: true),
                  ],
                  rows: summary.metrics.map((m) {
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
                            '${m.avgMilliseconds.toStringAsFixed(2)} ms',
                            style: const TextStyle(
                                fontSize: 12.5, fontWeight: FontWeight.w500))),
                        DataCell(
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: primaryColor.withAlpha(20),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              '${m.opsPerSec.toStringAsFixed(0)} ops/s',
                              style: TextStyle(
                                fontSize: 12.5,
                                fontWeight: FontWeight.bold,
                                color: primaryColor,
                              ),
                            ),
                          ),
                        ),
                        DataCell(Text('${m.avgLatencyUs.toStringAsFixed(2)} μs',
                            style: const TextStyle(
                                fontSize: 12.5, color: Color(0xFF475569)))),
                        DataCell(Text(
                          '${(m.minMicroseconds / 1000.0).toStringAsFixed(1)} / ${(m.maxMicroseconds / 1000.0).toStringAsFixed(1)} ms',
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

  List<Widget> _buildResultsActions(
      BuildContext context, BenchmarkSummary summary) {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Close'),
      ),
      const SizedBox(width: 8),
      OutlinedButton.icon(
        style: OutlinedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        icon: const Icon(Icons.tune_rounded, size: 18),
        label: const Text('New Benchmark'),
        onPressed: () {
          setState(() {
            _isViewingResults = false;
          });
        },
      ),
      const SizedBox(width: 8),
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: const Color.fromARGB(255, 10, 150, 210),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
          ),
        ),
        icon: const Icon(Icons.refresh_rounded, size: 18),
        label: const Text(
          'Re-run Test',
          style: TextStyle(fontWeight: FontWeight.bold),
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
                    setState(() => _selectedTier = tier);
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
                    if (_selectedOperations.length ==
                        BenchmarkOperation.values.length) {
                      _selectedOperations.clear();
                    } else {
                      _selectedOperations = Set.from(BenchmarkOperation.values);
                    }
                  });
                },
                child: Text(
                  _selectedOperations.length == BenchmarkOperation.values.length
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
            children: BenchmarkOperation.values.map((op) {
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

  List<Widget> _buildConfigActions(BuildContext context) {
    return [
      TextButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('Cancel'),
      ),
      const SizedBox(width: 8),
      ElevatedButton.icon(
        style: ElevatedButton.styleFrom(
          foregroundColor: Colors.white,
          backgroundColor: const Color.fromARGB(255, 10, 150, 210),
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        icon: const Icon(Icons.play_arrow_rounded, size: 20),
        label: const Text(
          'Start Benchmark',
          style: TextStyle(fontWeight: FontWeight.bold),
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
