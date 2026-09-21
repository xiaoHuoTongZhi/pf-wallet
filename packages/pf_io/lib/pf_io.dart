/// PF Wallet 导入导出与同步。
///
/// 本层不认识 SQLite，也不认识文件系统 ——
/// 它只做「两组版本元数据之间如何裁决」这一件事，以及描述导入导出的契约。
/// 把这件事单独成层，是为了让它能被纯逻辑地测试：
/// 合并算法的正确性不该依赖数据库是否装好。
library;

export 'src/export_payload.dart';
export 'src/exporter.dart';
export 'src/import_apply.dart';
export 'src/import_file.dart';
export 'src/import_merge.dart';
export 'src/import_payload.dart';
export 'src/import_reference_fix.dart';
export 'src/record_version.dart';
export 'src/transfer.dart';
