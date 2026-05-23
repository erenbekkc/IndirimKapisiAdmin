import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class RaporlarScreen extends StatefulWidget {
  const RaporlarScreen({super.key});

  @override
  State<RaporlarScreen> createState() => _RaporlarScreenState();
}

class _RaporlarScreenState extends State<RaporlarScreen> {
  DateTime _startDate = DateTime.now();
  DateTime _endDate = DateTime.now();
  bool _loading = false;
  List<Map<String, dynamic>> _dailyData = [];
  Map<String, int> _citySessionMap = {};
  Map<String, int> _cityUniqueMap = {};
  // key: 'yyyy-MM', value: {'android': int, 'ios': int}
  Map<String, Map<String, int>> _downloadsByMonth = {};

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      final dates = <String>[];
      var d = _startDate;
      while (!d.isAfter(_endDate)) {
        dates.add(_dateStr(d));
        d = d.add(const Duration(days: 1));
      }

      // Aylık şehir sorgusu
      final now = DateTime.now();
      final monthStart = '${now.year}-${now.month.toString().padLeft(2, '0')}-01';
      final monthEnd   = '${now.year}-${now.month.toString().padLeft(2, '0')}-31';

      // Paralel: daily_stats, user-stats (seçili aralık), user-stats (aylık), ilk kurulumlar (tüm zamanlar)
      final results = await Future.wait<dynamic>([
        Future.wait(dates.map((dt) =>
            FirebaseFirestore.instance.collection('daily_stats').doc(dt).get())),
        FirebaseFirestore.instance
            .collection('user-stats')
            .where('sessionDate', isGreaterThanOrEqualTo: dates.first)
            .where('sessionDate', isLessThanOrEqualTo: dates.last)
            .get(),
        FirebaseFirestore.instance
            .collection('user-stats')
            .where('sessionDate', isGreaterThanOrEqualTo: monthStart)
            .where('sessionDate', isLessThanOrEqualTo: monthEnd)
            .get(),
        FirebaseFirestore.instance
            .collection('user-stats')
            .where('isFirstOpen', isEqualTo: true)
            .get(),
      ]);

      final snapshots        = results[0] as List<DocumentSnapshot>;
      final userStatsSnap    = results[1] as QuerySnapshot;
      final monthlyStatsSnap = results[2] as QuerySnapshot;
      final firstOpenSnap    = results[3] as QuerySnapshot;

      // user-stats'ı tarihe göre grupla (seçili aralık)
      final Map<String, List<Map<String, dynamic>>> statsByDate = {};

      for (final doc in userStatsSnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final dateKey = (data['sessionDate'] as String?) ?? '';
        statsByDate.putIfAbsent(dateKey, () => []).add(data);
      }

      // Aylık şehir dağılımı
      final Map<String, int>        citySessionMap = {};
      final Map<String, Set<String>> cityUidSets   = {};

      for (final doc in monthlyStatsSnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final city = (data['city'] as String?) ?? 'Bilinmiyor';
        final uid  = data['uid'] as String?;
        citySessionMap[city] = (citySessionMap[city] ?? 0) + 1;
        if (uid != null) {
          cityUidSets.putIfAbsent(city, () => {}).add(uid);
        }
      }

      final cityUniqueMap = Map.fromEntries(
        cityUidSets.entries.map((e) => MapEntry(e.key, e.value.length)),
      );

      // Tüm zamanlara göre aylık kurulum sayısı
      final Map<String, Map<String, int>> downloadsByMonth = {};
      for (final doc in firstOpenSnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final dateStr = (data['sessionDate'] as String?) ?? '';
        if (dateStr.length < 7) continue;
        final monthKey = dateStr.substring(0, 7); // 'yyyy-MM'
        downloadsByMonth.putIfAbsent(monthKey, () => {'android': 0, 'ios': 0});
        if (data['platform'] == 'ios') {
          downloadsByMonth[monthKey]!['ios'] = downloadsByMonth[monthKey]!['ios']! + 1;
        } else {
          downloadsByMonth[monthKey]!['android'] = downloadsByMonth[monthKey]!['android']! + 1;
        }
      }

      // Günlük satırları oluştur
      final rows = <Map<String, dynamic>>[];
      for (int i = 0; i < dates.length; i++) {
        final data = (snapshots[i].data() as Map<String, dynamic>?) ?? {};
        final androidTokens = (data['androidUniqueUsers'] as List?)?.length ?? 0;
        final iosTokens = (data['iosUniqueUsers'] as List?)?.length ?? 0;

        // user-stats'tan gelen veriler
        final dayStats = statsByDate[dates[i]] ?? [];
        final androidSess = dayStats.where((s) => s['platform'] == 'android').toList();
        final iosSess = dayStats.where((s) => s['platform'] == 'ios').toList();

        int aAds = 0, iAds = 0;
        int aInstalls = 0, iInstalls = 0;

        for (final s in androidSess) {
          aAds += (s['adsWatched'] as int?) ?? 0;
          if (s['isFirstOpen'] == true) aInstalls++;
        }
        for (final s in iosSess) {
          iAds += (s['adsWatched'] as int?) ?? 0;
          if (s['isFirstOpen'] == true) iInstalls++;
        }

        rows.add({
          'date': dates[i],
          'androidOpens': (data['androidOpens'] as num?)?.toInt() ?? 0,
          'iosOpens': (data['iosOpens'] as num?)?.toInt() ?? 0,
          'androidUnique': androidTokens,
          'iosUnique': iosTokens,
          'androidNotifClicks': (data['androidNotifClicks'] as num?)?.toInt() ?? 0,
          'iosNotifClicks': (data['iosNotifClicks'] as num?)?.toInt() ?? 0,
          'notifSent': (data['notifSent'] as num?)?.toInt() ?? 0,
          'androidNotifSent': (data['androidNotifSent'] as num?)?.toInt() ?? 0,
          'iosNotifSent': (data['iosNotifSent'] as num?)?.toInt() ?? 0,
          // Yeni: kurulum (user-stats'tan)
          'androidInstalls': aInstalls,
          'iosInstalls': iInstalls,
          // Yeni: reklam görüntüleme (toplam + oturum başı ortalama)
          'androidAds': aAds,
          'iosAds': iAds,
          'androidAvgAds': (data['androidOpens'] as num?)?.toInt() != null && (data['androidOpens'] as num).toInt() > 0 ? (aAds / (data['androidOpens'] as num).toInt()) : 0.0,
          'iosAvgAds': (data['iosOpens'] as num?)?.toInt() != null && (data['iosOpens'] as num).toInt() > 0 ? (iAds / (data['iosOpens'] as num).toInt()) : 0.0,
        });
      }

      setState(() {
        _dailyData = rows;
        _citySessionMap = citySessionMap;
        _cityUniqueMap  = cityUniqueMap;
        _downloadsByMonth = downloadsByMonth;
        _loading = false;
      });
    } catch (e) {
      setState(() => _loading = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Hata: $e')),
        );
      }
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(2025),
      lastDate: DateTime.now(),
      initialDateRange: DateTimeRange(start: _startDate, end: _endDate),
      locale: const Locale('tr', 'TR'),
    );
    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
      _loadData();
    }
  }

  bool _isRowEmpty(Map<String, dynamic> r) =>
      r['androidOpens'] == 0 &&
      r['iosOpens'] == 0 &&
      r['notifSent'] == 0 &&
      r['androidNotifSent'] == 0 &&
      r['iosNotifSent'] == 0 &&
      r['androidUnique'] == 0 &&
      r['iosUnique'] == 0 &&
      r['androidInstalls'] == 0 &&
      r['iosInstalls'] == 0;

  @override
  Widget build(BuildContext context) {
    final df = DateFormat('d MMM', 'tr_TR');
    return _loading
        ? const Center(child: CircularProgressIndicator())
        : RefreshIndicator(
            onRefresh: _loadData,
            child: SingleChildScrollView(
              physics: const AlwaysScrollableScrollPhysics(),
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Tarih aralığı seçici
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.date_range, size: 18),
                          label: Text(
                            '${df.format(_startDate)} – ${df.format(_endDate)}',
                            style: const TextStyle(fontWeight: FontWeight.w600),
                          ),
                          onPressed: _pickDateRange,
                        ),
                      ),
                      const SizedBox(width: 8),
                      IconButton(
                        icon: const Icon(Icons.refresh),
                        onPressed: _loadData,
                        tooltip: 'Yenile',
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),

                  // Günlük istatistikler
                  _sectionHeader('Günlük İstatistikler'),
                  const SizedBox(height: 8),
                  if (_dailyData.every(_isRowEmpty))
                    const Padding(
                      padding: EdgeInsets.only(top: 8),
                      child: Text(
                        'Seçilen tarih aralığında veri yok.',
                        style: TextStyle(color: Colors.grey),
                      ),
                    )
                  else
                    ..._dailyData.reversed.map((row) => _dayCard(row, df)),

                  // Şehir dağılımı — Oturum
                  if (_citySessionMap.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _sectionHeader('Şehir Dağılımı — Oturum Sayısı (${_monthLabel()})'),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: _buildCitySection(_citySessionMap),
                      ),
                    ),
                  ],
                  // Şehir dağılımı — Tekil Kullanıcı
                  if (_cityUniqueMap.isNotEmpty) ...[
                    const SizedBox(height: 16),
                    _sectionHeader('Şehir Dağılımı — Tekil Kullanıcı (${_monthLabel()})'),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: _buildCitySection(_cityUniqueMap),
                      ),
                    ),
                  ],

                  // Aylık ilk kurulum — tüm aylar
                  if (_downloadsByMonth.isNotEmpty) ...[
                    const SizedBox(height: 20),
                    _sectionHeader('İlk Kurulum — Aylık'),
                    const SizedBox(height: 8),
                    Card(
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          children: (_downloadsByMonth.entries.toList()
                                ..sort((a, b) => b.key.compareTo(a.key)))
                              .map((e) {
                            final android = e.value['android'] ?? 0;
                            final ios = e.value['ios'] ?? 0;
                            final parts = e.key.split('-');
                            final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]));
                            final label = DateFormat('MMMM yyyy', 'tr_TR').format(dt);
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 8),
                              child: _statRow(
                                label: label,
                                total: android + ios,
                                android: android,
                                ios: ios,
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
  }

  Widget _sectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w700,
        color: Color(0xFF2563EB),
      ),
    );
  }

  Widget _dayCard(Map<String, dynamic> row, DateFormat df) {
    final parts = (row['date'] as String).split('-');
    final dt = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));

    final androidOpens = row['androidOpens'] as int;
    final iosOpens = row['iosOpens'] as int;
    final androidUnique = row['androidUnique'] as int;
    final iosUnique = row['iosUnique'] as int;
    final androidClicks = row['androidNotifClicks'] as int;
    final iosClicks = row['iosNotifClicks'] as int;
    final notifSent = row['notifSent'] as int;
    final androidSent = row['androidNotifSent'] as int;
    final iosSent = row['iosNotifSent'] as int;
    final androidInstalls = row['androidInstalls'] as int;
    final iosInstalls = row['iosInstalls'] as int;
    final androidAds = row['androidAds'] as int;
    final iosAds = row['iosAds'] as int;
    final androidAvgAds = (row['androidAvgAds'] as num?)?.toDouble() ?? 0.0;
    final iosAvgAds = (row['iosAvgAds'] as num?)?.toDouble() ?? 0.0;

    if (_isRowEmpty(row)) return const SizedBox.shrink();

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              df.format(dt),
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
            const Divider(height: 12),
            if (androidInstalls > 0 || iosInstalls > 0) ...[
              _statRow(
                label: 'Kurulum',
                total: androidInstalls + iosInstalls,
                android: androidInstalls,
                ios: iosInstalls,
              ),
              const SizedBox(height: 4),
            ],
            _statRow(
              label: 'Tekil Kullanıcı',
              total: androidUnique + iosUnique,
              android: androidUnique,
              ios: iosUnique,
            ),
            const SizedBox(height: 4),
            _statRow(
              label: 'Toplam Açılma',
              total: androidOpens + iosOpens,
              android: androidOpens,
              ios: iosOpens,
            ),
            const SizedBox(height: 4),
            _statRow(
              label: 'Bildirim Gönderim',
              total: notifSent > 0 ? notifSent : androidSent + iosSent,
              android: androidSent,
              ios: iosSent,
            ),
            const SizedBox(height: 4),
            _statRow(
              label: 'Bildirim Tıklama',
              total: androidClicks + iosClicks,
              android: androidClicks,
              ios: iosClicks,
            ),
            if (androidAds > 0 || iosAds > 0) ...[
              const SizedBox(height: 4),
              _statRow(
                label: 'Reklam Görüntüleme',
                total: androidAds + iosAds,
                android: androidAds,
                ios: iosAds,
              ),
              const SizedBox(height: 4),
              _durationRow(
                label: 'Ort. Reklam/Oturum',
                androidSecs: 0,
                iosSecs: 0,
                androidText: androidAvgAds > 0 ? androidAvgAds.toStringAsFixed(1) : '-',
                iosText: iosAvgAds > 0 ? iosAvgAds.toStringAsFixed(1) : '-',
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _statRow({
    required String label,
    required int total,
    required int android,
    required int ios,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.black87)),
        ),
        _chip('Toplam', total, Colors.blueGrey.shade600),
        const SizedBox(width: 4),
        _chip('Android', android, Colors.green.shade700),
        const SizedBox(width: 4),
        _chip('iOS', ios, Colors.blue.shade700),
      ],
    );
  }

  Widget _durationRow({
    required String label,
    required int androidSecs,
    required int iosSecs,
    String? androidText,
    String? iosText,
  }) {
    return Row(
      children: [
        Expanded(
          child: Text(label,
              style: const TextStyle(fontSize: 12, color: Colors.black87)),
        ),
        _chipText('Android', androidText ?? _formatDur(androidSecs), Colors.green.shade700),
        const SizedBox(width: 4),
        _chipText('iOS', iosText ?? _formatDur(iosSecs), Colors.blue.shade700),
      ],
    );
  }

  String _monthLabel() =>
      DateFormat('MMMM yyyy', 'tr_TR').format(DateTime.now());

  Widget _buildCitySection(Map<String, int> cityMap) {
    final total = cityMap.values.fold(0, (a, b) => a + b);
    final sorted = cityMap.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return Column(
      children: sorted.take(15).map((e) {
        final pct = total > 0 ? e.value / total : 0.0;
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            children: [
              const Icon(Icons.location_on, size: 13, color: Colors.grey),
              const SizedBox(width: 4),
              Expanded(
                child: Text(e.key, style: const TextStyle(fontSize: 12)),
              ),
              Text('${e.value}',
                  style: const TextStyle(
                      fontSize: 12, fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              SizedBox(
                width: 70,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(3),
                  child: LinearProgressIndicator(
                    value: pct,
                    backgroundColor: Colors.grey.shade200,
                    valueColor:
                        const AlwaysStoppedAnimation(Color(0xFF2563EB)),
                    minHeight: 5,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );
  }

  Widget _chip(String label, int value, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Widget _chipText(String label, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        '$label: $text',
        style: TextStyle(
            fontSize: 11, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  String _formatDur(int secs) {
    if (secs <= 0) return '-';
    if (secs < 60) return '${secs}sn';
    final m = secs ~/ 60;
    final s = secs % 60;
    return s > 0 ? '${m}dk ${s}sn' : '${m}dk';
  }
}
