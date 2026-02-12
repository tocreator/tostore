import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:tostore/tostore.dart';
import 'testing/database_tester.dart';
import 'testing/log_service.dart';
import 'tostore_example.dart' show ForeignKeyMode, TostoreExample;

/// Simple UI to run examples
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // It's crucial to set the log handler *before* any potential errors can occur.
  // This ensures that initialization logs are captured and displayed in the UI.
  LogConfig.setConfig(
    onLogHandler: (message, type, label) {
      // 1. Suppress expected Non-Nullable Constraint warnings
      if (type == LogType.warn &&
          (message.contains('Field email is required and cannot be null') ||
              message.contains('Data validation failed for table users'))) {
        return;
      }

      // 2. Suppress expected Unique Constraint Violations (New Format)
      // Format: [Unique Constraint Violation] Table '...' Field(s) [...] already contain value '...' (source: ...).
      if (message.contains('[Unique Constraint Violation]')) {
        // Only suppress if it contains specific test data values
        if (message.contains("value 'tx_user1'") || // Transaction test
            message.contains("value 'tx_user4'") || // Transaction test
            message.contains("value 'upsert_user'") || // Upsert test
            message.contains("value '3'") || // Edge case test
            message
                .contains("value '4'") || // Edge case test (potential artifact)
            message.contains("value '8'")) {
          // Edge case test (potential artifact)
          return;
        }
      }

      // 3. Suppress expected Foreign Key and Transaction warnings
      if (message.contains('Values: {id: 99999}') ||
          message.contains(
              'Cannot clear table users: Referenced by foreign keys with RESTRICT/NO ACTION in tables: comments') ||
          message.contains(
              'Cannot delete record from users: Referenced by records in comments (foreign key: fk_comments_user)') ||
          message.contains('Division by zero in expression. Returning 0.') ||
          message.contains(
              'Table users has primary key conflict, update auto increment start:') ||
          message.contains(
              'Insert failed: Transaction operation failed: insert on users -> Unique constraint violation')) {
        return; // Suppress expected foreign key constraint test errors
      }

      logService.add('[$label] $message', type, true);
    },
  );

  final example = TostoreExample();

  // The example app will now run even if initialization fails,
  // allowing the user to see the error logs in the ListView.
  runApp(MyApp(example: example));
}

class MyApp extends StatelessWidget {
  const MyApp({super.key, required this.example});
  final TostoreExample example;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Tostore Example',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff0aa6e8)),
        useMaterial3: true,
        visualDensity: VisualDensity.adaptivePlatformDensity,
      ),
      home: TostoreExamplePage(example: example),
    );
  }
}

enum AppView { dataView, benchmark }

enum PaginationMode { offset, cursor }

class TostoreExamplePage extends StatefulWidget {
  const TostoreExamplePage({super.key, required this.example});
  final TostoreExample example;
  @override
  State<TostoreExamplePage> createState() => _TostoreExamplePageState();
}

class _TostoreExamplePageState extends State<TostoreExamplePage> {
  final TextEditingController _searchController = TextEditingController();
  late final PageController _pageViewController;

  LogType? _selectedLogType;
  String _lastOperationInfo = 'Please initialize the database first.';
  bool _isDbInitialized = false;
  bool _isInitializing = true;
  bool _isTesting = false; // Add state to track if a test is running
  bool _isAtBottom = true; // Assume we start at the bottom

  AppView _selectedView = AppView.dataView;

  // State for spaces
  final List<String> _spaceNames = ['default', 'space1', 'space2'];
  String _selectedSpace = 'default';

  // State for Data View
  final List<String> _tableNames = [
    'users',
    'posts',
    'comments',
    'embeddings',
    'settings'
  ];
  String _selectedTable = 'users';
  bool _hasVectorSupport = false;
  List<Map<String, dynamic>> _tableData = [];
  List<String> _tableColumns = [];
  int _currentPage = 1;
  final int _pageSize = 20;
  int _totalRecords = 0;
  int _totalPages = 0;
  bool _isDataLoading = false;
  bool _isCountLimited =
      false; // Indicates if count might be limited by defaultQueryLimit
  String? _primaryKey;
  final Set<dynamic> _selectedRows = {};

  // Pagination state
  PaginationMode _paginationMode = PaginationMode.cursor;
  String? _nextCursor;
  String? _prevCursor;

  final TextEditingController _pageInputController = TextEditingController();
  final DraggableScrollableController _logPanelController =
      DraggableScrollableController();

  // The scroll controller provided by the DraggableScrollableSheet builder.
  // We need to hold a reference to it to manage listeners correctly.
  ScrollController? _sheetScrollController;
  bool _logCanScrollUp = false;
  bool _logCanScrollDown = false;

  // New state for sorting
  String? _sortColumn;
  bool _sortAscending = true;

  // New state for active filters
  List<Map<String, dynamic>> _activeFilters = [];

  @override
  void initState() {
    super.initState();
    _pageViewController = PageController(initialPage: _selectedView.index);
    _initializeDatabase();
    logService.logs.addListener(_onLogsChanged);
    _searchController.addListener(() {
      setState(() {
        // Just rebuild the widget when text changes
      });
    });
  }

  @override
  void dispose() {
    logService.logs.removeListener(_onLogsChanged);
    _logPanelController.dispose();
    _sheetScrollController?.removeListener(_logScrollListener);
    _searchController.dispose();
    _pageViewController.dispose();
    _pageInputController.dispose();
    super.dispose();
  }

  Future<void> _fetchTableData({bool resetPage = false, String? cursor}) async {
    if (!_isDbInitialized) return;

    setState(() {
      _isDataLoading = true;
      if (resetPage) {
        _currentPage = 1;
        _selectedRows.clear();
        _sortColumn = null; // Reset sort on page reset
        _nextCursor = null;
        _prevCursor = null;
      }
    });

    try {
      // Get schema to find columns and PK
      final schema = await widget.example.db.getTableSchema(_selectedTable);
      if (schema != null) {
        _tableColumns = schema.fields.map((f) => f.name).toList();
        _primaryKey = schema.primaryKeyConfig.name;
        if (!_tableColumns.contains(_primaryKey)) {
          _tableColumns.insert(0, _primaryKey!);
        }
        _hasVectorSupport =
            schema.indexes.any((idx) => idx.type == IndexType.vector);
      } else {
        // Fallback for tables without explicit schema (like kv store)
        _tableColumns = [];
        _primaryKey = 'key';
        _hasVectorSupport = false;
      }

      // Base queries for data and count
      var dataQuery = widget.example.db.query(_selectedTable);

      // Apply active filters
      for (final filter in _activeFilters) {
        final field = filter['field'] as String;
        final op = filter['operator'] as String;
        final value = filter['value'];
        dataQuery = dataQuery.where(field, op, value);
      }

      // Apply sorting
      if (_sortColumn != null) {
        if (_sortAscending) {
          dataQuery = dataQuery.orderByAsc(_sortColumn!);
        } else {
          dataQuery = dataQuery.orderByDesc(_sortColumn!);
        }
      }

      final int maxOffset = widget.example.db.config.maxQueryOffset;

      // Get defaultQueryLimit to detect if count might be limited
      final int defaultQueryLimit = widget.example.db.config.defaultQueryLimit;

      if (_paginationMode == PaginationMode.offset) {
        // Get total count for pagination (only needed in offset mode)
        _totalRecords = await dataQuery.count();

        // Detect if count might be limited by defaultQueryLimit
        // If count equals defaultQueryLimit and there are filters, it's likely limited
        _isCountLimited =
            _activeFilters.isNotEmpty && _totalRecords == defaultQueryLimit;

        _totalPages = (_totalRecords / _pageSize).ceil();
        if (_totalPages == 0) _totalPages = 1;

        // Clamp the current page
        if (_currentPage > _totalPages) {
          _currentPage = _totalPages;
        }

        final int offset = (_currentPage - 1) * _pageSize;
        if (!mounted) return;
        if (offset > maxOffset) {
          _showOffsetLimitWarning(offset, maxOffset);
          setState(() => _isDataLoading = false);
          return;
        }

        final result = await dataQuery.limit(_pageSize).offset(offset);
        if (!mounted) return;
        setState(() {
          _tableData = result.data;
          _nextCursor = result.nextCursor;
          _prevCursor = result.prevCursor;
        });
      } else {
        // Cursor mode
        // IMPORTANT: Create a separate count query to avoid limit affecting the count
        // Build count query with same filters but without limit/cursor
        var countQuery = widget.example.db.query(_selectedTable);
        for (final filter in _activeFilters) {
          final field = filter['field'] as String;
          final op = filter['operator'] as String;
          final value = filter['value'];
          countQuery = countQuery.where(field, op, value);
        }
        // Apply same sorting for consistency (though count doesn't need it)
        if (_sortColumn != null) {
          if (_sortAscending) {
            countQuery = countQuery.orderByAsc(_sortColumn!);
          } else {
            countQuery = countQuery.orderByDesc(_sortColumn!);
          }
        }
        _totalRecords = await countQuery.count();

        // Detect if count might be limited by defaultQueryLimit
        // If count equals defaultQueryLimit and there are filters, it's likely limited
        _isCountLimited =
            _activeFilters.isNotEmpty && _totalRecords == defaultQueryLimit;

        // Now apply limit and cursor for data fetching
        var q = dataQuery.limit(_pageSize);
        if (cursor != null) {
          q = q.cursor(cursor);
        }

        final result = await q;
        if (!mounted) return;

        setState(() {
          _tableData = result.data;
          _nextCursor = result.nextCursor;
          _prevCursor = result.prevCursor;
        });
      }

      setState(() {
        // if columns were not determined by schema, infer from first record
        if (_tableColumns.isEmpty && _tableData.isNotEmpty) {
          _tableColumns = _tableData.first.keys.toList();
        }
      });
    } catch (e, s) {
      logService.add('Error fetching table data: $e', LogType.error);
      logService.add('Stacktrace: $s', LogType.error);
    } finally {
      setState(() {
        _isDataLoading = false;
        _pageInputController.text = _currentPage.toString();
      });
    }
  }

  void _onLogsChanged() {
    // Check if we are at the bottom *before* new logs are added.
    bool wasAtBottom = true; // Assume true if we can't check
    if (_sheetScrollController != null && _sheetScrollController!.hasClients) {
      final pos = _sheetScrollController!.position;
      wasAtBottom =
          pos.pixels >= pos.maxScrollExtent - 5.0; // Use a small tolerance
    }

    if (wasAtBottom) {
      _logScrollToBottom();
    }

    // After logs are added, the scroll extent might change, so re-evaluate button states.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _logScrollListener();
    });
  }

  void _logScrollListener() {
    if (_sheetScrollController == null || !_sheetScrollController!.hasClients) {
      return;
    }
    final position = _sheetScrollController!.position;

    _isAtBottom = position.pixels >= position.maxScrollExtent - 5.0;
    final atTop = position.pixels <= position.minScrollExtent;

    final canScrollUp = !atTop;
    final canScrollDown = !_isAtBottom;

    if (_logCanScrollUp != canScrollUp || _logCanScrollDown != canScrollDown) {
      if (mounted) {
        setState(() {
          _logCanScrollUp = canScrollUp;
          _logCanScrollDown = canScrollDown;
        });
      }
    }
  }

  void _logScrollToTop() {
    if (_sheetScrollController != null && _sheetScrollController!.hasClients) {
      _sheetScrollController!.animateTo(
        0,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _logScrollToBottom() {
    // Use a post-frame callback to ensure the list has been rebuilt.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_sheetScrollController != null &&
          _sheetScrollController!.hasClients) {
        _sheetScrollController!.animateTo(
          _sheetScrollController!.position.maxScrollExtent,
          duration: const Duration(milliseconds: 300),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _updateOperationInfo(String info) {
    if (mounted) {
      setState(() {
        _lastOperationInfo = info;
      });
    }
  }

  Future<void> _initializeDatabase() async {
    setState(() {
      _isInitializing = true;
      _lastOperationInfo = 'Initializing Database...';
    });

    // Exclude getApplicationDocumentsDirectory time from stats
    // because that's an OS/Flutter limitation, not the db engine
    final dbPath = await widget.example.getDbPath();

    final stopwatch = Stopwatch()..start();
    try {
      await widget.example.initialize(dbPath: dbPath);
      stopwatch.stop();
      if (mounted) {
        setState(() {
          _isDbInitialized = true;
          _isInitializing = false;
          _lastOperationInfo =
              'DB Initialized: ${stopwatch.elapsedMilliseconds}ms';
          _selectedSpace = widget.example.db.currentSpaceName ?? 'default';
        });
        // Fetch data if the data view is active
        if (_selectedView == AppView.dataView) {
          await _fetchTableData(resetPage: true);
        }
      }
    } catch (e, s) {
      stopwatch.stop();
      logService.add(
          '!!!!!! DATABASE INITIALIZATION FAILED !!!!!!', LogType.error);
      logService.add('Error: $e', LogType.error);
      logService.add('StackTrace: $s', LogType.error);
      if (mounted) {
        setState(() {
          _isDbInitialized = false;
          _isInitializing = false;
          _lastOperationInfo = 'DB Initialization FAILED!';
        });
      }
    }
  }

  Widget _buildActionButton({required String text, VoidCallback? onPressed}) {
    return ElevatedButton(
      onPressed: onPressed,
      style: ElevatedButton.styleFrom(
        foregroundColor: Colors.white,
        backgroundColor: const Color.fromARGB(255, 10, 150, 210),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
        elevation: 2,
        shadowColor: const Color.fromARGB(102, 6, 126, 177),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      ),
      child: Text(
        text,
        textAlign: TextAlign.center,
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
        maxLines: 1,
        overflow: TextOverflow.visible,
      ),
    );
  }

  Widget _buildFilterButton(
      String text, LogType? type, int count, BuildContext context) {
    if (count == 0 && type != null) {
      // Don't show the button if there are no logs of this type (except for 'All')
      return const SizedBox.shrink();
    }
    final isSelected = _selectedLogType == type;
    final Color backgroundColor;
    final Color foregroundColor;
    final double elevation;
    final Color? shadowColor;
    Color? countColor;

    if (isSelected) {
      backgroundColor = const Color.fromARGB(255, 10, 150, 210);
      foregroundColor = Colors.white;
      elevation = 2;
      shadowColor = const Color.fromARGB(102, 6, 126, 177);
    } else {
      backgroundColor = const Color.fromARGB(255, 227, 232, 235);
      foregroundColor = Theme.of(context).colorScheme.onSecondaryContainer;
      elevation = 0;
      shadowColor = null;

      // Set count color for non-selected buttons
      if (type == LogType.error) {
        countColor = Colors.red;
      } else if (type == LogType.warn) {
        countColor = Colors.orange;
      }
    }

    return ElevatedButton(
      onPressed: () {
        setState(() {
          _selectedLogType = type;
        });
      },
      style: ElevatedButton.styleFrom(
        backgroundColor: backgroundColor,
        foregroundColor: foregroundColor,
        elevation: elevation,
        shadowColor: shadowColor,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      child: RichText(
        text: TextSpan(
          style: TextStyle(
            color: foregroundColor,
            fontWeight: FontWeight.normal,
          ),
          children: [
            TextSpan(text: '$text ('),
            TextSpan(
              text: '$count',
              style: TextStyle(
                fontWeight: FontWeight.bold,
                color:
                    countColor, // This will be null for selected, which is fine
              ),
            ),
            const TextSpan(text: ')'),
          ],
        ),
      ),
    );
  }

  Color _getLogColor(LogType type) {
    switch (type) {
      case LogType.error:
        return Colors.red;
      case LogType.warn:
        return Colors.orange;
      case LogType.debug:
        return Colors.blueAccent;
      case LogType.info:
        return Colors.black;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        title: const Text('Tostore Demo'),
        actions: [
          _buildMoreActionsButton(),
        ],
      ),
      body: SafeArea(
        top: false,
        child: Stack(
          children: [
            // Main Content
            Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 1200),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildViewToggle(),
                    Expanded(
                      child: _isInitializing
                          ? _buildInitializingView()
                          : PageView(
                              controller: _pageViewController,
                              onPageChanged: (index) {
                                final newView = AppView.values[index];
                                if (_selectedView != newView) {
                                  setState(() {
                                    _selectedView = newView;
                                  });
                                  // If switching to Data View, always refresh the data
                                  // to ensure it's not stale after benchmark tests.
                                  if (newView == AppView.dataView) {
                                    _fetchTableData(resetPage: true);
                                  }
                                }
                              },
                              children: [
                                _buildDataView(),
                                _buildBenchmarkView(),
                              ],
                            ),
                    ),
                    // This space is a buffer for the collapsed log panel handle
                    const SizedBox(height: 60),
                  ],
                ),
              ),
            ),
            // Draggable Log Panel
            _buildResizableLogPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildResizableLogPanel() {
    return DraggableScrollableSheet(
      controller: _logPanelController,
      initialChildSize: 0.1,
      minChildSize: 0.1,
      maxChildSize: 0.8,
      builder: (BuildContext context, ScrollController scrollController) {
        // The builder provides a new scrollController instance on each rebuild.
        // We must manage our listener accordingly.
        if (_sheetScrollController != scrollController) {
          _sheetScrollController?.removeListener(_logScrollListener);
          _sheetScrollController = scrollController;
          _sheetScrollController?.addListener(_logScrollListener);
        }

        return Container(
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(16.0),
              topRight: Radius.circular(16.0),
            ),
            boxShadow: [
              BoxShadow(
                blurRadius: 10.0,
                color: Colors.black.withAlpha(51),
              ),
            ],
          ),
          child: _buildLogPanel(scrollController),
        );
      },
    );
  }

  Widget _buildInitializingView() {
    return const Center(
      child: Padding(
        padding: EdgeInsets.symmetric(horizontal: 16.0, vertical: 24),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            CircularProgressIndicator(),
            SizedBox(width: 20),
            Text('Initializing...'),
          ],
        ),
      ),
    );
  }

  Widget _buildViewToggle() {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: Center(
        child: ToggleButtons(
          isSelected: [
            _selectedView == AppView.dataView,
            _selectedView == AppView.benchmark,
          ],
          onPressed: (index) {
            _pageViewController.animateToPage(
              index,
              duration: const Duration(milliseconds: 250),
              curve: Curves.easeInOut,
            );
          },
          borderRadius: BorderRadius.circular(8),
          selectedColor: Colors.black,
          fillColor: const Color.fromARGB(255, 211, 235, 245),
          children: const [
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Data View'),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: 16),
              child: Text('Benchmark'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildDataView() {
    return Column(
      children: [
        // Header with record count and actions
        _buildDataHeader(),
        _buildActiveFiltersDisplay(),
        const Divider(height: 1),
        // Data Table
        if (_isDataLoading)
          const Expanded(child: Center(child: CircularProgressIndicator()))
        else if (_tableData.isEmpty)
          const Expanded(
            child: Center(
              child: Text('No records found.'),
            ),
          )
        else
          _buildDataTable(),
        // Pagination Controls
        _buildPaginationControls(),
        // Add padding at the bottom to avoid being obscured by the log panel
        const SizedBox(height: 20),
      ],
    );
  }

  Widget _buildDataHeader() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 8.0),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Table Selector Dropdown
              DropdownButton<String>(
                value: _selectedTable,
                items: _tableNames.map((String tableName) {
                  return DropdownMenuItem<String>(
                    value: tableName,
                    child: Text(tableName),
                  );
                }).toList(),
                onChanged: (String? newTable) {
                  if (newTable != null && newTable != _selectedTable) {
                    setState(() {
                      _selectedTable = newTable;
                      _activeFilters.clear();
                    });
                    _fetchTableData(resetPage: true);
                  }
                },
              ),
              Text(
                  _isCountLimited
                      ? '≥$_totalRecords Records ($_selectedSpace)' // Indicate count might be limited
                      : '$_totalRecords Records ($_selectedSpace)', // Show current space
                  style: Theme.of(context).textTheme.bodyMedium),
            ],
          ),
          const SizedBox(height: 8),

          // Action Buttons
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 8.0,
            runSpacing: 8.0,
            children: [
              ElevatedButton.icon(
                onPressed: _isDataLoading ? null : _showAddDataDialog,
                icon: const Icon(Icons.add, size: 16),
                label: const Text('Add'),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  backgroundColor: const Color.fromARGB(255, 10, 150, 210),
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(fontSize: 14),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              ElevatedButton.icon(
                onPressed: _selectedRows.isEmpty || _isDataLoading
                    ? null
                    : _showBatchUpdateDialog,
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('Modify'),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  backgroundColor:
                      _selectedRows.isEmpty ? Colors.grey : Colors.green,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(fontSize: 14),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              ElevatedButton.icon(
                onPressed: _selectedRows.isEmpty || _isDataLoading
                    ? null
                    : _confirmDeleteSelected,
                icon: const Icon(Icons.delete, size: 16),
                label: Text('Del(${_selectedRows.length})'),
                style: ElevatedButton.styleFrom(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                  backgroundColor:
                      _selectedRows.isEmpty ? Colors.grey : Colors.red,
                  foregroundColor: Colors.white,
                  textStyle: const TextStyle(fontSize: 14),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
              ),
              PopupMenuButton<String>(
                icon: Icon(
                  Icons.more_horiz_outlined,
                  color: _activeFilters.isEmpty ? null : Colors.orange.shade700,
                ),
                tooltip: 'Advanced Actions',
                onSelected: (value) {
                  if (value == 'filter') {
                    _showFilterDialog();
                  } else if (value == 'custom_delete') {
                    _showCustomDeleteDialog();
                  } else if (value == 'clear_current_table') {
                    _confirmClearCurrentTable();
                  } else if (value == 'vector_search') {
                    _showVectorSearchBenchmarkDialog();
                  }
                },
                itemBuilder: (context) => [
                  const PopupMenuItem(
                    value: 'filter',
                    child: Row(
                      children: [
                        Icon(Icons.filter_alt_outlined, size: 18),
                        SizedBox(width: 8),
                        Text('Filter Data'),
                      ],
                    ),
                  ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'custom_delete',
                    child: Row(
                      children: [
                        Icon(Icons.playlist_remove, size: 18),
                        SizedBox(width: 8),
                        Text('Custom Delete'),
                      ],
                    ),
                  ),
                  if (_hasVectorSupport) const PopupMenuDivider(),
                  if (_hasVectorSupport)
                    const PopupMenuItem(
                      value: 'vector_search',
                      child: Row(
                        children: [
                          Icon(Icons.query_stats,
                              size: 18, color: Color(0xff0aa6e8)),
                          SizedBox(width: 8),
                          Text('Vector Search'),
                        ],
                      ),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'clear_current_table',
                    child: Row(
                      children: [
                        Icon(Icons.cleaning_services_rounded, size: 18),
                        SizedBox(width: 8),
                        Text('Clear Table'),
                      ],
                    ),
                  ),
                ],
              ),
            ],
          )
        ],
      ),
    );
  }

  Widget _buildActiveFiltersDisplay() {
    if (_activeFilters.isEmpty) {
      return const SizedBox.shrink();
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Wrap(
              spacing: 6.0,
              runSpacing: 6.0,
              children: _activeFilters.map((filter) {
                return Chip(
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  padding: const EdgeInsets.all(4),
                  label: Text(
                      "'${filter['field']}' ${filter['operator']} '${filter['value']}'"),
                  deleteIcon: const Icon(Icons.close, size: 14),
                  onDeleted: () {
                    setState(() {
                      _activeFilters.remove(filter);
                    });
                    _fetchTableData(resetPage: true);
                  },
                );
              }).toList(),
            ),
          ),
          IconButton(
            tooltip: 'Clear All Filters',
            icon: const Icon(Icons.close_outlined, color: Colors.redAccent),
            onPressed: () {
              setState(() {
                _activeFilters.clear();
              });
              _fetchTableData(resetPage: true);
            },
          ),
        ],
      ),
    );
  }

  Widget _buildDataTable() {
    if (_tableColumns.isEmpty) {
      return const Expanded(child: Center(child: Text('No records found.')));
    }

    return Expanded(
      child: SingleChildScrollView(
        scrollDirection: Axis.vertical,
        child: SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            sortColumnIndex: _sortColumn == null
                ? null
                : _tableColumns.indexOf(_sortColumn!),
            sortAscending: _sortAscending,
            showCheckboxColumn: _primaryKey != null,
            columns: [
              for (final colName in _tableColumns)
                DataColumn(
                  label: Text(colName),
                  onSort: (columnIndex, ascending) {
                    setState(() {
                      if (_sortColumn == _tableColumns[columnIndex]) {
                        if (_sortAscending) {
                          _sortAscending = false;
                        } else {
                          _sortColumn = null;
                        }
                      } else {
                        _sortColumn = _tableColumns[columnIndex];
                        _sortAscending = true;
                      }
                    });
                    _fetchTableData();
                  },
                ),
            ],
            rows: _tableData.map((row) {
              final pkValue = _primaryKey != null ? row[_primaryKey] : null;
              return DataRow(
                selected: pkValue != null && _selectedRows.contains(pkValue),
                onSelectChanged: pkValue == null
                    ? null
                    : (isSelected) {
                        setState(() {
                          if (isSelected ?? false) {
                            _selectedRows.add(pkValue);
                          } else {
                            _selectedRows.remove(pkValue);
                          }
                        });
                      },
                cells: [
                  for (final colName in _tableColumns)
                    DataCell(
                      Text(
                        '${row[colName] ?? 'NULL'}',
                        overflow: TextOverflow.ellipsis,
                      ),
                      onLongPress: () {
                        if (_primaryKey != null && row[_primaryKey] != null) {
                          _showEditRowDialog(row);
                        }
                      },
                    ),
                ],
              );
            }).toList(),
            onSelectAll: (isSelected) {
              if (_primaryKey == null) return;
              setState(() {
                if (isSelected ?? false) {
                  for (final row in _tableData) {
                    _selectedRows.add(row[_primaryKey]);
                  }
                } else {
                  for (final row in _tableData) {
                    _selectedRows.remove(row[_primaryKey]);
                  }
                }
              });
            },
          ),
        ),
      ),
    );
  }

  Widget _buildPaginationControls() {
    if (_paginationMode == PaginationMode.cursor) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            IconButton(
              icon: const Icon(Icons.first_page, size: 20),
              tooltip: 'Jump to First Page',
              onPressed: _prevCursor != null
                  ? () => _fetchTableData(resetPage: true)
                  : null,
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
            ),
            const SizedBox(width: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.chevron_left, size: 16),
              label: const Text('Prev'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _prevCursor != null
                  ? () => _fetchTableData(cursor: _prevCursor)
                  : null,
            ),
            const SizedBox(width: 16),
            ElevatedButton.icon(
              icon: const Icon(Icons.chevron_right, size: 16),
              label: const Text('Next'),
              style: ElevatedButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 3),
                visualDensity: VisualDensity.compact,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              onPressed: _nextCursor != null
                  ? () => _fetchTableData(cursor: _nextCursor)
                  : null,
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 8.0),
      child: Wrap(
        alignment: WrapAlignment.center,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 2.0, // Reduced space between items
        runSpacing: 8.0,
        children: [
          IconButton(
            icon: const Icon(Icons.first_page),
            tooltip: 'First Page',
            onPressed: _currentPage > 1 ? () => _goToPage(1) : null,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          IconButton(
            icon: const Icon(Icons.chevron_left),
            tooltip: 'Previous Page',
            onPressed:
                _currentPage > 1 ? () => _goToPage(_currentPage - 1) : null,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text('Page'),
              const SizedBox(width: 4), // Reduced space
              SizedBox(
                width: 50,
                child: TextField(
                  controller: _pageInputController,
                  textAlign: TextAlign.center,
                  keyboardType: TextInputType.number,
                  inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                  decoration: const InputDecoration(
                    isDense: true,
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 8),
                  ),
                  onSubmitted: (value) {
                    final page = int.tryParse(value);
                    if (page != null) {
                      _goToPage(page);
                    }
                  },
                ),
              ),
              const SizedBox(width: 4), // Reduced space
              Text('of $_totalPages'),
            ],
          ),
          IconButton(
            icon: const Icon(Icons.chevron_right),
            tooltip: 'Next Page',
            onPressed: _currentPage < _totalPages
                ? () => _goToPage(_currentPage + 1)
                : null,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
          IconButton(
            icon: const Icon(Icons.last_page),
            tooltip: 'Last Page',
            onPressed: _currentPage < _totalPages
                ? () => _goToPage(_totalPages)
                : null,
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
          ),
        ],
      ),
    );
  }

  void _goToPage(int page) {
    if (page < 1 || page > _totalPages) return;
    setState(() {
      _currentPage = page;
    });
    _fetchTableData();
  }

  void _showOffsetLimitWarning(int offset, int maxOffset) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.warning_amber_rounded, color: Colors.orange),
            SizedBox(width: 8),
            Text('Offset Limit Reached'),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current offset: $offset'),
            Text('Environment limit: $maxOffset'),
            const SizedBox(height: 12),
            const Text(
              'Deep pagination using Offset is discouraged due to performance costs. '
              'Please use Cursor mode for better performance at this depth.',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              Navigator.pop(context);
              setState(() {
                _paginationMode = PaginationMode.cursor;
              });
              _fetchTableData(resetPage: true);
            },
            child: const Text('Switch to Cursor Mode'),
          ),
        ],
      ),
    );
  }

  Widget _buildBenchmarkView() {
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16.0, 16.0, 16.0, 200.0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 40,
              alignment: Alignment.center,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  if (_isTesting) ...[
                    const SizedBox(
                      height: 16,
                      width: 16,
                      child: CircularProgressIndicator(strokeWidth: 2.0),
                    ),
                    const SizedBox(width: 12),
                  ],
                  Expanded(
                    child: Text(
                      _lastOperationInfo,
                      style: Theme.of(context).textTheme.titleMedium,
                      overflow: TextOverflow.ellipsis,
                      textAlign:
                          _isTesting ? TextAlign.start : TextAlign.center,
                    ),
                  ),
                ],
              ),
            ),
            LayoutBuilder(builder: (context, constraints) {
              final double buttonWidth;
              // On very narrow screens, use one column. Otherwise, use two.
              if (constraints.maxWidth < 360) {
                buttonWidth = constraints.maxWidth;
              } else {
                buttonWidth = (constraints.maxWidth - 12) / 2; // 12 is spacing
              }

              return Wrap(
                spacing: 12,
                runSpacing: 12,
                alignment: WrapAlignment.center,
                children: [
                  SizedBox(
                    width: buttonWidth,
                    child: _buildActionButton(
                      text: 'Concurrency Test',
                      onPressed: !_isDbInitialized || _isTesting
                          ? null
                          : () {
                              _checkAndExpandLogPanel();
                              _showConcurrencyTestDialog();
                            },
                    ),
                  ),
                  SizedBox(
                    width: buttonWidth,
                    child: _buildActionButton(
                      text: 'Run All Tests',
                      onPressed: !_isDbInitialized || _isTesting
                          ? null
                          : () async {
                              _checkAndExpandLogPanel();
                              setState(() {
                                _isTesting = true;
                              });
                              try {
                                final tester = DatabaseTester(
                                  widget.example.db,
                                  logService,
                                  _updateOperationInfo,
                                );
                                await tester.runAllTests();
                              } finally {
                                if (mounted) {
                                  setState(() {
                                    _isTesting = false;
                                  });
                                }
                                _fetchTableData(resetPage: true);
                              }
                            },
                    ),
                  ),
                ],
              );
            }),
          ],
        ),
      ),
    );
  }

  Widget _buildLogPanel(ScrollController scrollController) {
    // We listen to the logs here to dynamically determine the header size.
    return ValueListenableBuilder<List<LogEntry>>(
      valueListenable: logService.logs,
      builder: (context, logs, child) {
        final bool hasLogs = logs.isNotEmpty;
        const double handleAndTitleHeight = 60.0;

        // Use a LayoutBuilder to dynamically calculate the header height
        // based on whether the search/filter section is visible.
        return LayoutBuilder(
          builder: (context, constraints) {
            // Create a text painter to measure text height for an accurate calculation.
            final textPainter = TextPainter(
              text: const TextSpan(text: 'Filter'),
              textDirection: TextDirection.ltr,
            )..layout();

            // Estimate heights for various components.
            const double textFieldHeight =
                50.0; // Approx height of the TextField
            const double paddingAndSpacing = 30.0; // Combined vertical padding
            final double buttonHeight =
                textPainter.height * 2.5; // Estimated height for filter buttons
            final double buttonsSectionHeight =
                (constraints.maxWidth < 350) ? buttonHeight * 2 : buttonHeight;

            final searchAndFilterHeight =
                textFieldHeight + paddingAndSpacing + buttonsSectionHeight;

            final totalHeaderHeight =
                handleAndTitleHeight + (hasLogs ? searchAndFilterHeight : 0);

            return CustomScrollView(
              controller: scrollController,
              slivers: [
                SliverPersistentHeader(
                  pinned: true,
                  delegate: _LogPanelHeaderDelegate(
                    height: totalHeaderHeight,
                    child: GestureDetector(
                      onDoubleTap: () {
                        if (_logPanelController.isAttached) {
                          final bool isExpanded =
                              _logPanelController.size > 0.15;
                          _logPanelController.animateTo(
                            isExpanded ? 0.1 : 0.8,
                            duration: const Duration(milliseconds: 300),
                            curve: Curves.easeOut,
                          );
                        }
                      },
                      child: Container(
                        color: Theme.of(context).colorScheme.surface,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            // Drag Handle and Title Row
                            SizedBox(
                              height: handleAndTitleHeight,
                              child: Column(
                                children: [
                                  Center(
                                    child: Container(
                                      width: 40,
                                      height: 5,
                                      margin: const EdgeInsets.symmetric(
                                          vertical: 8),
                                      decoration: BoxDecoration(
                                        color: Colors.grey.shade300,
                                        borderRadius: BorderRadius.circular(10),
                                      ),
                                    ),
                                  ),
                                  Expanded(
                                    child: Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                          16.0, 0, 4, 0),
                                      child: Row(
                                        children: [
                                          const Text('Logs',
                                              style: TextStyle(
                                                  fontWeight: FontWeight.bold,
                                                  fontSize: 16)),
                                          const Spacer(),
                                          IconButton(
                                            icon:
                                                const Icon(Icons.arrow_upward),
                                            tooltip: 'Scroll to Top',
                                            onPressed: _logCanScrollUp
                                                ? _logScrollToTop
                                                : null,
                                          ),
                                          IconButton(
                                            icon: const Icon(
                                                Icons.arrow_downward),
                                            tooltip: 'Scroll to Bottom',
                                            onPressed: _logCanScrollDown
                                                ? _logScrollToBottom
                                                : null,
                                          ),
                                          IconButton(
                                            icon: const Icon(
                                                Icons.copy_outlined,
                                                size: 20),
                                            tooltip: 'Copy Visible Logs',
                                            onPressed: _copyVisibleLogs,
                                          ),
                                          IconButton(
                                            icon: const Icon(
                                                Icons.cleaning_services_rounded,
                                                size: 20),
                                            tooltip: 'Clear Logs',
                                            onPressed: logService.clear,
                                          ),
                                          AnimatedBuilder(
                                            animation: _logPanelController,
                                            builder: (context, child) {
                                              final bool isExpanded =
                                                  _logPanelController.size >
                                                      0.15;
                                              return IconButton(
                                                icon: Icon(isExpanded
                                                    ? Icons.keyboard_arrow_down
                                                    : Icons.keyboard_arrow_up),
                                                tooltip: isExpanded
                                                    ? 'Collapse Logs'
                                                    : 'Expand Logs',
                                                onPressed: () {
                                                  _logPanelController.animateTo(
                                                    isExpanded ? 0.1 : 0.8,
                                                    duration: const Duration(
                                                        milliseconds: 300),
                                                    curve: Curves.easeOut,
                                                  );
                                                },
                                              );
                                            },
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const Divider(height: 1),
                                ],
                              ),
                            ),
                            // Search and Filter section (conditionally shown)
                            if (hasLogs)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 16.0),
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.start,
                                    mainAxisAlignment:
                                        MainAxisAlignment.spaceEvenly,
                                    children: [
                                      TextField(
                                        controller: _searchController,
                                        decoration: InputDecoration(
                                          hintText: 'Search in logs...',
                                          prefixIcon: const Icon(Icons.search),
                                          suffixIcon: _searchController
                                                  .text.isNotEmpty
                                              ? IconButton(
                                                  icon: const Icon(Icons.clear),
                                                  onPressed: () {
                                                    _searchController.clear();
                                                  },
                                                )
                                              : null,
                                          border: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                          ),
                                          enabledBorder: OutlineInputBorder(
                                            borderRadius:
                                                BorderRadius.circular(8),
                                            borderSide: BorderSide(
                                                color: Colors.grey.shade300,
                                                width: 0.8),
                                          ),
                                          contentPadding:
                                              const EdgeInsets.symmetric(
                                                  horizontal: 12, vertical: 8),
                                        ),
                                      ),
                                      ValueListenableBuilder<List<LogEntry>>(
                                        valueListenable: logService.logs,
                                        builder: (context, logs, child) {
                                          // Counts...
                                          final allCount = logs.length;
                                          final infoCount = logs
                                              .where((log) =>
                                                  log.type == LogType.info)
                                              .length;
                                          final debugCount = logs
                                              .where((log) =>
                                                  log.type == LogType.debug)
                                              .length;
                                          final warnCount = logs
                                              .where((log) =>
                                                  log.type == LogType.warn)
                                              .length;
                                          final errorCount = logs
                                              .where((log) =>
                                                  log.type == LogType.error)
                                              .length;

                                          return Wrap(
                                            spacing: 8.0,
                                            runSpacing: 8.0,
                                            alignment: WrapAlignment.start,
                                            children: [
                                              _buildFilterButton('All', null,
                                                  allCount, context),
                                              _buildFilterButton(
                                                  'Info',
                                                  LogType.info,
                                                  infoCount,
                                                  context),
                                              _buildFilterButton(
                                                  'Debug',
                                                  LogType.debug,
                                                  debugCount,
                                                  context),
                                              _buildFilterButton(
                                                  'Warn',
                                                  LogType.warn,
                                                  warnCount,
                                                  context),
                                              _buildFilterButton(
                                                  'Error',
                                                  LogType.error,
                                                  errorCount,
                                                  context),
                                            ],
                                          );
                                        },
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
                ValueListenableBuilder<List<LogEntry>>(
                  valueListenable: logService.logs,
                  builder: (context, logs, child) {
                    // ... (filtering logic remains the same)
                    final filteredByType = _selectedLogType == null
                        ? logs
                        : logs
                            .where((log) => log.type == _selectedLogType)
                            .toList();
                    final searchText = _searchController.text.toLowerCase();
                    final filteredLogs = searchText.isEmpty
                        ? filteredByType
                        : filteredByType
                            .where((log) =>
                                log.message.toLowerCase().contains(searchText))
                            .toList();

                    if (filteredLogs.isEmpty) {
                      return const SliverToBoxAdapter(
                        child: Padding(
                          padding: EdgeInsets.symmetric(vertical: 48),
                          child: Center(child: Text('No logs to display.')),
                        ),
                      );
                    }
                    return SliverPadding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 16.0, vertical: 16.0),
                      sliver: SliverList(
                        delegate: SliverChildBuilderDelegate(
                          (context, index) {
                            final logEntry = filteredLogs[index];
                            return Padding(
                              padding:
                                  const EdgeInsets.symmetric(vertical: 4.0),
                              child: Text(
                                logEntry.message,
                                style: TextStyle(
                                  fontSize: 12,
                                  color: _getLogColor(logEntry.type),
                                ),
                              ),
                            );
                          },
                          childCount: filteredLogs.length,
                        ),
                      ),
                    );
                  },
                ),
              ],
            );
          },
        );
      },
    );
  }

  PopupMenuButton<String> _buildMoreActionsButton() {
    return PopupMenuButton<String>(
      onSelected: (value) async {
        if (value.startsWith('switch_space_')) {
          final newSpace = value.substring('switch_space_'.length);
          if (newSpace != _selectedSpace) {
            await widget.example.db
                .switchSpace(spaceName: newSpace, keepActive: true);
            setState(() {
              _selectedSpace = newSpace;
              _activeFilters.clear();
            });
            await _fetchTableData(resetPage: true);
          }
          return;
        }

        switch (value) {
          case 'set_mode_offset':
            setState(() {
              _paginationMode = PaginationMode.offset;
            });
            _fetchTableData(resetPage: true);
            break;
          case 'set_mode_cursor':
            setState(() {
              _paginationMode = PaginationMode.cursor;
            });
            _fetchTableData(resetPage: true);
            break;
          case 'clear_all_tables':
            setState(() {
              _isTesting = true;
              _lastOperationInfo = 'Clearing all tables...';
            });
            try {
              await widget.example.db.clear('comments');
              await widget.example.db.clear('posts');
              await widget.example.db.clear('users');
              await widget.example.db.clear('settings');
              await widget.example.db.clear('embeddings');
              _updateOperationInfo('All tables cleared.');
              _fetchTableData(resetPage: true);
            } finally {
              if (mounted) {
                setState(() {
                  _isTesting = false;
                });
              }
            }
            break;
        }
      },
      itemBuilder: (BuildContext context) {
        return [
          PopupMenuItem<String>(
            value: _paginationMode == PaginationMode.offset
                ? 'set_mode_cursor'
                : 'set_mode_offset',
            child: Row(
              children: [
                Icon(
                  _paginationMode == PaginationMode.offset
                      ? Icons.ads_click
                      : Icons.format_list_numbered,
                  size: 20,
                  color: Colors.blue,
                ),
                const SizedBox(width: 12),
                Text(_paginationMode == PaginationMode.offset
                    ? 'Switch to Cursor Mode'
                    : 'Switch to Offset Mode'),
              ],
            ),
          ),
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            enabled: false,
            child: Row(
              children: [
                Icon(Icons.storage, size: 20, color: Colors.grey),
                SizedBox(width: 12),
                Text('Switch Space',
                    style: TextStyle(fontWeight: FontWeight.bold)),
              ],
            ),
          ),
          ..._spaceNames.map((spaceName) {
            return CheckedPopupMenuItem<String>(
              value: 'switch_space_$spaceName',
              checked: _selectedSpace == spaceName,
              child: Text(spaceName),
            );
          }),
          const PopupMenuDivider(),
          const PopupMenuItem<String>(
            value: 'clear_all_tables',
            child: Row(
              children: [
                Icon(
                  Icons.delete_sweep,
                  size: 20,
                ),
                SizedBox(width: 12),
                Text('Clear All Tables'),
              ],
            ),
          ),
        ];
      },
    );
  }

  Future<void> _showConcurrencyTestDialog() async {
    final config = await showDialog<Map<String, Map<String, int>>>(
      context: context,
      barrierDismissible: false,
      builder: (context) => const ConcurrencyTestDialog(),
    );
    if (!mounted) return;

    if (config != null) {
      _updateOperationInfo('Running Custom Concurrency Test...');
      setState(() {
        _isTesting = true;
      });
      try {
        final tester = DatabaseTester(
          widget.example.db,
          logService,
          _updateOperationInfo,
        );
        final success = await tester.runConfigurableConcurrencyTest(config);
        if (success) {
          _updateOperationInfo('✅ Custom Concurrency Test Passed');
        } else {
          _updateOperationInfo('❌ Custom Concurrency Test Failed');
        }
      } finally {
        if (mounted) {
          setState(() {
            _isTesting = false;
          });
          _fetchTableData(resetPage: true);
        }
      }
    }
  }

  Future<void> _showVectorSearchBenchmarkDialog() async {
    final result = await showDialog<Map<String, int>>(
      context: context,
      builder: (context) => const VectorSearchDialog(),
    );
    if (!mounted) return;

    if (result != null) {
      final iterations = result['iterations'] ?? 1;
      final topK = result['topK'] ?? 10;

      setState(() {
        _isTesting = true;
        _lastOperationInfo =
            'Running $iterations vector search iterations (Top-$topK)...';
      });

      try {
        await widget.example
            .vectorSearchBenchmark(_selectedTable, iterations, topK);
      } catch (e) {
        logService.add('Benchmark failed: $e', LogType.error);
        _updateOperationInfo('❌ Vector search benchmark failed.');
      } finally {
        if (mounted) {
          setState(() {
            _isTesting = false;
          });
        }
      }
    }
  }

  Future<void> _showAddDataDialog() async {
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => AddDataDialog(
        defaultCount: 10000,
        tableName: _selectedTable,
        db: widget.example.db,
      ),
    );
    if (!mounted) return;

    if (result != null) {
      final count = result['count'] as int;
      final method = result['method'] as InsertMethod;
      final foreignKeyValues =
          result['foreignKeyValues'] as Map<String, dynamic>?;
      final foreignKeyModes =
          result['foreignKeyModes'] as Map<String, ForeignKeyMode>?;
      final foreignKeyIdLists =
          result['foreignKeyIdLists'] as Map<String, List<dynamic>>?;

      if (count <= 0) return;

      setState(() {
        _isTesting = true; // Use the benchmark view's testing flag
        _isDataLoading = true;
        _lastOperationInfo =
            'Adding $count records (${method == InsertMethod.batch ? 'batch' : 'one-by-one'})...';
      });

      int elapsed = -1;

      try {
        if (method == InsertMethod.batch) {
          // Use the existing benchmark logic for batch adding
          elapsed = await widget.example.addExamples(
            _selectedTable,
            count,
            foreignKeyValues: foreignKeyValues,
            foreignKeyModes: foreignKeyModes,
            foreignKeyIdLists: foreignKeyIdLists,
          );
        } else {
          // Use the existing benchmark logic for one-by-one adding
          elapsed = await widget.example.addExamplesOneByOne(
            _selectedTable,
            count,
            foreignKeyValues: foreignKeyValues,
            foreignKeyModes: foreignKeyModes,
            foreignKeyIdLists: foreignKeyIdLists,
          );
        }
      } catch (e, s) {
        logService.add('Failed to add data: $e', LogType.error);
        logService.add('Stacktrace: $s', LogType.error);
        // 'elapsed' remains -1, indicating failure.
      }

      if (!mounted) return;

      // Show a user-friendly SnackBar based on the operation result.
      if (elapsed >= 0) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Added $count records in ${elapsed}ms'),
            duration: const Duration(seconds: 3),
            backgroundColor: Colors.green,
          ),
        );
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Failed to add data. Please check logs for details.'),
            duration: Duration(seconds: 4),
            backgroundColor: Colors.red,
          ),
        );
      }

      setState(() {
        _isTesting = false;
      });
      await _fetchTableData(
          resetPage: true); // Refresh the view and go to page 1
    }
  }

  Future<void> _confirmDeleteSelected() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Deletion'),
        content: Text(
            'Are you sure you want to delete ${_selectedRows.length} selected record(s)?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed ?? false) {
      if (_primaryKey == null) {
        logService.add('Cannot delete without a primary key.', LogType.error);
        return;
      }

      setState(() {
        _isDataLoading = true;
        _lastOperationInfo = 'Deleting ${_selectedRows.length} records...';
      });

      try {
        final result = await widget.example.db
            .delete(_selectedTable)
            .whereIn(_primaryKey!, _selectedRows.toList());

        logService.add(
            'Deleted ${result.successCount} of ${_selectedRows.length} records.',
            result.isSuccess ? LogType.info : LogType.warn);

        if (result.failedCount > 0) {
          logService.add(
              'Failed to delete ${result.failedCount} records. Error: ${result.message}',
              LogType.error);
        }
      } catch (e, s) {
        logService.add('Failed to delete data: $e', LogType.error);
        logService.add('Stacktrace: $s', LogType.error);
      }

      _selectedRows.clear();
      await _fetchTableData(); // Refresh the view
    }
  }

  Future<void> _showEditRowDialog(Map<String, dynamic> rowData) async {
    final schema = await widget.example.db.getTableSchema(_selectedTable);
    if (schema == null) {
      logService.add('Cannot edit row: Schema not found for $_selectedTable.',
          LogType.warn);
      return;
    }

    if (!mounted) return;
    final Map<String, dynamic>? updatedData = await showDialog(
      context: context,
      builder: (context) => EditRowDialog(
        schema: schema,
        initialData: rowData,
      ),
    );
    if (!mounted) return;

    if (updatedData != null) {
      setState(() {
        _isDataLoading = true;
        _lastOperationInfo = 'Updating row...';
      });

      final pkValue = rowData[schema.primaryKeyConfig.name];

      try {
        final result = await widget.example.db
            .update(_selectedTable, updatedData)
            .where(schema.primaryKeyConfig.name, '=', pkValue);

        if (result.isSuccess) {
          logService.add('Row successfully updated.', LogType.info);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Row updated!'),
                duration: Duration(seconds: 2),
              ),
            );
          }
        } else {
          logService.add(
              'Failed to update row: ${result.message}', LogType.error);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text('Error: ${result.message}'),
                backgroundColor: Colors.red,
              ),
            );
          }
        }
      } catch (e, s) {
        logService.add('Failed to update data: $e', LogType.error);
        logService.add('Stacktrace: $s', LogType.error);
      }

      await _fetchTableData();
    }
  }

  Future<void> _showBatchUpdateDialog() async {
    final schema = await widget.example.db.getTableSchema(_selectedTable);
    if (schema == null) {
      logService.add(
          'Cannot modify rows: Schema not found for $_selectedTable.',
          LogType.warn);
      return;
    }

    if (!mounted) return;
    final Map<String, dynamic>? updateInfo = await showDialog(
      context: context,
      builder: (context) => BatchUpdateDialog(schema: schema),
    );
    if (!mounted) return;

    if (updateInfo != null) {
      final fieldToUpdate = updateInfo['field'] as String;
      final newValue = updateInfo['value'];

      setState(() {
        _isDataLoading = true;
        _lastOperationInfo = 'Updating ${_selectedRows.length} records...';
      });

      try {
        final result = await widget.example.db
            .update(_selectedTable, {fieldToUpdate: newValue})
            .whereIn(_primaryKey!, _selectedRows.toList())
            .allowPartialErrors();

        final successMsg =
            'Successfully updated ${result.successCount} of ${_selectedRows.length} records.';
        logService.add(successMsg, LogType.info);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(successMsg),
              duration: const Duration(seconds: 3),
            ),
          );
        }

        if (result.failedCount > 0) {
          final errorMsg =
              'Failed to update ${result.failedCount} records. Error: ${result.message}';
          logService.add(errorMsg, LogType.error);
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(errorMsg),
                backgroundColor: Colors.red,
                duration: const Duration(seconds: 5),
              ),
            );
          }
        }
      } catch (e, s) {
        logService.add('Failed to bulk update data: $e', LogType.error);
        logService.add('Stacktrace: $s', LogType.error);
      }

      _selectedRows.clear();
      await _fetchTableData();
    }
  }

  Future<void> _showCustomDeleteDialog() async {
    final schema = await widget.example.db.getTableSchema(_selectedTable);
    if (schema == null) {
      logService.add(
          'Cannot perform custom delete: Schema not found for $_selectedTable.',
          LogType.warn);
      return;
    }
    if (!mounted) return;
    final result = await showDialog<Map<String, dynamic>>(
      context: context,
      builder: (context) => CustomDeleteDialog(schema: schema),
    );
    if (!mounted) return;

    if (result != null) {
      final field = result['field'] as String;
      final op = result['operator'] as String;
      final value = result['value'];

      if (value == null) {
        logService.add('Invalid value for custom delete.', LogType.warn);
        return;
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('Confirm Custom Deletion'),
          content: Text(
              'Are you sure you want to delete all records from "$_selectedTable" where $field $op $value? This action cannot be undone.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              style: TextButton.styleFrom(foregroundColor: Colors.red),
              child: const Text('Delete'),
            ),
          ],
        ),
      );
      if (!mounted) return;

      if (confirmed ?? false) {
        setState(() {
          _isDataLoading = true;
          _lastOperationInfo = 'Deleting records where $field $op $value...';
        });

        try {
          final result = await widget.example.db
              .delete(_selectedTable)
              .where(field, op, value);

          logService.add(
              'Custom delete affected ${result.successCount} record(s).',
              result.isSuccess ? LogType.info : LogType.warn);

          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                    '${result.successCount} record(s) deleted successfully.'),
              ),
            );
          }
        } catch (e, s) {
          logService.add('Failed to perform custom delete: $e', LogType.error);
          logService.add('Stacktrace: $s', LogType.error);
        }

        await _fetchTableData(resetPage: true);
      }
    }
  }

  Future<void> _showFilterDialog() async {
    final schema = await widget.example.db.getTableSchema(_selectedTable);
    if (schema == null) {
      logService.add(
          'Cannot filter: Schema not found for $_selectedTable.', LogType.warn);
      return;
    }

    if (!mounted) return;
    final newFilters = await showDialog<List<Map<String, dynamic>>>(
      context: context,
      builder: (context) => FilterDialog(
        schema: schema,
        existingFilters: _activeFilters,
      ),
    );
    if (!mounted) return;

    if (newFilters != null) {
      setState(() {
        _activeFilters = newFilters;
      });
      _fetchTableData(resetPage: true);
    }
  }

  Future<void> _confirmClearCurrentTable() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Confirm Clear Table'),
        content: const Text(
          'Are you sure you want to clear the current table?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (!mounted) return;

    if (confirmed ?? false) {
      setState(() {
        _isDataLoading = true;
        _lastOperationInfo = 'Clearing current table...';
      });

      try {
        await widget.example.db.clear(_selectedTable);
        logService.add('Cleared table $_selectedTable.', LogType.info);
      } catch (e, s) {
        logService.add('Failed to clear table: $e', LogType.error);
        logService.add('Stacktrace: $s', LogType.error);
      }
      await _fetchTableData(resetPage: true);
    }
  }

  Future<void> _copyVisibleLogs() async {
    final logs = logService.logs.value;
    if (logs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No logs to copy.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // Apply the same filtering logic as in the log panel
    var filteredLogs = logs;

    // Filter by type
    if (_selectedLogType != null) {
      filteredLogs =
          filteredLogs.where((log) => log.type == _selectedLogType).toList();
    }

    // Filter by search text
    final searchText = _searchController.text.toLowerCase();
    if (searchText.isNotEmpty) {
      filteredLogs = filteredLogs
          .where((log) => log.message.toLowerCase().contains(searchText))
          .toList();
    }

    if (filteredLogs.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No visible logs to copy.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    // Format logs as text (one log per line)
    final logText = filteredLogs.map((log) => log.message).join('\n');

    // Copy to clipboard
    await Clipboard.setData(ClipboardData(text: logText));

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Copied ${filteredLogs.length} log(s) to clipboard.'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _checkAndExpandLogPanel() {
    // Threshold is slightly larger than minChildSize to handle tolerances
    // and minor user dragging.
    if (_logPanelController.isAttached && _logPanelController.size < 0.15) {
      // Animate to a size that's large enough to be useful but leaves
      // top controls visible. The max is 0.8.
      const targetSize = 0.7;
      _logPanelController.animateTo(
        targetSize,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }
}

/// A custom SliverPersistentHeaderDelegate for creating a pinned header
/// for the log panel. This ensures the header (with title and action buttons)
/// stays visible while the log content scrolls.
class _LogPanelHeaderDelegate extends SliverPersistentHeaderDelegate {
  final Widget child;
  final double height;

  _LogPanelHeaderDelegate({required this.child, required this.height});

  @override
  Widget build(
      BuildContext context, double shrinkOffset, bool overlapsContent) {
    return SizedBox.expand(child: child);
  }

  @override
  double get maxExtent => height;

  @override
  double get minExtent => height;

  @override
  bool shouldRebuild(covariant _LogPanelHeaderDelegate oldDelegate) {
    return oldDelegate.height != height || oldDelegate.child != child;
  }
}

/// A dialog for configuring and running a custom concurrency test.
class ConcurrencyTestDialog extends StatefulWidget {
  const ConcurrencyTestDialog({super.key});

  @override
  State<ConcurrencyTestDialog> createState() => _ConcurrencyTestDialogState();
}

class _ConcurrencyTestDialogState extends State<ConcurrencyTestDialog> {
  final _formKey = GlobalKey<FormState>();

  final _controllers = {
    'users': {
      'insert': TextEditingController(text: '1000'),
      'read': TextEditingController(text: '1000'),
      'update': TextEditingController(text: '500'),
      'delete': TextEditingController(text: '500'),
    },
    'settings': {
      'insert': TextEditingController(text: '1000'),
      'read': TextEditingController(text: '1000'),
      'update': TextEditingController(text: '500'),
      'delete': TextEditingController(text: '500'),
    },
  };

  @override
  void dispose() {
    for (final table in _controllers.values) {
      for (final controller in table.values) {
        controller.dispose();
      }
    }
    super.dispose();
  }

  void _onRun() {
    if (_formKey.currentState!.validate()) {
      final config = _controllers.map((table, operations) {
        return MapEntry(table, operations.map((op, controller) {
          return MapEntry(op, int.tryParse(controller.text) ?? 0);
        }));
      });
      Navigator.of(context).pop(config);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      // 1. Make dialog wider by reducing horizontal padding
      insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
      title: const Text('Configure Concurrency Test'),
      // Use a SizedBox to constrain the content width
      content: SizedBox(
        width: MediaQuery.of(context).size.width, // Use full screen width
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: _controllers.entries.map((tableEntry) {
                return _buildTableSection(tableEntry.key, tableEntry.value);
              }).toList(),
            ),
          ),
        ),
      ),
      // 2. Center the buttons
      actionsAlignment: MainAxisAlignment.center,
      actionsPadding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        const SizedBox(width: 16),
        // 3. Style the Run Test button to match the main screen
        ElevatedButton(
          style: ElevatedButton.styleFrom(
            foregroundColor: Colors.white,
            backgroundColor: const Color.fromARGB(255, 10, 150, 210),
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
          ),
          onPressed: _onRun,
          child: const Text('Run Test', style: TextStyle(fontSize: 16)),
        ),
      ],
    );
  }

  Widget _buildTableSection(
      String title, Map<String, TextEditingController> controllers) {
    return Padding(
      // 4. Adjust spacing for better visual layout
      padding: const EdgeInsets.only(bottom: 24.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${title[0].toUpperCase()}${title.substring(1)}',
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 16),
          if (controllers.containsKey('insert'))
            _buildOperationRow('Inserts', controllers['insert']!),
          if (controllers.containsKey('read'))
            _buildOperationRow('Reads', controllers['read']!),
          if (controllers.containsKey('update'))
            _buildOperationRow('Updates', controllers['update']!),
          if (controllers.containsKey('delete'))
            _buildOperationRow('Deletes', controllers['delete']!),
        ],
      ),
    );
  }

  Widget _buildOperationRow(String label, TextEditingController controller) {
    return Padding(
      // 4. Adjust spacing
      padding: const EdgeInsets.symmetric(vertical: 6.0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: const TextStyle(fontSize: 16)),
          ),
          // 4. Add space between label and field
          const SizedBox(width: 24),
          Expanded(
            flex: 3,
            child: TextFormField(
              controller: controller,
              keyboardType: TextInputType.number,
              inputFormatters: [FilteringTextInputFormatter.digitsOnly],
              decoration: const InputDecoration(
                border: OutlineInputBorder(),
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Required';
                }
                if (int.tryParse(value) == null) {
                  return 'Invalid';
                }
                return null;
              },
            ),
          ),
        ],
      ),
    );
  }
}

enum InsertMethod { batch, oneByOne }

/// A dialog for adding a specific number of records.
class AddDataDialog extends StatefulWidget {
  final int defaultCount;
  final String tableName;
  final ToStore db;
  const AddDataDialog({
    super.key,
    required this.defaultCount,
    required this.tableName,
    required this.db,
  });

  @override
  State<AddDataDialog> createState() => _AddDataDialogState();
}

class _AddDataDialogState extends State<AddDataDialog> {
  late final TextEditingController _controller;
  InsertMethod _method = InsertMethod.batch;
  bool _isLoading = true;
  Map<String, List<Map<String, dynamic>>> _foreignKeyOptions =
      {}; // foreign key options for dropdown display (up to 100 records)
  final Map<String, dynamic> _selectedForeignKeyValues = {};
  Map<String, String> _foreignKeyFieldMap = {}; // fk_field -> referenced_table
  final Map<String, ForeignKeyMode> _foreignKeyModes = {}; // fk_field -> mode
  final Map<String, List<dynamic>> _foreignKeyIdLists =
      {}; // fk_field -> [id1, id2, ...] all IDs for random
  final Map<String, int> _foreignKeyTotalCounts =
      {}; // fk_field -> total number of records
  final Map<String, TextEditingController> _manualInputControllers =
      {}; // manual input controller
  final Map<String, bool> _useManualInput = {}; // whether to use manual input
  List<String> _missingForeignKeyTables =
      []; // records missing data in the main table

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.defaultCount.toString());
    _loadForeignKeyData();
  }

  @override
  void dispose() {
    _controller.dispose();
    for (final controller in _manualInputControllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadForeignKeyData() async {
    try {
      final schema = await widget.db.getTableSchema(widget.tableName);
      if (schema == null || schema.foreignKeys.isEmpty) {
        setState(() {
          _isLoading = false;
        });
        return;
      }

      final Map<String, List<Map<String, dynamic>>> options = {};
      final Map<String, String> fieldMap = {};
      final List<String> missingTables = [];

      for (final fk in schema.foreignKeys) {
        if (!fk.enabled) continue;

        // First query the total number of records
        final totalCount = await widget.db.query(fk.referencedTable).count();

        if (totalCount == 0) {
          // The main table has no data, record it in the missing list
          missingTables.add(fk.referencedTable);
          continue;
        }

        // Query the first 100 records for dropdown display (performance optimization)
        final refTableResult = await widget.db
            .query(fk.referencedTable)
            .select([fk.referencedFields.first])
            .orderByAsc(fk.referencedFields.first)
            .limit(100);

        // Store option data (up to 100 records for dropdown)
        options[fk.fields.first] = refTableResult.data;
        fieldMap[fk.fields.first] = fk.referencedTable;
        _foreignKeyTotalCounts[fk.fields.first] = totalCount;

        // Extract all primary key values for random selection (need to query all data)
        // If the total number exceeds 1000, only query the first 1000 records for random (performance consideration)
        final maxForRandom = totalCount > 1000 ? 1000 : totalCount;
        final allIdsResult = await widget.db
            .query(fk.referencedTable)
            .select([fk.referencedFields.first])
            .orderByAsc(fk.referencedFields.first)
            .limit(maxForRandom);

        final idList = allIdsResult.data
            .map((row) => row[fk.referencedFields.first])
            .toList();
        _foreignKeyIdLists[fk.fields.first] = idList;

        // Initialize manual input controller
        _manualInputControllers[fk.fields.first] = TextEditingController();
        _useManualInput[fk.fields.first] = false;

        // Default select the first record, default mode is random
        if (refTableResult.data.isNotEmpty) {
          final pkValue = refTableResult.data.first[fk.referencedFields.first];
          _selectedForeignKeyValues[fk.fields.first] = pkValue;
          _foreignKeyModes[fk.fields.first] =
              ForeignKeyMode.random; // Default random mode
        }
      }

      setState(() {
        _foreignKeyOptions = options;
        _foreignKeyFieldMap = fieldMap;
        _missingForeignKeyTables = missingTables;
        _isLoading = false;
      });
    } catch (e) {
      logService.add('Error loading foreign key data: $e', LogType.error);
      setState(() {
        _isLoading = false;
      });
    }
  }

  void _onAdd() async {
    final count = int.tryParse(_controller.text);
    if (count != null && count > 0) {
      // Check if there are foreign keys but the main table has no data
      if (_missingForeignKeyTables.isNotEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
                'Cannot add: Tables "${_missingForeignKeyTables.join('", "')}" have no data, please add records first.'),
            backgroundColor: Colors.red,
            duration: const Duration(seconds: 3),
          ),
        );
        return;
      }

      // Process manual input values
      final finalForeignKeyValues =
          Map<String, dynamic>.from(_selectedForeignKeyValues);
      for (final entry in _useManualInput.entries) {
        if (entry.value) {
          // Use manual input values
          final controller = _manualInputControllers[entry.key];
          if (controller != null && controller.text.isNotEmpty) {
            final inputValue = controller.text.trim();
            // Try to convert to number (if the foreign key is a number type)
            final numValue = num.tryParse(inputValue);
            finalForeignKeyValues[entry.key] = numValue ?? inputValue;
          }
        }
      }

      Navigator.of(context).pop({
        'count': count,
        'method': _method,
        'foreignKeyValues': finalForeignKeyValues,
        'foreignKeyModes': _foreignKeyModes,
        'foreignKeyIdLists': _foreignKeyIdLists,
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Test Data'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_isLoading)
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: CircularProgressIndicator(),
              )
            else ...[
              // If there are missing main table data, display a warning
              if (_missingForeignKeyTables.isNotEmpty)
                Container(
                  padding: const EdgeInsets.all(12.0),
                  margin: const EdgeInsets.only(bottom: 16.0),
                  decoration: BoxDecoration(
                    color: Colors.orange.shade50,
                    border: Border.all(color: Colors.orange.shade300),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(Icons.warning_amber_rounded,
                              color: Colors.orange.shade700, size: 20),
                          const SizedBox(width: 8),
                          Text(
                            'Missing main table data',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.orange.shade700),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'The following tables have no data, please add first:\n${_missingForeignKeyTables.map((t) => '• $t').join('\n')}',
                        style: TextStyle(color: Colors.orange.shade700),
                      ),
                    ],
                  ),
                ),
              TextField(
                controller: _controller,
                autofocus: true,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: 'Number of records to add',
                  border: OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 20),
              // Display foreign key selector
              ..._foreignKeyOptions.entries.map((entry) {
                final fkField = entry.key;
                final options = entry.value;
                final refTable = _foreignKeyFieldMap[fkField] ?? '';
                final selectedValue = _selectedForeignKeyValues[fkField];
                final mode = _foreignKeyModes[fkField] ?? ForeignKeyMode.random;
                final totalCount = _foreignKeyTotalCounts[fkField] ?? 0;
                final displayCount = options.length;
                final useManual = _useManualInput[fkField] ?? false;

                return Padding(
                  padding: const EdgeInsets.only(bottom: 16.0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              '$fkField (from $refTable)',
                              style: const TextStyle(
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          ),
                          Text(
                            totalCount > displayCount
                                ? '($displayCount/$totalCount records)'
                                : '($totalCount records)',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      // Mode selection
                      RadioGroup<ForeignKeyMode>(
                        groupValue: mode,
                        onChanged: (value) {
                          setState(() {
                            _foreignKeyModes[fkField] = value!;
                          });
                        },
                        child: const Row(
                          children: [
                            Expanded(
                              child: RadioListTile<ForeignKeyMode>(
                                title: Text('Fixed value'),
                                value: ForeignKeyMode.fixed,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                            Expanded(
                              child: RadioListTile<ForeignKeyMode>(
                                title: Text('Random value'),
                                value: ForeignKeyMode.random,
                                dense: true,
                                contentPadding: EdgeInsets.zero,
                              ),
                            ),
                          ],
                        ),
                      ),
                      // Fixed value mode display dropdown or manual input
                      if (mode == ForeignKeyMode.fixed) ...[
                        // Select input method
                        RadioGroup<bool>(
                          groupValue: useManual,
                          onChanged: (value) {
                            setState(() {
                              _useManualInput[fkField] = value!;
                            });
                          },
                          child: const Row(
                            children: [
                              Expanded(
                                child: RadioListTile<bool>(
                                  title: Text('Dropdown selection'),
                                  value: false,
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                              Expanded(
                                child: RadioListTile<bool>(
                                  title: Text('Manual input'),
                                  value: true,
                                  dense: true,
                                  contentPadding: EdgeInsets.zero,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        if (!useManual)
                          DropdownButtonFormField<dynamic>(
                            initialValue: selectedValue,
                            decoration: InputDecoration(
                              labelText: 'Select foreign key value',
                              border: const OutlineInputBorder(),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              helperText: totalCount > displayCount
                                  ? 'Only display the first $displayCount records, total $totalCount records'
                                  : null,
                            ),
                            items: options.map((option) {
                              final pkValue = option.values.first;
                              return DropdownMenuItem<dynamic>(
                                value: pkValue,
                                child: Text('$pkValue'),
                              );
                            }).toList(),
                            onChanged: (value) {
                              setState(() {
                                _selectedForeignKeyValues[fkField] = value;
                              });
                            },
                          )
                        else
                          TextField(
                            controller: _manualInputControllers[fkField],
                            decoration: InputDecoration(
                              labelText: 'Manual input foreign key value',
                              border: const OutlineInputBorder(),
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              helperText: 'Enter valid $refTable table ID',
                              hintText: 'For example: 1, 2, 100',
                            ),
                            keyboardType: TextInputType.number,
                            onChanged: (value) {
                              // Real-time update value
                              if (value.isNotEmpty) {
                                final numValue = num.tryParse(value);
                                if (numValue != null) {
                                  _selectedForeignKeyValues[fkField] = numValue;
                                } else {
                                  _selectedForeignKeyValues[fkField] = value;
                                }
                              }
                            },
                          ),
                      ] else
                        Container(
                          padding: const EdgeInsets.all(12.0),
                          decoration: BoxDecoration(
                            color: Colors.blue.shade50,
                            border: Border.all(color: Colors.blue.shade200),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            children: [
                              Icon(Icons.shuffle,
                                  size: 16, color: Colors.blue.shade700),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  totalCount >
                                          (_foreignKeyIdLists[fkField]
                                                  ?.length ??
                                              0)
                                      ? 'Will randomly select from ${_foreignKeyIdLists[fkField]?.length ?? 0} records (total $totalCount records)'
                                      : 'Will randomly select from $totalCount records',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.blue.shade700,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                );
              }),
              const SizedBox(height: 20),
              const Text('Insertion Method'),
              RadioGroup<InsertMethod>(
                groupValue: _method,
                onChanged: (value) {
                  setState(() {
                    _method = value!;
                  });
                },
                child: const Column(
                  children: [
                    RadioListTile<InsertMethod>(
                      title: Text('Batch Insert'),
                      value: InsertMethod.batch,
                    ),
                    RadioListTile<InsertMethod>(
                      title: Text('Insert One by One'),
                      value: InsertMethod.oneByOne,
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _isLoading ? null : _onAdd,
          child: const Text('Add'),
        ),
      ],
    );
  }
}

/// A dialog for editing a single row of data.
class EditRowDialog extends StatefulWidget {
  final TableSchema schema;
  final Map<String, dynamic> initialData;

  const EditRowDialog(
      {super.key, required this.schema, required this.initialData});

  @override
  State<EditRowDialog> createState() => _EditRowDialogState();
}

class _EditRowDialogState extends State<EditRowDialog> {
  final _formKey = GlobalKey<FormState>();
  late Map<String, TextEditingController> _controllers;
  late Map<String, dynamic> _updatedData;

  @override
  void initState() {
    super.initState();
    _updatedData = Map.from(widget.initialData);

    // Initialize controllers for all fields defined in the schema
    _controllers = {
      for (var field in widget.schema.fields)
        field.name: TextEditingController(
            text: '${widget.initialData[field.name] ?? ''}'),
    };

    // Also add a controller for the primary key, which will be read-only
    final pkName = widget.schema.primaryKeyConfig.name;
    if (!_controllers.containsKey(pkName) &&
        widget.initialData.containsKey(pkName)) {
      _controllers[pkName] =
          TextEditingController(text: '${widget.initialData[pkName]}');
    }
  }

  @override
  void dispose() {
    for (var controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  void _onSave() {
    if (_formKey.currentState!.validate()) {
      _formKey.currentState!.save();
      Navigator.of(context).pop(_updatedData);
    }
  }

  dynamic _convertValue(String? value, DataType type) {
    if (value == null || value.isEmpty || value.toLowerCase() == 'null') {
      return null;
    }
    switch (type) {
      case DataType.integer:
        return int.tryParse(value);
      case DataType.double:
        return double.tryParse(value);
      case DataType.boolean:
        return value.toLowerCase() == 'true' || value == '1';
      default:
        return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final pkName = widget.schema.primaryKeyConfig.name;

    return AlertDialog(
      title: Text('Edit Record: ${widget.initialData[pkName]}'),
      content: Form(
        key: _formKey,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Display the primary key as read-only if it exists
              if (_controllers.containsKey(pkName))
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: TextFormField(
                    controller: _controllers[pkName],
                    readOnly: true,
                    decoration: InputDecoration(
                      labelText: '$pkName (Primary Key)',
                      border: const OutlineInputBorder(),
                      filled: true,
                      fillColor: Colors.grey.shade200,
                    ),
                  ),
                ),
              // Editable fields from schema
              ...widget.schema.fields.map((field) {
                // Don't show the primary key again if it's also listed in fields
                if (field.name == pkName) return const SizedBox.shrink();

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8.0),
                  child: TextFormField(
                    controller: _controllers[field.name],
                    decoration: InputDecoration(
                      labelText: field.name,
                      border: const OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (!field.nullable && (value == null || value.isEmpty)) {
                        return 'This field cannot be empty.';
                      }
                      return null;
                    },
                    onSaved: (newValue) {
                      _updatedData[field.name] =
                          _convertValue(newValue, field.type);
                    },
                  ),
                );
              }),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _onSave,
          child: const Text('Save'),
        ),
      ],
    );
  }
}

class BatchUpdateDialog extends StatefulWidget {
  final TableSchema schema;
  const BatchUpdateDialog({super.key, required this.schema});

  @override
  State<BatchUpdateDialog> createState() => _BatchUpdateDialogState();
}

class _BatchUpdateDialogState extends State<BatchUpdateDialog> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedField;
  final _valueController = TextEditingController();
  late final List<FieldSchema> _updatableFields;

  @override
  void initState() {
    super.initState();
    // Exclude primary key and unique fields from batch updates
    final pkName = widget.schema.primaryKeyConfig.name;
    _updatableFields = widget.schema.fields
        .where((f) => f.name != pkName && !f.unique)
        .toList();
    if (_updatableFields.isNotEmpty) {
      _selectedField = _updatableFields.first.name;
    }
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  void _onSave() {
    if (_formKey.currentState!.validate() && _selectedField != null) {
      final field =
          _updatableFields.firstWhere((f) => f.name == _selectedField);
      final value = _convertValue(_valueController.text, field.type);
      Navigator.of(context).pop({'field': _selectedField, 'value': value});
    }
  }

  dynamic _convertValue(String? value, DataType type) {
    if (value == null || value.isEmpty || value.toLowerCase() == 'null') {
      return null;
    }
    switch (type) {
      case DataType.integer:
        return int.tryParse(value);
      case DataType.double:
        return double.tryParse(value);
      case DataType.boolean:
        return value.toLowerCase() == 'true' || value == '1';
      default:
        return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Batch Update Selected'),
      content: _updatableFields.isEmpty
          ? const Text(
              'No updatable (non-unique) fields available for this table.')
          : Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: _selectedField,
                    items: _updatableFields.map((field) {
                      return DropdownMenuItem(
                        value: field.name,
                        child: Text(field.name),
                      );
                    }).toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedField = value;
                        });
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: 'Field to Update',
                      border: OutlineInputBorder(),
                    ),
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _valueController,
                    decoration: const InputDecoration(
                      labelText: 'New Value',
                      hintText: 'Enter the new value for all selected rows',
                      border: OutlineInputBorder(),
                    ),
                    validator: (value) {
                      if (_selectedField == null) return null;
                      final field = _updatableFields
                          .firstWhere((f) => f.name == _selectedField);
                      if (!field.nullable && (value == null || value.isEmpty)) {
                        return 'This field cannot be empty.';
                      }
                      return null;
                    },
                  )
                ],
              ),
            ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _updatableFields.isEmpty ? null : _onSave,
          child: const Text('Update All'),
        ),
      ],
    );
  }
}

class CustomDeleteDialog extends StatefulWidget {
  final TableSchema schema;

  const CustomDeleteDialog({super.key, required this.schema});

  @override
  State<CustomDeleteDialog> createState() => _CustomDeleteDialogState();
}

class _CustomDeleteDialogState extends State<CustomDeleteDialog> {
  final _formKey = GlobalKey<FormState>();
  String? _selectedField;
  String _selectedOperator = '>';
  final _valueController = TextEditingController();

  @override
  void initState() {
    super.initState();
    _selectedField = widget.schema.primaryKeyConfig.name;
  }

  @override
  void dispose() {
    _valueController.dispose();
    super.dispose();
  }

  void _onConfirm() {
    if (_formKey.currentState!.validate()) {
      final fieldSchema = _getSelectedFieldSchema();
      if (fieldSchema == null) return;

      final convertedValue =
          _convertValue(_valueController.text, fieldSchema.type);

      Navigator.of(context).pop({
        'field': _selectedField,
        'operator': _selectedOperator,
        'value': convertedValue,
      });
    }
  }

  FieldSchema? _getSelectedFieldSchema() {
    if (_selectedField == widget.schema.primaryKeyConfig.name) {
      // Create a pseudo-schema for the primary key for type conversion
      return FieldSchema(name: _selectedField!, type: DataType.integer);
    }
    return widget.schema.fields.firstWhere((f) => f.name == _selectedField);
  }

  dynamic _convertValue(String? value, DataType type) {
    if (value == null || value.isEmpty || value.toLowerCase() == 'null') {
      return null;
    }
    switch (type) {
      case DataType.integer:
        return int.tryParse(value);
      case DataType.double:
        return double.tryParse(value);
      case DataType.boolean:
        return value.toLowerCase() == 'true' || value == '1';
      default:
        return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final allFields = [
      widget.schema.primaryKeyConfig.name,
      ...widget.schema.fields.map((f) => f.name)
    ];

    final selectedFieldSchema = _getSelectedFieldSchema();
    final isNumeric = selectedFieldSchema?.type == DataType.integer ||
        selectedFieldSchema?.type == DataType.double;

    return AlertDialog(
      title: const Text('Custom Delete'),
      content: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Delete records based on the following condition:'),
            const SizedBox(height: 24),
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  flex: 4,
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedField,
                    items: allFields
                        .map((field) =>
                            DropdownMenuItem(value: field, child: Text(field)))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedField = value;
                          // Reset value when field changes
                          _valueController.clear();
                        });
                      }
                    },
                    decoration: const InputDecoration(
                      labelText: 'Field',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  flex: 3,
                  child: DropdownButtonFormField<String>(
                    initialValue: _selectedOperator,
                    items: ['>', '>=', '<', '<=', '=', '!=', 'LIKE']
                        .map((op) =>
                            DropdownMenuItem(value: op, child: Text(op)))
                        .toList(),
                    onChanged: (value) {
                      if (value != null) {
                        setState(() {
                          _selectedOperator = value;
                        });
                      }
                    },
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _valueController,
              autofocus: true,
              keyboardType:
                  isNumeric ? TextInputType.number : TextInputType.text,
              inputFormatters:
                  isNumeric ? [FilteringTextInputFormatter.digitsOnly] : [],
              decoration: const InputDecoration(
                labelText: 'Value',
                border: OutlineInputBorder(),
              ),
              validator: (value) {
                if (value == null || value.isEmpty) {
                  return 'Required';
                }
                if (isNumeric && int.tryParse(value) == null) {
                  return 'Invalid number';
                }
                // Add more validation for other types if needed
                return null;
              },
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _onConfirm,
          style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
          child: const Text('Delete', style: TextStyle(color: Colors.white)),
        ),
      ],
    );
  }
}

class FilterDialog extends StatefulWidget {
  final TableSchema schema;
  final List<Map<String, dynamic>> existingFilters;

  const FilterDialog(
      {super.key, required this.schema, required this.existingFilters});

  @override
  State<FilterDialog> createState() => _FilterDialogState();
}

class _FilterDialogState extends State<FilterDialog> {
  late List<_FilterCondition> _filters;
  final _formKey = GlobalKey<FormState>();

  @override
  void initState() {
    super.initState();
    _filters = widget.existingFilters.map((f) {
      return _FilterCondition(
        field: f['field'],
        operator: f['operator'],
        valueController: TextEditingController(text: '${f['value']}'),
      );
    }).toList();

    if (_filters.isEmpty) {
      _filters.add(
        _FilterCondition(
          field: _getAvailableFields().first,
          operator: '=',
          valueController: TextEditingController(),
        ),
      );
    }
  }

  @override
  void dispose() {
    for (final filter in _filters) {
      filter.valueController.dispose();
    }
    super.dispose();
  }

  void _addFilter() {
    setState(() {
      _filters.add(_FilterCondition(
        field: _getAvailableFields().first,
        operator: '=',
        valueController: TextEditingController(),
      ));
    });
  }

  void _removeFilter(int index) {
    setState(() {
      _filters.removeAt(index);
    });
  }

  List<String> _getAvailableFields() {
    final pkName = widget.schema.primaryKeyConfig.name;
    final fieldNames = widget.schema.fields.map((f) => f.name).toSet();
    fieldNames.add(pkName);
    return fieldNames.toList()..sort();
  }

  void _onApply() {
    if (_formKey.currentState!.validate()) {
      final newFilters = _filters.map((f) {
        final fieldSchema = _getFieldSchema(f.field);
        return {
          'field': f.field,
          'operator': f.operator,
          'value': _convertValue(
              f.valueController.text, fieldSchema?.type ?? DataType.text),
        };
      }).toList();
      Navigator.of(context).pop(newFilters);
    }
  }

  FieldSchema? _getFieldSchema(String fieldName) {
    if (fieldName == widget.schema.primaryKeyConfig.name) {
      // Create a pseudo-schema for the primary key for type conversion
      return FieldSchema(name: fieldName, type: DataType.integer);
    }
    try {
      return widget.schema.fields.firstWhere((f) => f.name == fieldName);
    } catch (_) {
      return null;
    }
  }

  dynamic _convertValue(String? value, DataType type) {
    if (value == null || value.isEmpty || value.toLowerCase() == 'null') {
      return null;
    }
    switch (type) {
      case DataType.integer:
        return int.tryParse(value);
      case DataType.double:
        return double.tryParse(value);
      case DataType.boolean:
        return value.toLowerCase() == 'true' || value == '1';
      default:
        return value;
    }
  }

  @override
  Widget build(BuildContext context) {
    final availableFields = _getAvailableFields();
    return AlertDialog(
      title: const Text('Set Filter Conditions'),
      content: Form(
        key: _formKey,
        child: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Expanded(
                child: _filters.isEmpty
                    ? const Center(
                        child: Text('No filters. Add one below.'),
                      )
                    : ListView.builder(
                        shrinkWrap: true,
                        itemCount: _filters.length,
                        itemBuilder: (context, index) {
                          final filter = _filters[index];
                          return _buildFilterRow(
                              filter, index, availableFields);
                        },
                      ),
              ),
              const SizedBox(height: 16),
              ElevatedButton.icon(
                onPressed: _addFilter,
                icon: const Icon(Icons.add),
                label: const Text('Add Condition'),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: _onApply,
          child: const Text('Apply Filters'),
        ),
      ],
    );
  }

  Widget _buildFilterRow(
      _FilterCondition filter, int index, List<String> availableFields) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: 8.0,
      ),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Expanded(
                      flex: 5,
                      child: DropdownButtonFormField<String>(
                        initialValue: filter.field,
                        items: availableFields
                            .map((f) =>
                                DropdownMenuItem(value: f, child: Text(f)))
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              filter.field = value;
                            });
                          }
                        },
                        decoration: const InputDecoration(
                            border: OutlineInputBorder(), labelText: 'Field'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      flex: 3,
                      child: DropdownButtonFormField<String>(
                        initialValue: filter.operator,
                        items: ['=', '!=', '>', '>=', '<', '<=', 'LIKE']
                            .map((op) =>
                                DropdownMenuItem(value: op, child: Text(op)))
                            .toList(),
                        onChanged: (value) {
                          if (value != null) {
                            setState(() {
                              filter.operator = value;
                            });
                          }
                        },
                        decoration:
                            const InputDecoration(border: OutlineInputBorder()),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                flex: 5,
                child: TextFormField(
                  controller: filter.valueController,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Value',
                  ),
                  validator: (value) {
                    if (value == null || value.isEmpty) {
                      return 'Required';
                    }
                    return null;
                  },
                ),
              ),
              IconButton(
                icon:
                    const Icon(Icons.remove_circle_outline, color: Colors.red),
                onPressed: () => _removeFilter(index),
              )
            ],
          ),
        ],
      ),
    );
  }
}

class _FilterCondition {
  String field;
  String operator;
  TextEditingController valueController;

  _FilterCondition({
    required this.field,
    required this.operator,
    required this.valueController,
  });
}

class VectorSearchDialog extends StatefulWidget {
  const VectorSearchDialog({super.key});

  @override
  State<VectorSearchDialog> createState() => _VectorSearchDialogState();
}

class _VectorSearchDialogState extends State<VectorSearchDialog> {
  int _iterations = 1;
  int _topK = 10;
  final _customController = TextEditingController(text: '1');

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Row(
        children: [
          Icon(Icons.query_stats, color: Color(0xff0aa6e8)),
          SizedBox(width: 10),
          Expanded(
            child: Text(
              'Vector Search Benchmark',
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Search Config',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 16),
            const Text('Top-K (Number of neighbors):'),
            Slider(
              value: _topK.toDouble(),
              min: 1,
              max: 100,
              divisions: 99,
              label: _topK.toString(),
              activeColor: const Color(0xff0aa6e8),
              onChanged: (v) => setState(() => _topK = v.toInt()),
            ),
            Center(child: Text('$_topK results per search')),
            const SizedBox(height: 24),
            const Text('Iterations:',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [1, 100, 1000, 10000].map((count) {
                final isSelected = _iterations == count;
                return ChoiceChip(
                  label: Text(count == 1 ? 'Single' : count.toString()),
                  selected: isSelected,
                  selectedColor: const Color(0xff0aa6e8),
                  labelStyle: TextStyle(
                    color: isSelected ? Colors.white : Colors.black,
                  ),
                  onSelected: (selected) {
                    if (selected) {
                      setState(() {
                        _iterations = count;
                        _customController.text = count.toString();
                      });
                    }
                  },
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _customController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Custom Iterations',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.repeat),
              ),
              onChanged: (v) {
                final val = int.tryParse(v);
                if (val != null && val > 0) {
                  setState(() => _iterations = val);
                }
              },
            ),
            const SizedBox(height: 16),
            const Text(
              'Total searches to perform. Results will be averaged to measure latency.',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            Navigator.of(context).pop({
              'iterations': _iterations,
              'topK': _topK,
            });
          },
          style: ElevatedButton.styleFrom(
            backgroundColor: const Color(0xff0aa6e8),
            foregroundColor: Colors.white,
          ),
          child: const Text('Start Benchmark'),
        ),
      ],
    );
  }
}
