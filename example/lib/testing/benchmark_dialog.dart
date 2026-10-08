import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:tostore/tostore.dart';

import 'benchmark_image_export.dart';
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
  late RecoveryDurability _selectedDurability;
  late Set<BenchmarkOperation> _selectedOperations;

  final GlobalKey _captureKey = GlobalKey();
  bool _savingImage = false;

  static const List<int> _scalarScaleOptions = [10000, 50000, 100000];
  static const List<int> _vectorScaleOptions = [1000, 5000, 10000];
  static const List<int> _iterationOptions = [1, 3, 5];
  static const List<RecoveryDurability> _durabilityOptions = [
    RecoveryDurability.async,
    RecoveryDurability.standard,
    RecoveryDurability.durable,
  ];

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
    _selectedDurability = config.durability;
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
          durability: _selectedDurability,
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
      // Results view embeds logo+title inside the capture card; keep dialog
      // title chrome minimal there so Save Image does not need a second header.
      title: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          if (_isViewingResults)
            const SizedBox.shrink()
          else
            Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Image.asset(
                  'assets/logo-tostore.png',
                  height: 36,
                  fit: BoxFit.contain,
                  errorBuilder: (context, error, stackTrace) => Icon(
                    Icons.speed_rounded,
                    color: primaryColor,
                    size: 28,
                  ),
                ),
                const SizedBox(width: 10),
                const Text(
                  'Performance Benchmark',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    color: Color(0xFF0F172A),
                  ),
                ),
              ],
            ),
          // Results actions live in the bottom "More" menu; config view keeps
          // a single View Results shortcut when a prior run exists.
          if (!_isViewingResults && widget.lastSummary != null)
            TextButton.icon(
              style: TextButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                visualDensity: VisualDensity.compact,
              ),
              icon: const Icon(Icons.bar_chart_rounded, size: 16),
              label: const Text(
                'View Results',
                style: TextStyle(fontSize: 13),
              ),
              onPressed: () {
                setState(() => _isViewingResults = true);
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
        if (_isViewingResults)
          _buildResultsActionBar(context, widget.lastSummary!)
        else
          _buildActionBar(_buildConfigActionButtons(context)),
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

    // Capture card excludes dialog chrome / action buttons / Copy Markdown.
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          RepaintBoundary(
            key: _captureKey,
            child: ColoredBox(
              color: Colors.white,
              child: Padding(
                // Match standalone showcase card margins (balanced on all sides).
                padding: const EdgeInsets.fromLTRB(24, 22, 24, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Image.asset(
                          'assets/logo-tostore.png',
                          height: 36,
                          fit: BoxFit.contain,
                          errorBuilder: (_, __, ___) => Icon(
                            Icons.speed_rounded,
                            size: 28,
                            color: primaryColor,
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'Benchmark Results',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFF0F172A),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 14),
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: const Color(0xFFE2E8F0)),
                      ),
                      child: Wrap(
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
                              'Durability: ${summary.config.durability.benchmarkLabel}',
                              Colors.grey.shade100,
                              const Color(0xFF334155)),
                          _buildBadge(dateStr, Colors.grey.shade100,
                              const Color(0xFF64748B)),
                        ],
                      ),
                    ),
                    const SizedBox(height: 16),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: Container(
                            decoration: BoxDecoration(
                              border:
                                  Border.all(color: const Color(0xFFE2E8F0)),
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: DataTable(
                              headingRowColor: WidgetStateProperty.all(
                                const Color(0xFFE8EEF5),
                              ),
                              headingTextStyle: const TextStyle(
                                fontWeight: FontWeight.w700,
                                fontSize: 13,
                                color: Color(0xFF0F172A),
                              ),
                              dataRowMinHeight: 40,
                              dataRowMaxHeight: 48,
                              headingRowHeight: 44,
                              columnSpacing: 18,
                              horizontalMargin: 14,
                              columns: const [
                                DataColumn(label: Text('Model')),
                                DataColumn(label: Text('Operation')),
                                DataColumn(label: Text('Count'), numeric: true),
                                DataColumn(
                                    label: Text('Avg Time'), numeric: true),
                                DataColumn(label: Text('Result')),
                                DataColumn(
                                    label: Text('Avg Latency'), numeric: true),
                                DataColumn(
                                    label: Text('Min / Max'), numeric: true),
                              ],
                              rows: summary.metrics.map((m) {
                                final isQuality = m.compactHighlight != null;
                                return DataRow(
                                  cells: [
                                    DataCell(Text(m.tierName,
                                        style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600))),
                                    DataCell(Text(m.name,
                                        style:
                                            const TextStyle(fontSize: 12.5))),
                                    DataCell(Text('${m.recordCount}',
                                        style: const TextStyle(
                                            fontSize: 12.5,
                                            color: Color(0xFF64748B)))),
                                    DataCell(Text(
                                        isQuality
                                            ? '—'
                                            : '${m.avgMilliseconds.toStringAsFixed(2)} ms',
                                        style: const TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w500))),
                                    DataCell(
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                            horizontal: 6, vertical: 2),
                                        decoration: BoxDecoration(
                                          color: primaryColor.withAlpha(20),
                                          borderRadius:
                                              BorderRadius.circular(4),
                                        ),
                                        child: Text(
                                          m.highlightLabel,
                                          style: TextStyle(
                                            fontSize: 12.5,
                                            fontWeight: FontWeight.w600,
                                            color: primaryColor,
                                          ),
                                        ),
                                      ),
                                    ),
                                    DataCell(Text(
                                        isQuality
                                            ? '—'
                                            : '${m.avgLatencyUs.toStringAsFixed(2)} μs',
                                        style: const TextStyle(
                                            fontSize: 12.5,
                                            color: Color(0xFF475569)))),
                                    DataCell(Text(
                                      isQuality
                                          ? '—'
                                          : '${(m.minMicroseconds / 1000.0).toStringAsFixed(1)} / ${(m.maxMicroseconds / 1000.0).toStringAsFixed(1)} ms',
                                      style: const TextStyle(
                                          fontSize: 12,
                                          color: Color(0xFF94A3B8)),
                                    )),
                                  ],
                                );
                              }).toList(),
                            ),
                          ),
                        ),
                      ),
                    ),
                    if (summary.vectorRecallCaption != null) ...[
                      const SizedBox(height: 10),
                      Text(
                        summary.vectorRecallCaption!,
                        style: const TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: Color(0xFF64748B),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _saveResultsImage(BenchmarkSummary summary) async {
    if (_savingImage || !canExportBenchmarkImage) return;
    setState(() => _savingImage = true);
    try {
      await Future<void>.delayed(const Duration(milliseconds: 80));
      await WidgetsBinding.instance.endOfFrame;

      final boundary = _captureKey.currentContext?.findRenderObject()
          as RenderRepaintBoundary?;
      if (boundary == null) {
        throw StateError('Capture target not ready');
      }

      final image = await boundary.toImage(pixelRatio: 3.0);
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (byteData == null) {
        throw StateError('Failed to encode PNG');
      }

      final dateStr = summary.timestamp.toIso8601String().split('T').first;
      final path = await exportBenchmarkPng(
        bytes: byteData.buffer.asUint8List(),
        fileName: 'tostore_benchmark_$dateStr.png',
      );

      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Saved: $path'),
          duration: const Duration(seconds: 5),
          backgroundColor: const Color(0xFF006CC3),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Save image failed: $e'),
          backgroundColor: Colors.red.shade700,
        ),
      );
    } finally {
      if (mounted) setState(() => _savingImage = false);
    }
  }

  void _copyMarkdown(BenchmarkSummary summary) {
    Clipboard.setData(ClipboardData(text: summary.toMarkdownTable()));
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('✅ Benchmark Markdown copied to clipboard!'),
        duration: Duration(seconds: 2),
        backgroundColor: Color(0xFF006CC3),
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

  /// Results footer: More on the far left; Close + Re-run grouped on the right.
  Widget _buildResultsActionBar(
      BuildContext context, BenchmarkSummary summary) {
    final compact = _isCompactActions(context);
    final buttonPadding = EdgeInsets.symmetric(
      horizontal: compact ? 10 : 14,
      vertical: compact ? 8 : 10,
    );
    final sharedShape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(8),
    );
    final outlinedStyle = OutlinedButton.styleFrom(
      padding: buttonPadding,
      visualDensity: VisualDensity.standard,
      minimumSize: const Size(0, 40),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: sharedShape,
    );
    final elevatedStyle = ElevatedButton.styleFrom(
      foregroundColor: Colors.white,
      backgroundColor: const Color.fromARGB(255, 10, 150, 210),
      padding: buttonPadding,
      visualDensity: VisualDensity.standard,
      minimumSize: const Size(0, 40),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      shape: sharedShape,
    );
    final textStyle = TextButton.styleFrom(
      padding: buttonPadding,
      visualDensity: VisualDensity.standard,
      minimumSize: const Size(0, 40),
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );

    return SizedBox(
      width: double.infinity,
      child: Row(
        children: [
          MenuAnchor(
            builder: (context, controller, child) {
              return OutlinedButton.icon(
                style: outlinedStyle,
                icon: const Icon(Icons.more_horiz_rounded, size: 18),
                label: const Text('More'),
                onPressed: _savingImage
                    ? null
                    : () {
                        if (controller.isOpen) {
                          controller.close();
                        } else {
                          controller.open();
                        }
                      },
              );
            },
            menuChildren: [
              MenuItemButton(
                leadingIcon: const Icon(Icons.copy_rounded, size: 20),
                onPressed: () => _copyMarkdown(summary),
                child: const Text('Copy Markdown'),
              ),
              if (canExportBenchmarkImage)
                MenuItemButton(
                  leadingIcon: _savingImage
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      : const Icon(Icons.image_outlined, size: 20),
                  onPressed:
                      _savingImage ? null : () => _saveResultsImage(summary),
                  child: Text(_savingImage ? 'Saving…' : 'Save Image'),
                ),
              MenuItemButton(
                leadingIcon: const Icon(Icons.tune_rounded, size: 20),
                onPressed: () => setState(() => _isViewingResults = false),
                child: const Text('New Benchmark'),
              ),
            ],
          ),
          const Spacer(),
          TextButton(
            style: textStyle,
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
          const SizedBox(width: 8),
          ElevatedButton.icon(
            style: elevatedStyle,
            icon: const Icon(Icons.refresh_rounded, size: 18),
            label: Text(
              compact ? 'Re-run' : 'Re-run Test',
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            onPressed: () => _onStart(summary.config),
          ),
        ],
      ),
    );
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

          // 4. Recovery Durability
          _buildSectionTitle('4. Write Recovery Durability'),
          const SizedBox(height: 4),
          Text(
            _selectedDurability.benchmarkDescription,
            style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: _durabilityOptions.map((mode) {
              final isSelected = _selectedDurability == mode;
              return ChoiceChip(
                label: Text(mode.benchmarkChipLabel),
                selected: isSelected,
                selectedColor: primaryColor.withAlpha(40),
                side: BorderSide(
                  color: isSelected ? primaryColor : Colors.grey.shade300,
                ),
                onSelected: (selected) {
                  if (selected) {
                    setState(() => _selectedDurability = mode);
                  }
                },
              );
            }).toList(),
          ),
          const SizedBox(height: 16),

          // 5. Operations Selection
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildSectionTitle('5. Operations to Evaluate'),
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
