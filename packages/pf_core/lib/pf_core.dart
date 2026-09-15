/// PF Wallet 领域层。
///
/// 依赖规则（由 review 与 guards 门禁共同保证）：
///   - 本包不得依赖任何三方包，也不得依赖 Flutter。
///   - 本包不得 import 任何 `pf_*` 兄弟包 —— 它是依赖树的叶子。
///
/// 之所以把「值对象 + 错误码 + ID + 时钟」单独拆出来，而不是塞进数据层：
/// 双端（移动 / 桌面）与测试套件都要用它们，且它们必须与具体存储、
/// 具体加密实现无关。把它们钉在这一层，就杜绝了「算钱的地方偷偷读了数据库」。
library;

export 'src/bytes.dart';
export 'src/clock.dart';
export 'src/errors.dart';
export 'src/log.dart';
export 'src/money.dart';
export 'src/ulid.dart';
export 'src/version.dart';
