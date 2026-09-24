import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:hanabi_download_manager_x/services/geo_ip_service.dart';

/// 离线归属地资源包的解析与导入校验。
///
/// 这些用例覆盖的是用户手里**真实会有**的文件格式：内置源被墙时，
/// 用户只能自己下载再导入，而他下到的可能是 ip-location-db 的点分 CSV、
/// IP2Location LITE 的十进制带引号 CSV，或者两者的 .gz。
void main() {
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('geo_pack_test');
  });

  tearDown(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  String write(String name, String content) {
    final f = File('${tmp.path}${Platform.pathSeparator}$name');
    f.writeAsStringSync(content);
    return f.path;
  }

  String writeGz(String name, String content) {
    final f = File('${tmp.path}${Platform.pathSeparator}$name');
    f.writeAsBytesSync(gzip.encode(utf8.encode(content)));
    return f.path;
  }

  ({Uint32List starts, Uint32List ends, Uint16List codes}) parse(String path) {
    final raw = parseGeoV4Csv(path);
    return (
      starts: raw[0] as Uint32List,
      ends: raw[1] as Uint32List,
      codes: raw[2] as Uint16List,
    );
  }

  String? lookup(String path, String ip) {
    final r = parse(path);
    final table = GeoV4Table(starts: r.starts, ends: r.ends, codes: r.codes);
    final value = GeoIpService.ipv4ToInt(ip);
    return value == null ? null : table.lookup(value);
  }

  // ip-location-db：内置源用的格式，点分区间，无表头，无引号。
  const dotted = '''
1.0.0.0,1.0.0.255,AU
1.0.1.0,1.0.3.255,CN
1.0.4.0,1.0.7.255,AU
1.0.16.0,1.0.31.255,JP
8.8.8.0,8.8.8.255,US
''';

  // IP2Location LITE DB1：十进制区间，每个字段都带双引号，还多一列国家全名。
  const decimalQuoted = '''
"16777216","16777471","AU","Australia"
"16777472","16778239","CN","China"
"16778240","16779263","AU","Australia"
"134744064","134744319","US","United States of America"
''';

  group('格式识别', () {
    test('ip-location-db 点分格式', () {
      final path = write('dotted.csv', dotted);
      expect(parse(path).starts.length, 5);
      expect(lookup(path, '1.0.1.5'), 'CN');
      expect(lookup(path, '1.0.16.5'), 'JP');
      expect(lookup(path, '8.8.8.8'), 'US');
    });

    test('IP2Location LITE 十进制带引号格式', () {
      final path = write('lite.csv', decimalQuoted);
      expect(parse(path).starts.length, 4);
      // 16777216 == 1.0.0.0，16777472 == 1.0.1.0
      expect(lookup(path, '1.0.0.10'), 'AU');
      expect(lookup(path, '1.0.1.10'), 'CN');
      expect(lookup(path, '8.8.8.8'), 'US');
    });

    test('gzip 压缩包（靠魔数识别，不看扩展名）', () {
      final path = writeGz('pack.bin', dotted); // 故意不用 .gz 扩展名
      expect(parse(path).starts.length, 5);
      expect(lookup(path, '1.0.1.5'), 'CN');
    });
  });

  group('健壮性', () {
    test('跳过 IPv6 行、注释行与空行', () {
      final path = write('mixed.csv', '''
# comment
2001:200::,2001:200:ffff:ffff:ffff:ffff:ffff:ffff,JP

1.0.1.0,1.0.3.255,CN
''');
      expect(parse(path).starts.length, 1);
      expect(lookup(path, '1.0.1.5'), 'CN');
    });

    test('丢弃畸形行而不是整包失败', () {
      final path = write('broken.csv', '''
not,a,valid,row
1.0.1.0,1.0.3.255,CN
999.999.999.999,1.2.3.4,XX
1.0.1.0
8.8.8.0,8.8.8.255,US
''');
      final r = parse(path);
      expect(r.starts.length, 2);
      expect(lookup(path, '8.8.8.8'), 'US');
    });

    test('区间倒置的行被丢弃', () {
      final path = write('reversed.csv', '8.8.8.255,8.8.8.0,US\n');
      expect(parse(path).starts.isEmpty, isTrue);
    });

    test('乱序输入会被排序，二分查找仍然正确', () {
      final path = write('unsorted.csv', '''
8.8.8.0,8.8.8.255,US
1.0.1.0,1.0.3.255,CN
1.0.16.0,1.0.31.255,JP
''');
      final r = parse(path);
      for (var i = 1; i < r.starts.length; i++) {
        expect(r.starts[i] >= r.starts[i - 1], isTrue,
            reason: '解析结果必须按起始地址升序，否则二分查找失效');
      }
      expect(lookup(path, '1.0.16.5'), 'JP');
      expect(lookup(path, '8.8.8.8'), 'US');
    });

    test('区间之外的地址返回 null，而不是错配到相邻区间', () {
      final path =
          write('gap.csv', '1.0.1.0,1.0.3.255,CN\n8.8.8.0,8.8.8.255,US\n');
      expect(lookup(path, '5.5.5.5'), isNull);
      expect(lookup(path, '1.0.4.0'), isNull);
      expect(lookup(path, '0.0.0.1'), isNull);
    });
  });

  group('字段切分', () {
    test('剥离引号并只取前三列', () {
      expect(splitGeoPackFields('"1","2","AU","Australia"', 3),
          <String>['1', '2', 'AU']);
      expect(splitGeoPackFields('1.0.0.0,1.0.0.255,AU', 3),
          <String>['1.0.0.0', '1.0.0.255', 'AU']);
    });
  });

  group('地址端点解析', () {
    test('点分与十进制两种写法等价', () {
      expect(parseGeoPackAddress('1.0.0.0'), 16777216);
      expect(parseGeoPackAddress('16777216'), 16777216);
      expect(parseGeoPackAddress('"16777216"'.replaceAll('"', '')), 16777216);
    });

    test('越界与垃圾输入返回 null', () {
      expect(parseGeoPackAddress('4294967296'), isNull); // 2^32
      expect(parseGeoPackAddress('-1'), isNull);
      expect(parseGeoPackAddress('abc'), isNull);
      expect(parseGeoPackAddress(''), isNull);
    });
  });
}
