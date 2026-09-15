/// PF Wallet 数据层。
///
/// 本层是**唯一**允许接触 SQLCipher 的地方。
/// 领域层与表现层只能通过本层暴露的 DAO 访问数据，
/// 不允许出现「顺手写个 SQL」的情况 —— 那样会让
/// 「所有查询都跑在加密连接上」这条保证失去意义。
library;

export 'src/database.dart';
export 'src/migration.dart';
