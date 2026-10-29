/// 通知来源的「角色」。
///
/// 存在的理由：用户反馈「微信绑的银行卡，扣费两个都有通知」——
/// 微信支付通知和银行扣费通知（或银行短信）说的是同一笔钱，
/// 但它们的包名不同，旧的去重逻辑按包名匹配，两条通知各记一笔，
/// 账本里就出现了重复账单。
///
/// 要把这两条认成同一笔，必须知道「谁是支付平台、谁是银行」。
/// 不靠正文关键词判断并不可靠：微信支付通知的完整版可能写着
/// 「使用招商银行(1234)信用卡支付31.31元」，含「信用卡」，
/// 用关键词判会把支付平台通知误判成银行通知。
///
/// 所以这里**以包名为准**，正文只作为短信 App 的补充判据
/// （短信 App 的包名只能说明「这是条短信」，内容才说明是谁发的）。
library;

/// 来源角色。
enum SourceRole {
  /// 支付平台：微信、支付宝、云闪付等。
  platform,

  /// 银行：银行 App 的通知，或银行发来的短信。
  bank,

  /// 其它：识别不出来，不参与跨来源合并。
  other,
}

/// 支付平台 App 的包名。
///
/// 「平台」和「银行」在这里的划分依据是**谁发的通知**：
/// 平台通知讲的是「你用某个支付渠道付了钱」，银行通知讲的是「你的卡被扣了钱」。
const Set<String> kPlatformPackages = <String>{
  'com.tencent.mm', // 微信
  'com.eg.android.alipaygphone', // 支付宝
  'com.unionpay', // 云闪付 / 银联
  'com.tencent.mobileqq', // QQ
  'com.jd.jrapp', // 京东金融
  'com.sankuai.meituan', // 美团
  'com.ss.android.ugc.aweme', // 抖音
  'com.taobao.taobao', // 淘宝
  'com.xunmeng.pinduoduo', // 拼多多
  'com.meituan.retail.waimai', // 美团外卖
};

/// 银行 App 的包名 -> 银行标识。
///
/// [kBankPackages] 只有 18 家银行，是不全的：
/// 信用卡 App（掌上生活、动卡空间、口袋银行…）、地方银行、民营银行、
/// 数字银行都不在里面。用户装的银行 App 只要不在这张表里，
/// 它的通知就会被判成「其它」，于是「微信 + 银行 App」这对本该合并的
/// 重复账单合并不了——这正是用户反馈的「账单依旧会重复记录」。
///
/// 所以除了包名，还要能**从正文里认出银行名**（见 [bankIdOfContent]）。
/// 这张表能认出来的就直接认，省得去猜。
const Map<String, String> kBankPackageIds = <String, String>{
  'com.icbc': 'icbc', // 中国工商银行
  'com.chinamworld.main': 'ccb', // 中国建设银行
  'com.cmbchina': 'cmbchina', // 招商银行
  'com.android.bankabc': 'abc', // 中国农业银行
  'com.bankcomm.bankcomm': 'bocom', // 交通银行
  'com.cebbank.mobile': 'ceb', // 中国光大银行
  'com.citic': 'citic', // 中信银行
  'com.hxb': 'hxb', // 华夏银行
  'com.yitong.mbank': 'psbc', // 中国邮政储蓄银行
  'com.pingan.paces.ccms': 'pingan', // 平安银行
  'com.cgsbank': 'cgb', // 广发银行
  'com.cib.bank': 'cib', // 兴业银行
  'com.bankofshanghai': 'bosc', // 上海银行
  'com.psbc.mobile': 'psbc', // 邮储银行
  'com.spdb': 'spdb', // 浦发银行
  'com.cmbc.guilin': 'cmbc', // 桂林银行
  'com.hncb.wy': 'hncb', // 湖南银行
  'com.cdbgzbank': 'cgb', // 广东发展银行
};

/// 银行包名集合（保留旧名字，兼容既有调用）。
final Set<String> kBankPackages = kBankPackageIds.keys.toSet();

/// 银行中文名 -> 银行标识。
///
/// 用于**从通知正文里认出是哪家银行**。
///
/// 为什么需要它：银行 App 的包名穷举不完（信用卡 App、地方银行、
/// 数字银行），但**银行短信和银行通知的正文里几乎总会写银行名**——
/// 「【招商银行】您尾号8888的信用卡于…」。
/// 微信支付通知里也常带：「使用招商银行(1234)信用卡支付31.31元」。
///
/// 有了它，两条通知里出现**同一家银行**就是「同一笔」的强证据，
/// 不再依赖「平台 ↔ 银行」这种配对——那对配对在银行 App 认不出来时
/// 会整条漏掉。
///
/// 长名要能盖住短名（「中国工商银行」盖住「工商银行」），
/// 所以匹配时按名字长度从长到短找。
const Map<String, String> kBankNames = <String, String>{
  '中国工商银行': 'icbc',
  '中国建设银行': 'ccb',
  '中国农业银行': 'abc',
  '中国邮政储蓄银行': 'psbc',
  '中国光大银行': 'ceb',
  '中国民生银行': 'cmbc',
  '中国银行': 'boc',
  '中国平安银行': 'pingan',
  '交通银行': 'bocom',
  '招商银行': 'cmbchina',
  '中信银行': 'citic',
  '华夏银行': 'hxb',
  '广发银行': 'cgb',
  '广东发展银行': 'cgb',
  '兴业银行': 'cib',
  '浦发银行': 'spdb',
  '平安银行': 'pingan',
  '邮储银行': 'psbc',
  '民生银行': 'cmbc',
  '光大银行': 'ceb',
  '工商银行': 'icbc',
  '建设银行': 'ccb',
  '农业银行': 'abc',
  '恒丰银行': 'hfbank',
  '渤海银行': 'cgb',
  '北京银行': 'bob',
  '上海银行': 'bosc',
  '江苏银行': 'jsbank',
  '宁波银行': 'nbcb',
  '南京银行': 'njcb',
  '杭州银行': 'hzcb',
  '徽商银行': 'hsybank',
  '长沙银行': 'cscb',
  '成都银行': 'bocd',
  '郑州银行': 'zzcb',
  '青岛银行': 'qdbank',
  '天津银行': 'tjb',
  '重庆银行': 'cqcb',
  '富滇银行': 'fdb',
  '微众银行': 'webank',
  '网商银行': 'mybank',
  '百度银行': 'duxiaobank',
  '四川天府银行': 'tfbank',
  '汉口银行': 'hkbank',
};

/// 银行名按长度倒序排好的列表（长的优先匹配）。
///
/// 「中国工商银行」必须排在「工商银行」前面，
/// 否则「工商银行」先命中，id 反而对不上——虽然这里两个都映射到 icbc，
/// 但「广东发展银行」和「广发银行」这类就不一样了。
final List<MapEntry<String, String>> kBankNamesByLength = () {
  final list = kBankNames.entries.toList()
    ..sort((a, b) => b.key.length.compareTo(a.key.length));
  return list;
}();

/// 短信 App 的包名。
///
/// 短信本身不能说明是谁发的，得看内容；
/// 银行短信的特征很稳定（储蓄卡 / 借记卡 / 尾号 / 账户余额 / 代扣）。
const Set<String> kSmsPackages = <String>{
  'com.android.mms',
  'com.android.providers.telephony',
  'com.ss.android.mms',
  'com.miui.mms',
  'com.coloros.mms',
  'com.htc.mms',
  'com.android.mms.service',
};

/// 银行短信里的强特征词。
///
/// 只用银行短信基本不会出现的词：
/// 微信支付通知可能提「信用卡」，所以「信用卡」不算强特征；
/// 但「储蓄卡」「借记卡」「尾号」「账户余额」「代扣」几乎只出现在银行短信里。
const List<String> kBankContentHints = <String>[
  '储蓄卡',
  '借记卡',
  '尾号',
  '账户余额',
  '代扣',
  '活期',
  '信用卡还款',
  '快捷支付',
  '网银',
  '手机银行',
  // 下面几个是常见银行短信模板里的说法。
  '网上支付',
  'POS',
  '消费支出',
  '您的账户',
  '账户支出',
];

/// 包名 -> 用户看得懂的来源名。
///
/// 账单页副标题要显示「这笔是从哪来的」，
/// 直接显示 `com.android.mms` 这种包名对用户毫无意义。
const Map<String, String> kPackageDisplayNames = <String, String>{
  // 支付平台
  'com.tencent.mm': '微信',
  'com.eg.android.alipaygphone': '支付宝',
  'com.unionpay': '云闪付',
  'com.tencent.mobileqq': 'QQ',
  'com.jd.jrapp': '京东',
  'com.sankuai.meituan': '美团',
  'com.taobao.taobao': '淘宝',
  'com.xunmeng.pinduoduo': '拼多多',
  'com.ss.android.ugc.aweme': '抖音',
  // 银行
  'com.icbc': '工商银行',
  'com.chinamworld.main': '建设银行',
  'com.cmbchina': '招商银行',
  'com.android.bankabc': '农业银行',
  'com.bankcomm.bankcomm': '交通银行',
  'com.cebbank.mobile': '光大银行',
  'com.citic': '中信银行',
  'com.hxb': '华夏银行',
  'com.yitong.mbank': '邮储银行',
  'com.pingan.paces.ccms': '平安银行',
  'com.cgsbank': '广发银行',
  'com.cib.bank': '兴业银行',
  'com.bankofshanghai': '上海银行',
  'com.psbc.mobile': '邮储银行',
  'com.spdb': '浦发银行',
  'com.cmbc.guilin': '桂林银行',
  'com.hncb.wy': '湖南银行',
  'com.cdbgzbank': '广发银行',
};

/// 短信 App 统一显示成「短信」。
///
/// 短信本身看不出是谁发的，具体哪家银行要从正文里认。
const String kSmsDisplayName = '短信';

/// 来源的可读名字。
///
/// 认不出来的包名返回 null——那种情况干脆不显示来源，
/// 也不显示包名（`com.some.app` 对用户是纯噪音）。
String? displaySource(String? packageName) {
  final pkg = (packageName ?? '').trim().toLowerCase();
  if (pkg.isEmpty) return null;
  final known = kPackageDisplayNames[pkg];
  if (known != null) return known;
  if (kSmsPackages.contains(pkg)) return kSmsDisplayName;
  return null;
}

/// 包名是短信 App 时，用内容判断是不是银行短信。
bool isBankByContent(String content) {
  for (final hint in kBankContentHints) {
    if (content.contains(hint)) return true;
  }
  return false;
}

/// 判断一条通知的来源角色。
///
/// 判定顺序（从可靠到不可靠）：
/// 1. 包名在支付平台表里 -> [SourceRole.platform]
/// 2. 包名在银行 App 表里 -> [SourceRole.bank]
/// 3. 包名是短信 App -> 内容像银行短信就是 [SourceRole.bank]，否则 [SourceRole.other]
/// 4. 其余一律 [SourceRole.other]
///
/// 第 4 条是刻意的保守：认不出来就不参与跨来源合并。
/// 合并错一次用户会平白少一笔账，漏合并一次顶多多一笔账——后者用户自己能删。
///
/// 想拿到更细的身份（是哪家银行），用 [identityOf]。
SourceRole roleOf({String? packageName, required String content}) =>
    identityOf(packageName: packageName, content: content).role;

/// 来源身份：角色 + 具体是哪家银行。
///
/// 为什么要在角色之上再带一个「哪家银行」：
///
/// 跨来源判重原本只认「支付平台 ↔ 银行」这一种配对。
/// 但银行 App 的包名穷举不完——信用卡 App（掌上生活、动卡空间、口袋银行）、
/// 地方银行、民营银行都不在包里。用户装的银行 App 一旦认不出来，
/// 它的通知就成了「其它」，于是「微信 + 银行 App」这对本该合并的
/// 重复账单合并不了。
///
/// 而**通知正文里几乎总会写银行名**：
/// - 银行短信：「【招商银行】您尾号8888的信用卡于…」
/// - 微信支付：「…使用招商银行(1234)信用卡支付31.31元」
///
/// 两条通知里出现同一家银行，就是「同一笔」的强证据——
/// 不再依赖「平台 ↔ 银行」这种配对。
class SourceIdentity {
  /// 来源的角色。
  final SourceRole role;

  /// 认得出的银行标识（如 `cmbchina`）。认不出为 null。
  final String? bankId;

  const SourceIdentity(this.role, [this.bankId]);

  /// 这条通知讲的是不是银行的事。
  bool get isBank => role == SourceRole.bank;

  @override
  String toString() => 'SourceIdentity($role, $bankId)';
}

/// 从通知正文里认出是哪家银行。
///
/// 认不出返回 null。
String? bankIdOfContent(String content) {
  if (content.isEmpty) return null;
  for (final entry in kBankNamesByLength) {
    if (content.contains(entry.key)) return entry.value;
  }
  return null;
}

/// 判断一条通知的完整身份（角色 + 哪家银行）。
///
/// 判定顺序：
/// 1. 包名在支付平台表里 -> platform
///    （正文里的银行名照样记下来——微信支付通知常带银行名，
///    「使用招商银行(1234)信用卡支付」在跨来源判重时非常有用）
/// 2. 包名在银行 App 表里 -> bank，银行 id 直接由包名给出
/// 3. 包名是短信 App -> 正文能认出银行名就是 bank，
///    否则看特征词；都认不出就是 other
/// 4. 其余包名 -> 正文里能认出银行名就是 bank，否则 other
///
/// 第 4 步比 [roleOf] 宽松了一点：只要正文明确写了是哪家银行，
/// 就认为这条通知讲的是银行的事。认不出银行名时仍然保守地当成 other。
SourceIdentity identityOf({String? packageName, required String content}) {
  final pkg = (packageName ?? '').trim().toLowerCase();
  final contentBankId = bankIdOfContent(content);

  if (pkg.isEmpty) {
    return SourceIdentity(
      contentBankId != null ? SourceRole.bank : SourceRole.other,
      contentBankId,
    );
  }

  if (kPlatformPackages.contains(pkg)) {
    return SourceIdentity(SourceRole.platform, contentBankId);
  }

  final packageBankId = kBankPackageIds[pkg];
  if (packageBankId != null) {
    return SourceIdentity(SourceRole.bank, packageBankId);
  }

  if (kSmsPackages.contains(pkg)) {
    if (contentBankId != null) {
      return SourceIdentity(SourceRole.bank, contentBankId);
    }
    return SourceIdentity(
      isBankByContent(content) ? SourceRole.bank : SourceRole.other,
      null,
    );
  }

  // 认不出来的包名：正文里写了银行名就当银行通知。
  return SourceIdentity(
    contentBankId != null ? SourceRole.bank : SourceRole.other,
    contentBankId,
  );
}

/// 两个身份能不能配成「同一笔」。
///
/// 满足其一即可：
/// 1. **支付平台 ↔ 银行**（原有的规则）；
/// 2. **同一家银行**（新增）。
///
/// 第 2 条覆盖了原先漏掉的几个场景：
/// - 银行 App（不在包名表里）+ 银行短信 —— 两边角色都是 bank，配不上；
/// - 银行短信 + 微信支付（正文里都带银行名）—— 短信被当成 other，配不上。
///
/// 误合并的风险很小：要求「认得出同一家银行」比「同金额」强得多，
/// 而同一家银行在几分钟内同额同向的两笔真交易相当罕见。
bool isSamePaymentPair(SourceIdentity a, SourceIdentity b) {
  if (isCrossSourcePair(a.role, b.role)) return true;
  final bankA = a.bankId;
  final bankB = b.bankId;
  return bankA != null && bankA == bankB;
}

/// 两个角色配对起来是不是「支付平台 ↔ 银行」。
///
/// 只有这种配对才允许跨来源合并：
/// 平台通知和银行通知讲的是同一笔钱；
/// 而两个陌生的 App 之间，即使金额时间一样，也可能是两笔真交易。
bool isCrossSourcePair(SourceRole a, SourceRole b) {
  return (a == SourceRole.platform && b == SourceRole.bank) ||
      (a == SourceRole.bank && b == SourceRole.platform);
}
