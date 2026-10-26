import '../../core/engine/data_store_impl.dart';
import '../../core/storage/path_manager.dart';
import '../../model/table_context.dart';
import '../../model/table_identity.dart';

import 'package:path/path.dart' as p;

/// Engine-v3 on-disk layout kept under `ngh_old/` during v4 rebuild.
final class LegacyNghPaths {
  static const String oldRootName = 'ngh_old';
  static const String postingDir = 'posting';
  static const String navBlobName = 'nav_graph.ngh';

  static String oldIndexRoot(
    PathManager paths,
    TableContext table,
    IndexUid indexUid,
  ) {
    return p.join(paths.getIndexPathByContext(table, indexUid), oldRootName);
  }

  static String postingPartition(
    DataStoreImpl db,
    TableContext table,
    IndexUid indexUid,
    int partitionNo,
  ) {
    final dirIndex = partitionNo ~/ db.maxEntriesPerDir;
    return p.join(
      oldIndexRoot(db.pathManager, table, indexUid),
      postingDir,
      'dir_$dirIndex',
      'p$partitionNo.ngh',
    );
  }

  static String navGraphBlob(
    PathManager paths,
    TableContext table,
    IndexUid indexUid,
  ) {
    return p.join(
      oldIndexRoot(paths, table, indexUid),
      navBlobName,
    );
  }
}
