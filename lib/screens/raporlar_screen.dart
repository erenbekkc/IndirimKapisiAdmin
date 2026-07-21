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

  // Aylık şehir dağılımı: key = "YYYY-MM"
  Map<String, Map<String, int>> _monthlySessionMaps = {};
  Map<String, Map<String, int>> _monthlyUniqueMaps  = {};
  Map<String, int> _monthlySessionPages = {};
  Map<String, int> _monthlyUniquePages  = {};

  // Aylık toplam reklam görüntüleme: key = "YYYY-MM"
  Map<String, int> _monthlyAdCounts = {};

  // Firestore config/regions'tan yüklenir
  Map<String, String> _ilceToIl = {};
  Map<String, String> _cityNormalize = {};

  // Bugün ilk kez görülen şehirler (yeşil şehir adı)
  Set<String> _newCitiesToday     = {};
  // Bugün yeni tekil kullanıcı kazanılan şehirler (tekil tabloda yeşil sayı)
  Set<String> _newUniqueUserCities = {};

  static const int _cityPageSize = 10;

  // İlk raporlama ayı
  static const int _firstYear  = 2026;
  static const int _firstMonth = 6; // Haziran

  static const List<String> _monthNames = [
    '', 'Ocak', 'Şubat', 'Mart', 'Nisan', 'Mayıs', 'Haziran',
    'Temmuz', 'Ağustos', 'Eylül', 'Ekim', 'Kasım', 'Aralık',
  ];

  @override
  void initState() {
    super.initState();
    _loadData();
  }

  String _dateStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  /// Başlangıç ayından bugünün ayına kadar tüm ay anahtarlarını döner.
  List<String> _monthKeys() {
    final today = DateTime.now();
    final keys  = <String>[];
    var year  = _firstYear;
    var month = _firstMonth;
    while (year < today.year || (year == today.year && month <= today.month)) {
      keys.add('$year-${month.toString().padLeft(2, '0')}');
      month++;
      if (month > 12) { month = 1; year++; }
    }
    return keys;
  }

  // Ham city değerini normalize et: ilçe → il, yazım → standart
  String _normalizeCity(String raw) {
    final normalized = _cityNormalize[raw] ?? raw;
    return _ilceToIl[normalized] ?? normalized;
  }

  Future<void> _loadData() async {
    setState(() => _loading = true);
    try {
      // Bölge haritasını yükle (yoksa sessizce devam et)
      try {
        final regDoc = await FirebaseFirestore.instance
            .collection('config').doc('regions').get();
        final rd = regDoc.data();
        if (rd != null) {
          final ilce = rd['ilceToIl'] as Map<String, dynamic>?;
          if (ilce != null) {
            _ilceToIl = ilce.map((k, v) => MapEntry(k, v as String));
          }
          final norm = rd['cityNormalize'] as Map<String, dynamic>?;
          if (norm != null) {
            _cityNormalize = norm.map((k, v) => MapEntry(k, v as String));
          }
        }
      } catch (_) {}

      final today        = DateTime.now();
      final todayStr     = _dateStr(today);
      final yesterday    = today.subtract(const Duration(days: 1));
      final yesterdayStr = _dateStr(yesterday);

      final dates = <String>[];
      var d = _startDate;
      while (!d.isAfter(_endDate)) {
        dates.add(_dateStr(d));
        d = d.add(const Duration(days: 1));
      }

      final monthKeys = _monthKeys();

      // Aylık şehir sorguları: mevcut ay için dünü bitiş olarak al
      // (bugünün verisi ayrı sorgulanıp "yeni şehir/kullanıcı" tespiti için kullanılır)
      final monthFutures = monthKeys.map((key) {
        final parts = key.split('-');
        final y = int.parse(parts[0]);
        final m = int.parse(parts[1]);
        final start = '$key-01';
        final String end;
        if (y == today.year && m == today.month) {
          end = yesterdayStr; // bugün hariç
        } else {
          final lastDay = DateTime(y, m + 1, 0).day;
          end = '$key-${lastDay.toString().padLeft(2, '0')}';
        }
        return FirebaseFirestore.instance
            .collection('user-stats')
            .where('sessionDate', isGreaterThanOrEqualTo: start)
            .where('sessionDate', isLessThanOrEqualTo: end)
            .get();
      }).toList();

      // Bugüne ait user-stats (yeni şehir/kullanıcı tespiti + mevcut ay görünümüne ekleme)
      final todayStatsFuture = FirebaseFirestore.instance
          .collection('user-stats')
          .where('sessionDate', isEqualTo: todayStr)
          .get();

      // notification-messages: tüm aralık için tek sorguda çek, günlük grupla
      final rangeStart = DateTime(_startDate.year, _startDate.month, _startDate.day);
      final rangeEnd   = DateTime(_endDate.year,   _endDate.month,   _endDate.day + 1);
      final notifMsgFuture = FirebaseFirestore.instance
          .collection('notification-messages')
          .where('sentAt', isGreaterThanOrEqualTo: Timestamp.fromDate(rangeStart))
          .where('sentAt', isLessThan:             Timestamp.fromDate(rangeEnd))
          .get();

      final results = await Future.wait<dynamic>([
        Future.wait(dates.map((dt) =>
            FirebaseFirestore.instance.collection('daily_stats').doc(dt).get())),
        FirebaseFirestore.instance
            .collection('user-stats')
            .where('sessionDate', isGreaterThanOrEqualTo: dates.first)
            .where('sessionDate', isLessThanOrEqualTo: dates.last)
            .get(),
        notifMsgFuture,
        todayStatsFuture,   // results[3]
        ...monthFutures,    // results[4+i]
      ]);

      final snapshots      = results[0] as List<DocumentSnapshot>;
      final userStatsSnap  = results[1] as QuerySnapshot;
      final notifMsgSnap   = results[2] as QuerySnapshot;

      // notification-messages → günlük platform bazında say (kümülatif)
      final Map<String, int> notifAndroidByDate = {};
      final Map<String, int> notifIosByDate     = {};
      for (final doc in notifMsgSnap.docs) {
        final data     = doc.data() as Map<String, dynamic>;
        final sentAt   = (data['sentAt'] as Timestamp).toDate().toLocal();
        final dateKey  = _dateStr(sentAt);
        final platform = (data['platform'] as String?) ?? 'android';
        if (platform == 'ios') {
          notifIosByDate[dateKey] = (notifIosByDate[dateKey] ?? 0) + 1;
        } else {
          notifAndroidByDate[dateKey] = (notifAndroidByDate[dateKey] ?? 0) + 1;
        }
      }

      // Günlük satırlar için user-stats'ı tarihe göre grupla
      final Map<String, List<Map<String, dynamic>>> statsByDate = {};
      for (final doc in userStatsSnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final dateKey = (data['sessionDate'] as String?) ?? '';
        statsByDate.putIfAbsent(dateKey, () => []).add(data);
      }

      // Aylık şehir dağılımlarını işle (mevcut ay = dünkü verilere kadar)
      final newSessionMaps      = <String, Map<String, int>>{};
      final newUniqueMaps       = <String, Map<String, int>>{};
      final newAdCounts         = <String, int>{};
      final monthlyUidSets      = <String, Map<String, Set<String>>>{}; // birleştirme için
      final historicalCities    = <String>{};
      final historicalUidsByCity = <String, Set<String>>{};

      for (int i = 0; i < monthKeys.length; i++) {
        final snap = results[4 + i] as QuerySnapshot;
        final citySessionMap = <String, int>{};
        final cityUidSets   = <String, Set<String>>{};
        int monthAds = 0;
        for (final doc in snap.docs) {
          final data = doc.data() as Map<String, dynamic>;
          final city = _normalizeCity((data['city'] as String?) ?? 'Bilinmiyor');
          final uid  = data['uid'] as String?;
          citySessionMap[city] = (citySessionMap[city] ?? 0) + 1;
          monthAds += (data['adsWatched'] as num?)?.toInt() ?? 0;
          historicalCities.add(city);
          if (uid != null) {
            cityUidSets.putIfAbsent(city, () => {}).add(uid);
            historicalUidsByCity.putIfAbsent(city, () => {}).add(uid);
          }
        }
        newSessionMaps[monthKeys[i]] = citySessionMap;
        newUniqueMaps[monthKeys[i]]  = Map.fromEntries(
          cityUidSets.entries.map((e) => MapEntry(e.key, e.value.length)),
        );
        newAdCounts[monthKeys[i]]  = monthAds;
        monthlyUidSets[monthKeys[i]] = cityUidSets;
      }

      // Bugünün verilerini işle
      final todaySnap         = results[3] as QuerySnapshot;
      final todayCitySession  = <String, int>{};
      final todayCityUidSets  = <String, Set<String>>{};
      int todayAds = 0;
      for (final doc in todaySnap.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final city = (data['city'] as String?) ?? 'Bilinmiyor';
        final uid  = data['uid'] as String?;
        todayCitySession[city] = (todayCitySession[city] ?? 0) + 1;
        todayAds += (data['adsWatched'] as num?)?.toInt() ?? 0;
        if (uid != null) {
          todayCityUidSets.putIfAbsent(city, () => {}).add(uid);
        }
      }

      // Yeni şehir tespiti: bugün var, tarihsel veride yok
      final newCitiesToday = todayCitySession.keys.toSet().difference(historicalCities);

      // Yeni tekil kullanıcı tespiti: bugünkü UID daha önce hiç görülmemiş
      final newUniqueUserCities = <String>{};
      for (final entry in todayCityUidSets.entries) {
        final histUids = historicalUidsByCity[entry.key] ?? {};
        if (entry.value.difference(histUids).isNotEmpty) {
          newUniqueUserCities.add(entry.key);
        }
      }

      // Bugünün verilerini mevcut ay görünümüne ekle
      final currentMonthKey = '${today.year}-${today.month.toString().padLeft(2, '0')}';
      final curSession = Map<String, int>.from(newSessionMaps[currentMonthKey] ?? {});
      for (final e in todayCitySession.entries) {
        curSession[e.key] = (curSession[e.key] ?? 0) + e.value;
      }
      newSessionMaps[currentMonthKey] = curSession;

      final curUidSets = Map<String, Set<String>>.from(monthlyUidSets[currentMonthKey] ?? {});
      for (final e in todayCityUidSets.entries) {
        curUidSets.putIfAbsent(e.key, () => {}).addAll(e.value);
      }
      newUniqueMaps[currentMonthKey] = Map.fromEntries(
        curUidSets.entries.map((e) => MapEntry(e.key, e.value.length)),
      );
      newAdCounts[currentMonthKey] = (newAdCounts[currentMonthKey] ?? 0) + todayAds;

      // Günlük satırları oluştur
      final rows = <Map<String, dynamic>>[];
      for (int i = 0; i < dates.length; i++) {
        final data = (snapshots[i].data() as Map<String, dynamic>?) ?? {};

        final dayStats    = statsByDate[dates[i]] ?? [];
        final androidSess = dayStats.where((s) => s['platform'] == 'android').toList();
        final iosSess     = dayStats.where((s) => s['platform'] == 'ios').toList();

        final androidOpens = androidSess.length;
        final iosOpens     = iosSess.length;

        final androidUids = androidSess
            .map((s) => s['uid'] as String?)
            .whereType<String>()
            .toSet()
            .length;
        final iosUids = iosSess
            .map((s) => s['uid'] as String?)
            .whereType<String>()
            .toSet()
            .length;

        int aAds = 0, iAds = 0;
        for (final s in androidSess) aAds += (s['adsWatched'] as int?) ?? 0;
        for (final s in iosSess)     iAds += (s['adsWatched'] as int?) ?? 0;

        // Bildirim gönderim: notification-messages koleksiyonundan kümülatif
        final androidSent = notifAndroidByDate[dates[i]] ?? 0;
        final iosSent     = notifIosByDate[dates[i]]     ?? 0;
        final notifSent   = androidSent + iosSent;

        rows.add({
          'date': dates[i],
          'androidOpens': androidOpens,
          'iosOpens': iosOpens,
          'androidUnique': androidUids,
          'iosUnique': iosUids,
          'androidNotifClicks': (data['androidNotifClicks'] as num?)?.toInt() ?? 0,
          'iosNotifClicks': (data['iosNotifClicks'] as num?)?.toInt() ?? 0,
          'notifSent': notifSent,
          'androidNotifSent': androidSent,
          'iosNotifSent': iosSent,
          'androidAds': aAds,
          'iosAds': iAds,
          'androidAvgAds': androidOpens > 0 ? aAds / androidOpens : 0.0,
          'iosAvgAds': iosOpens > 0 ? iAds / iosOpens : 0.0,
        });
      }

      setState(() {
        _dailyData             = rows;
        _monthlySessionMaps    = newSessionMaps;
        _monthlyUniqueMaps     = newUniqueMaps;
        _monthlyAdCounts       = newAdCounts;
        _monthlySessionPages   = {};
        _monthlyUniquePages    = {};
        _newCitiesToday        = newCitiesToday;
        _newUniqueUserCities   = newUniqueUserCities;
        _loading               = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hata: $e'), duration: const Duration(seconds: 6)),
      );
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
        _endDate   = picked.end;
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
      r['iosUnique'] == 0;

  String _monthLabel(String key) {
    final parts = key.split('-');
    final y     = int.parse(parts[0]);
    final m     = int.parse(parts[1]);
    return '${_monthNames[m]} $y';
  }

  @override
  Widget build(BuildContext context) {
    final df             = DateFormat('d MMM', 'tr_TR');
    final monthKeys      = _monthKeys();
    final now            = DateTime.now();
    final currentMonthKey = '${now.year}-${now.month.toString().padLeft(2, '0')}';

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

                  // Aylık şehir dağılımları (en yeniden en eskiye)
                  ...monthKeys.reversed.expand((key) {
                    final sessionMap = _monthlySessionMaps[key] ?? {};
                    final uniqueMap  = _monthlyUniqueMaps[key]  ?? {};
                    final label      = _monthLabel(key);
                    if (sessionMap.isEmpty && uniqueMap.isEmpty) return <Widget>[];
                    return [
                      const SizedBox(height: 28),
                      // Ana ay başlığı
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E40AF),
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text(
                          label,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: 0.3,
                          ),
                        ),
                      ),
                      if (uniqueMap.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        _sectionHeader('Şehir Dağılımı — Tekil Kullanıcı'),
                        const SizedBox(height: 8),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: _buildCitySection(
                              uniqueMap,
                              _monthlyUniquePages[key] ?? 0,
                              (p) => setState(() => _monthlyUniquePages[key] = p),
                              newCities:      key == currentMonthKey ? _newCitiesToday      : const {},
                              newCountCities: key == currentMonthKey ? _newUniqueUserCities : const {},
                            ),
                          ),
                        ),
                      ],
                      if (sessionMap.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        _sectionHeader('Şehir Dağılımı — Oturum Sayısı'),
                        const SizedBox(height: 8),
                        Card(
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: _buildCitySection(
                              sessionMap,
                              _monthlySessionPages[key] ?? 0,
                              (p) => setState(() => _monthlySessionPages[key] = p),
                            ),
                          ),
                        ),
                      ],
                      // Aylık toplam reklam görüntüleme
                      Builder(builder: (_) {
                        final adCount = _monthlyAdCounts[key] ?? 0;
                        if (adCount == 0) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(top: 16),
                          child: Card(
                            color: Colors.orange.shade50,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(color: Colors.orange.shade200),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                              child: Row(
                                children: [
                                  Icon(Icons.play_circle_outline,
                                      color: Colors.orange.shade700, size: 20),
                                  const SizedBox(width: 10),
                                  const Expanded(
                                    child: Text(
                                      'Toplam Reklam Görüntüleme',
                                      style: TextStyle(
                                          fontSize: 13, fontWeight: FontWeight.w600),
                                    ),
                                  ),
                                  Text(
                                    adCount.toString(),
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      color: Colors.orange.shade800,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      }),
                    ];
                  }),
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
    final dt    = DateTime(int.parse(parts[0]), int.parse(parts[1]), int.parse(parts[2]));

    final androidOpens  = row['androidOpens']  as int;
    final iosOpens      = row['iosOpens']       as int;
    final androidUnique = row['androidUnique']  as int;
    final iosUnique     = row['iosUnique']      as int;
    final androidClicks = row['androidNotifClicks'] as int;
    final iosClicks     = row['iosNotifClicks']     as int;
    final notifSent     = row['notifSent']          as int;
    final androidSent   = row['androidNotifSent']   as int;
    final iosSent       = row['iosNotifSent']        as int;
    final androidAds    = row['androidAds']          as int;
    final iosAds        = row['iosAds']              as int;
    final androidAvgAds = (row['androidAvgAds'] as num?)?.toDouble() ?? 0.0;
    final iosAvgAds     = (row['iosAvgAds']     as num?)?.toDouble() ?? 0.0;

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

  Widget _buildCitySection(
    Map<String, int> cityMap,
    int page,
    void Function(int) onPageChange, {
    Set<String> newCities     = const {},
    Set<String> newCountCities = const {},
  }) {
    final grandTotal = cityMap.values.fold(0, (a, b) => a + b);
    final sorted     = cityMap.entries.toList()
      ..sort((a, b) => b.value != a.value
          ? b.value.compareTo(a.value)
          : a.key.compareTo(b.key));
    final totalPages = (sorted.length / _cityPageSize).ceil();
    final start      = page * _cityPageSize;
    final end        = (start + _cityPageSize).clamp(0, sorted.length);
    final pageItems  = sorted.sublist(start, end);

    return Column(
      children: [
        ...pageItems.map((e) {
          final pct        = grandTotal > 0 ? e.value / grandTotal : 0.0;
          final isNewCity  = newCities.contains(e.key);
          final isNewCount = newCountCities.contains(e.key);
          return Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Row(
              children: [
                Icon(Icons.location_on, size: 13,
                    color: isNewCity ? Colors.green.shade600 : Colors.grey),
                const SizedBox(width: 4),
                Expanded(
                  child: Text(e.key,
                      style: TextStyle(
                          fontSize: 12,
                          color: isNewCity ? Colors.green.shade700 : null,
                          fontWeight: isNewCity ? FontWeight.w600 : FontWeight.normal)),
                ),
                Text('${e.value}',
                    style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: isNewCount ? Colors.green.shade700 : null)),
                const SizedBox(width: 8),
                SizedBox(
                  width: 70,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(3),
                    child: LinearProgressIndicator(
                      value: pct,
                      backgroundColor: Colors.grey.shade200,
                      valueColor: const AlwaysStoppedAnimation(Color(0xFF2563EB)),
                      minHeight: 5,
                    ),
                  ),
                ),
              ],
            ),
          );
        }),
        if (totalPages > 1) ...[
          const SizedBox(height: 8),
          Wrap(
            alignment: WrapAlignment.center,
            spacing: 4,
            children: List.generate(totalPages, (i) {
              final selected = i == page;
              return GestureDetector(
                onTap: () => onPageChange(i),
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected
                        ? const Color(0xFF2563EB)
                        : Colors.grey.shade200,
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Text(
                    '${i + 1}',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: selected ? Colors.white : Colors.black87,
                    ),
                  ),
                ),
              );
            }),
          ),
        ],
        const Divider(height: 16),
        Row(
          children: [
            const Expanded(
              child: Text('Toplam',
                  style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: Color(0xFF2563EB))),
            ),
            Text('$grandTotal',
                style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF2563EB))),
            const SizedBox(width: 78),
          ],
        ),
      ],
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
