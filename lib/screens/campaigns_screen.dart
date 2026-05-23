import 'dart:async';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';
import 'add_campaign_screen.dart';

enum CampaignFilter { active, upcoming, expired }

class CampaignsScreen extends StatefulWidget {
  const CampaignsScreen({super.key});

  @override
  State<CampaignsScreen> createState() => _CampaignsScreenState();
}

class _CampaignsScreenState extends State<CampaignsScreen> {
  CampaignFilter _filter = CampaignFilter.active;
  String? _selectedMarketId;
  String? _selectedCategoryId;
  final Map<String, String> _categoryIconMap = {};
  final Map<String, String> _marketIconMap = {};
  StreamSubscription<QuerySnapshot>? _categorySub;
  StreamSubscription<QuerySnapshot>? _marketSub;

  @override
  void initState() {
    super.initState();
    _categorySub = FirebaseFirestore.instance
        .collection('categories')
        .snapshots()
        .listen((snapshot) {
      final map = <String, String>{};
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final iconUrl = data['iconUrl'] as String?;
        if (iconUrl != null && iconUrl.isNotEmpty) {
          map[doc.id] = iconUrl;
        }
      }
      if (mounted) setState(() => _categoryIconMap
        ..clear()
        ..addAll(map));
    });
    _marketSub = FirebaseFirestore.instance
        .collection('markets')
        .snapshots()
        .listen((snapshot) {
      final map = <String, String>{};
      for (final doc in snapshot.docs) {
        final data = doc.data() as Map<String, dynamic>;
        final logoUrl = data['logoUrl'] as String?;
        if (logoUrl != null && logoUrl.isNotEmpty) {
          map[doc.id] = logoUrl;
        }
      }
      if (mounted) setState(() => _marketIconMap
        ..clear()
        ..addAll(map));
    });
  }

  @override
  void dispose() {
    _categorySub?.cancel();
    _marketSub?.cancel();
    super.dispose();
  }

  void _delete(DocumentSnapshot doc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Kampanyayı Sil'),
        content: Text('"${doc.get('title')}" silinsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              await doc.reference.delete();
            },
            child: const Text('Sil'),
          ),
        ],
      ),
    );
  }

  void _deleteAll(List<DocumentSnapshot> docs) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tümünü Sil'),
        content: Text('Süresi dolan ${docs.length} kampanya silinsin mi? Bu işlem geri alınamaz.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              final batch = FirebaseFirestore.instance.batch();
              for (final doc in docs) {
                batch.delete(doc.reference);
              }
              await batch.commit();
            },
            child: const Text('Tümünü Sil'),
          ),
        ],
      ),
    );
  }

  Widget _buildCampaignCard(DocumentSnapshot doc) {
    final data = doc.data() as Map<String, dynamic>;
    final dateFormat = DateFormat('dd MMM', 'tr_TR');
    final priceFormat = NumberFormat('#,##0.00', 'tr_TR');
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final startDate = (data['startDate'] as Timestamp?)?.toDate();
    final endDate = (data['endDate'] as Timestamp?)?.toDate();
    final endDay = endDate != null ? DateTime(endDate.year, endDate.month, endDate.day) : null;
    final isExpired = endDay != null && endDay.isBefore(today);
    final isUpcoming = startDate != null && startDate.isAfter(now);

    Color badgeColor;
    String badgeText;
    if (isExpired) {
      badgeColor = Colors.grey;
      badgeText = 'Bitti';
    } else if (isUpcoming) {
      badgeColor = Colors.orange;
      badgeText = 'Yakında';
    } else {
      badgeColor = const Color(0xFF16A34A);
      badgeText = 'Aktif';
    }

    final productImageUrl = data['productImageUrl'] as String?;
    final categoryIconUrl = _categoryIconMap[data['categoryId'] as String? ?? ''];
    final marketLogoUrl = _marketIconMap[data['marketId'] as String? ?? ''];

    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Sol: ürün bilgisi
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    (data['product'] as String?)?.isNotEmpty == true
                        ? data['product']
                        : (data['title'] ?? ''),
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: isExpired ? Colors.grey : null,
                    ),
                  ),
                  if (data['campaignType'] == 'priceDiscount') ...[
                    const SizedBox(height: 6),
                    Builder(builder: (_) {
                      final oldP = (data['oldPrice'] as num?)?.toDouble() ?? 0;
                      final newP = (data['newPrice'] as num?)?.toDouble() ?? 0;
                      final pct = oldP > 0 ? ((oldP - newP) / oldP * 100).round() : 0;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            Text(
                              '${priceFormat.format(oldP)} TL',
                              style: const TextStyle(
                                  fontSize: 14, color: Colors.grey,
                                  decoration: TextDecoration.lineThrough),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              '${priceFormat.format(newP)} TL',
                              style: const TextStyle(
                                  fontSize: 14, color: Colors.deepOrange,
                                  fontWeight: FontWeight.bold),
                            ),
                          ]),
                          if (!isExpired && pct > 0) ...[
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF7ED),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '🔥 %$pct indirim',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.deepOrange,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                          ],
                        ],
                      );
                    }),
                  ],
                  if (data['campaignType'] == 'buyOneGetOne') ...[
                    const SizedBox(height: 6),
                    Builder(builder: (_) {
                      final price = (data['productPrice'] as num?)?.toDouble() ?? 0;
                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Container(
                            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFF7ED),
                              borderRadius: BorderRadius.circular(20),
                            ),
                            child: const Text(
                              '🔥 1 alana 1 bedava',
                              style: TextStyle(
                                  fontSize: 11, color: Colors.deepOrange,
                                  fontWeight: FontWeight.w600),
                            ),
                          ),
                          if (price > 0) ...[
                            const SizedBox(height: 4),
                            Row(children: [
                              const Text('2 Ürün: ',
                                  style: TextStyle(
                                      fontSize: 14, color: Colors.black87,
                                      fontWeight: FontWeight.w500)),
                              Text(
                                '${priceFormat.format(price * 2)} TL',
                                style: const TextStyle(
                                    fontSize: 14, color: Colors.grey,
                                    decoration: TextDecoration.lineThrough),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${priceFormat.format(price)} TL',
                                style: const TextStyle(
                                    fontSize: 14, color: Colors.deepOrange,
                                    fontWeight: FontWeight.bold),
                              ),
                            ]),
                          ],
                        ],
                      );
                    }),
                  ],
                  if (data['campaignType'] == 'secondDiscount') ...[
                    const SizedBox(height: 6),
                    Builder(builder: (_) {
                      final rate = (data['discountRate'] as num?)?.toDouble() ?? 0;
                      final price = (data['productPrice'] as num?)?.toDouble() ?? 0;
                      if (price > 0 && rate > 0) {
                        final discountedTotal = price + price * (1 - rate / 100);
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                              decoration: BoxDecoration(
                                color: const Color(0xFFFFF7ED),
                                borderRadius: BorderRadius.circular(20),
                              ),
                              child: Text(
                                '🔥 1 alana 2. %${rate.toInt()} indirimli',
                                style: const TextStyle(
                                    fontSize: 11, color: Colors.deepOrange,
                                    fontWeight: FontWeight.w600),
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(children: [
                              const Text('2 Ürün: ',
                                  style: TextStyle(
                                      fontSize: 14, color: Colors.black87,
                                      fontWeight: FontWeight.w500)),
                              Text(
                                '${priceFormat.format(price * 2)} TL',
                                style: const TextStyle(
                                    fontSize: 14, color: Colors.grey,
                                    decoration: TextDecoration.lineThrough),
                              ),
                              const SizedBox(width: 6),
                              Text(
                                '${priceFormat.format(discountedTotal)} TL',
                                style: const TextStyle(
                                    fontSize: 14, color: Colors.deepOrange,
                                    fontWeight: FontWeight.bold),
                              ),
                            ]),
                          ],
                        );
                      }
                      return Text(
                        '2. üründe %${rate.toInt()} indirim',
                        style: const TextStyle(
                            fontSize: 13, color: Colors.deepOrange,
                            fontWeight: FontWeight.w600),
                      );
                    }),
                  ],
                  const SizedBox(height: 12),
                  // Market + Kategori chip
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    children: [
                      _buildInfoChip(Icons.store, data['marketName'] ?? '', marketLogoUrl),
                      _buildInfoChip(Icons.category, data['categoryName'] ?? '', categoryIconUrl),
                    ],
                  ),
                  // Tarih
                  if (startDate != null && endDate != null) ...[
                    const SizedBox(height: 8),
                    Builder(builder: (_) {
                      final endDay2 = DateTime(endDate.year, endDate.month, endDate.day);
                      final diff = endDay2.difference(today).inDays;
                      if (!isExpired && diff == 0) {
                        return const Row(children: [
                          Icon(Icons.hourglass_bottom, size: 13, color: Colors.red),
                          SizedBox(width: 4),
                          Text('Bugün son',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.red,
                                  fontWeight: FontWeight.w600)),
                        ]);
                      } else if (!isExpired && diff == 1) {
                        return Row(children: [
                          Icon(Icons.access_time, size: 13, color: Colors.orange.shade700),
                          const SizedBox(width: 4),
                          Text('Yarın bitiyor',
                              style: TextStyle(
                                  fontSize: 12, color: Colors.orange.shade700,
                                  fontWeight: FontWeight.w600)),
                        ]);
                      } else {
                        return Row(children: [
                          const Icon(Icons.calendar_today, size: 13, color: Colors.grey),
                          const SizedBox(width: 4),
                          Text(
                            '${dateFormat.format(startDate)} - ${dateFormat.format(endDate)}',
                            style: TextStyle(
                              fontSize: 12,
                              color: isExpired ? Colors.grey : const Color(0xFF16A34A),
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ]);
                      }
                    }),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 10),
            // Sağ: badge + resim + butonlar
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: badgeColor.withValues(alpha: 0.10),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Text(
                    badgeText,
                    style: TextStyle(
                        color: badgeColor,
                        fontSize: 11,
                        fontWeight: FontWeight.w600),
                  ),
                ),
                if (productImageUrl != null && productImageUrl.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      productImageUrl,
                      width: 90,
                      height: 90,
                      fit: BoxFit.cover,
                      loadingBuilder: (_, child, progress) => progress == null
                          ? child
                          : const SizedBox(
                              width: 90,
                              height: 90,
                              child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
                            ),
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ],
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, color: Color(0xFF2563EB), size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => Navigator.push(
                        context,
                        MaterialPageRoute(
                            builder: (_) => AddCampaignScreen(campaignDoc: doc)),
                      ),
                    ),
                    const SizedBox(width: 8),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red, size: 20),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(),
                      onPressed: () => _delete(doc),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoChip(IconData fallbackIcon, String label, String? iconUrl) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (iconUrl != null && iconUrl.isNotEmpty)
            ClipOval(
              child: Image.network(
                iconUrl,
                width: 13,
                height: 13,
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) =>
                    Icon(fallbackIcon, size: 12, color: Colors.grey),
              ),
            )
          else
            Icon(fallbackIcon, size: 12, color: Colors.grey),
          const SizedBox(width: 4),
          Text(label,
              style: const TextStyle(
                  fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);

    return Scaffold(
      body: Column(
        children: [
          _buildFilterBar(),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('campaigns')
                  .orderBy('startDate', descending: false)
                  .snapshots(),
              builder: (context, snapshot) {
                if (snapshot.hasError) return const Center(child: Text('Hata oluştu'));
                if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());

                final all = snapshot.data!.docs;
                final docs = all.where((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  final startDate = (data['startDate'] as Timestamp?)?.toDate();
                  final endDate = (data['endDate'] as Timestamp?)?.toDate();
                  final endDay = endDate != null ? DateTime(endDate.year, endDate.month, endDate.day) : null;
                  if (_selectedMarketId != null && data['marketId'] != _selectedMarketId) return false;
                  if (_selectedCategoryId != null && data['categoryId'] != _selectedCategoryId) return false;
                  switch (_filter) {
                    case CampaignFilter.active:
                      return endDay != null && !endDay.isBefore(today) &&
                          (startDate == null || !startDate.isAfter(now));
                    case CampaignFilter.upcoming:
                      return startDate != null && startDate.isAfter(now);
                    case CampaignFilter.expired:
                      return endDay != null && endDay.isBefore(today);
                  }
                }).toList();

                if (docs.isEmpty) {
                  return Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.campaign_outlined, size: 64, color: Colors.grey.shade300),
                        const SizedBox(height: 12),
                        Text(
                          _filter == CampaignFilter.active
                              ? 'Devam eden kampanya yok'
                              : _filter == CampaignFilter.upcoming
                                  ? 'Gelecek kampanya yok'
                                  : 'Süresi dolan kampanya yok',
                          style: const TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  );
                }

                return Column(
                  children: [
                    if (_filter == CampaignFilter.expired)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            onPressed: () => _deleteAll(docs),
                            icon: const Icon(Icons.delete_sweep_outlined),
                            label: Text('Tümünü Sil (${docs.length})'),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.red.shade400,
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                            ),
                          ),
                        ),
                      ),
                    Expanded(
                      child: ListView.separated(
                  padding: const EdgeInsets.all(16),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (context, i) => _buildCampaignCard(docs[i]),
                      ),
                    ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFilterBar() {
    return Column(
      children: [
        Container(
          color: Colors.white,
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: Row(
            children: [
              _filterChip(CampaignFilter.active, 'Devam Eden', Colors.green.shade700),
              const SizedBox(width: 8),
              _filterChip(CampaignFilter.upcoming, 'Gelecek', const Color(0xFF2563EB)),
              const SizedBox(width: 8),
              _filterChip(CampaignFilter.expired, 'Süresi Dolan', Colors.red.shade400),
            ],
          ),
        ),
        _buildMarketChips(),
        _buildCategoryChips(),
      ],
    );
  }

  Widget _buildMarketChips() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('markets').orderBy('name').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox(height: 40);
        final docs = snapshot.data!.docs;
        return Container(
          color: const Color(0xFFF8FAFF),
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _marketFilterChip(
                  label: 'Tüm Marketler',
                  logoUrl: null,
                  selected: _selectedMarketId == null,
                  onTap: () => setState(() => _selectedMarketId = null),
                ),
                ...docs.map((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  return _marketFilterChip(
                    label: doc.get('name') as String,
                    logoUrl: data['logoUrl'] as String?,
                    selected: _selectedMarketId == doc.id,
                    onTap: () => setState(() =>
                      _selectedMarketId = _selectedMarketId == doc.id ? null : doc.id,
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildCategoryChips() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('categories').orderBy('name').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) return const SizedBox(height: 40);
        final docs = snapshot.data!.docs;
        return Container(
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFF),
            boxShadow: [
              BoxShadow(color: Colors.black.withOpacity(0.05), offset: const Offset(0, 2), blurRadius: 4),
            ],
          ),
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                _categoryFilterChip(
                  name: 'Tüm Kategoriler',
                  iconUrl: null,
                  selected: _selectedCategoryId == null,
                  onTap: () => setState(() => _selectedCategoryId = null),
                ),
                ...docs.map((doc) {
                  final data = doc.data() as Map<String, dynamic>;
                  return _categoryFilterChip(
                    name: data['name'] as String? ?? '',
                    iconUrl: data['iconUrl'] as String?,
                    selected: _selectedCategoryId == doc.id,
                    onTap: () => setState(() =>
                      _selectedCategoryId = _selectedCategoryId == doc.id ? null : doc.id,
                    ),
                  );
                }),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _marketFilterChip({
    required String label,
    String? logoUrl,
    required bool selected,
    required VoidCallback onTap,
  }) {
    const color = Color(0xFF2563EB);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? color : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? color : Colors.grey.shade300),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (logoUrl != null && logoUrl.isNotEmpty) ...[
                ClipOval(
                  child: Image.network(
                    logoUrl,
                    width: 16,
                    height: 16,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.store, size: 14, color: selected ? Colors.white : color),
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? Colors.white : Colors.grey.shade700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _categoryFilterChip({
    required String name,
    String? iconUrl,
    required bool selected,
    required VoidCallback onTap,
  }) {
    const color = Color(0xFF7C3AED);
    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: selected ? color : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(color: selected ? color : Colors.grey.shade300),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (iconUrl != null && iconUrl.isNotEmpty) ...[
                ClipOval(
                  child: Image.network(
                    iconUrl,
                    width: 16,
                    height: 16,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => Icon(Icons.category, size: 14, color: selected ? Colors.white : color),
                  ),
                ),
                const SizedBox(width: 5),
              ],
              Text(
                name,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.normal,
                  color: selected ? Colors.white : Colors.grey.shade700,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _filterChip(CampaignFilter filter, String label, Color color) {
    final isSelected = _filter == filter;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _filter = filter),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8),
          decoration: BoxDecoration(
            color: isSelected ? color : Colors.grey.shade100,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: isSelected ? color : Colors.grey.shade300),
          ),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: isSelected ? Colors.white : Colors.grey.shade600,
            ),
          ),
        ),
      ),
    );
  }
}
