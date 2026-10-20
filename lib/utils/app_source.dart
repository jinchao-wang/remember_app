/// 把各种「来源」写法归一到同一个钱包标识。
///
/// 通知自动记账落库的 sourceApp 是应用包名（com.tencent.mm），
/// 账单导入落库的是「微信」。判重时两边必须能对上，
/// 否则同一笔消费会被当成两笔分别记下来。
String? canonicalSource(String? raw) {
  if (raw == null) return null;
  final v = raw.trim().toLowerCase();
  if (v.isEmpty) return null;

  const aliases = <String, String>{
    'com.tencent.mm': '微信',
    '微信': '微信',
    '微信支付': '微信',
    'wechat': '微信',
    'com.eg.android.alipaygphone': '支付宝',
    '支付宝': '支付宝',
    'alipay': '支付宝',
  };
  return aliases[v] ?? v;
}
