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

/// 银行 App 的包名。
///
/// 各家银行的包名不统一，这里只列常见的；
/// 没列到的银行走 [isBankByContent] 的短信通道判断，
/// 认不出来就是 [SourceRole.other]——宁可漏合并，也不误合并。
const Set<String> kBankPackages = <String>{
  'com.icbc', // 中国工商银行
  'com.chinamworld.main', // 中国建设银行
  'com.cmbchina', // 招商银行
  'com.android.bankabc', // 中国农业银行
  'com.bankcomm.Bankcomm', // 交通银行
  'com.cebbank.mobile', // 中国光大银行
  'com.citic', // 中信银行
  'com.hxb', // 华夏银行
  'com.yitong.mbank', // 中国邮政储蓄银行
  'com.pingan.paces.ccms', // 平安银行
  'com.cgsbank', // 广发银行
  'com.cib.bank', // 兴业银行
  'com.bankofshanghai', // 上海银行
  'com.psbc.mobile', // 邮储银行
  'com.spdb', // 浦发银行
  'com.cmbc.guilin', // 桂林银行
  'com.hncb.wy', // 湖南银行
  'com.cdbgzbank', // 广东发展银行
};

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
SourceRole roleOf({String? packageName, required String content}) {
  final pkg = (packageName ?? '').trim().toLowerCase();
  if (pkg.isEmpty) return SourceRole.other;

  if (kPlatformPackages.contains(pkg)) return SourceRole.platform;
  if (kBankPackages.contains(pkg)) return SourceRole.bank;
  if (kSmsPackages.contains(pkg)) {
    return isBankByContent(content) ? SourceRole.bank : SourceRole.other;
  }
  return SourceRole.other;
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
