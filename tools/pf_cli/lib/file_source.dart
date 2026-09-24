/// CLI 与磁盘的接触面。
///
/// 这里只有三件事，但每一件都做成**可注入的纯函数**，理由不是洁癖：
///
///   1. [FileBytesReader] —— 读文件字节。注入之后测试不必碰磁盘，而
///      「文件不存在」「权限不足」这些分支才**测得到**。用真的文件系统时，
///      这类反例要么写不出来，要么依赖运行环境（CI 上跑 root 就不报 EACCES）。
///   2. [decodePasswordBytes] —— 把密码文件的字节解成密码。这段逻辑有真实
///      且反直觉的细节（BOM、末尾换行），不锁死的话会以「密码明明是对的，
///      却报密码错」的形式出现 —— 而那是最难排查的一类失败。
///   3. [FileTextWriter] —— 写文本文件。跨实现校验产出的报告要**指定 UTF-8**
///      落盘：Windows 控制台的默认代码页不是 UTF-8，靠重定向拿到的字节
///      会随机器而变，而那份报告要拿去与另一套实现逐字节 diff。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// 读一个文件的全部字节。读不到时抛 [FileSystemException]。
///
/// 用同步版本是刻意的：CLI 是「跑一次就退出」的进程，异步读只会把
/// `await` 传染到调用链上，换不来任何东西（没有并发可重排）。
typedef FileBytesReader = Uint8List Function(String path);

/// 真实文件系统的缺省实现。
Uint8List readFileBytes(String path) => File(path).readAsBytesSync();

/// 写一个文本文件。**编码显式写死 UTF-8**，不跟随平台默认。
///
/// 理由是可复现性：本工具要在三平台 CI 上跑，而 Windows 上 `stdout` 的
/// 默认编码不是 UTF-8（是控制台代码页）。让报告经过重定向取字节，
/// 就会得到「同一份报告，Linux 上是 UTF-8、Windows 上是 GBK」——
/// 而它要拿去与另一套实现逐字节 diff，编码一变就是一片假差异。
/// 写文件时把编码钉死，这条路径就与平台无关了。
typedef FileTextWriter = void Function(String path, String text);

/// 真实文件系统的缺省实现。不写 BOM（`writeAsStringSync` 的 `utf8` 不带 BOM）。
void writeTextFile(String path, String text) =>
    File(path).writeAsStringSync(text, encoding: utf8, flush: true);

/// 取路径的最后一段。`/` 与 `\` 都认（本工具要在三平台 CI 上跑）。
///
/// 用途只有一个：把 `imported.fileName` 填成人看得懂的名字。
/// 那个字段**不参与任何路径构造**（见 `ImportedFile` 的注释），
/// 所以这里不需要、也不应该引入 `package:path` 去做规范化 ——
/// 传进来的路径只可能来自本机命令行，能取到最后一段就够了。
String baseNameOf(String path) {
  final cut = path.lastIndexOf(RegExp(r'[/\\]'));
  return cut < 0 ? path : path.substring(cut + 1);
}

/// 主密码的来源二选一：环境变量 [kPasswordEnvVar] 或 `--password-file`。
///
/// **刻意不提供 `--password <明文>`**：命令行参数会同时留在两个地方 ——
/// shell 历史（`~/.bash_history`、PowerShell 的 PSReadLine 历史）与进程列表
/// （`ps -ef` / 任务管理器）。在任何多用户或多进程的机器上，
/// 「备份密码」出现在这两处就等于泄露；而备份密码泄露等于整个账本泄露。
/// 这不是洁癖，是把一条本来会被随手用上的捷径直接堵掉。
///
/// 环境变量优于命令行的地方在于：它不进历史、也不出现在 `ps` 的参数列里
/// （Linux 的 `/proc/<pid>/environ` 仍是 root 可读，但在容器/CI 里可控）。
/// 最安全的是 `--password-file`，这也是帮助文本里的首选。
const String kPasswordEnvVar = 'PF_PASSWORD';

/// 把密码文件的字节解成密码。
///
/// 做两件**必须**做的剥离，否则会出现最难排查的一类失败 ——
/// 「密码明明是对的，却报密码错」：
///
///   1. **UTF-8 BOM**（`EF BB BF`）。Windows 记事本「另存为 UTF-8」会加上，
///      于是密码的实际首字节变成 BOM —— 用户看不出，粘贴时也不知道。
///   2. **末尾的一个换行**（`\n`，或 `\r\n`）。`echo secret > pw.txt`、
///      `echo secret | clip`、多数编辑器的「保存」都会带上。
///
/// 只剥**一个**换行，不做整段 trim：密码本身可以以空格或制表符开头结尾，
/// 那些字符是有意义的（去掉它们等于改变了用户设定的密码）。
/// 要剥的只是「工具顺手加上去的那一个」。
Uint8List decodePasswordBytes(Uint8List raw) {
  var start = 0;
  var end = raw.length;

  if (end - start >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) {
    start = 3;
  }
  if (end > start && raw[end - 1] == 0x0A) {
    end--;
    if (end > start && raw[end - 1] == 0x0D) {
      end--;
    }
  }
  return Uint8List.fromList(raw.sublist(start, end));
}
