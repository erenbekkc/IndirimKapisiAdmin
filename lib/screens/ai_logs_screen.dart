import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

class AiLogsScreen extends StatelessWidget {
  const AiLogsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          _buildSummaryBar(),
          Expanded(
            child: StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('chatbot_logs')
                  .orderBy('timestamp', descending: true)
                  .limit(200)
                  .snapshots(),
              builder: (context, snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (snap.hasError) {
                  return Center(child: Text('Firestore hatası: ${snap.error}'));
                }
                final docs = snap.data?.docs ?? [];
                if (docs.isEmpty) {
                  return const Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_outline, size: 64, color: Colors.green),
                        SizedBox(height: 12),
                        Text('Henüz hata kaydı yok', style: TextStyle(fontSize: 16, color: Colors.grey)),
                      ],
                    ),
                  );
                }
                return ListView.separated(
                  padding: const EdgeInsets.all(12),
                  itemCount: docs.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 8),
                  itemBuilder: (_, i) => _LogCard(doc: docs[i]),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSummaryBar() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('chatbot_logs').snapshots(),
      builder: (context, snap) {
        final docs = snap.data?.docs ?? [];
        final apiErrors = docs.where((d) => (d.data() as Map)['type'] == 'api_error').length;
        final connErrors = docs.where((d) => (d.data() as Map)['type'] == 'connection_error').length;

        return Container(
          color: const Color(0xFF1E3A5F),
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            children: [
              _StatChip(label: 'Toplam', value: '${docs.length}', color: Colors.white70),
              const SizedBox(width: 12),
              _StatChip(label: 'API Hatası', value: '$apiErrors', color: Colors.orange.shade200),
              const SizedBox(width: 12),
              _StatChip(label: 'Bağlantı Hatası', value: '$connErrors', color: Colors.red.shade200),
              const Spacer(),
              if (docs.isNotEmpty)
                TextButton.icon(
                  onPressed: () => _confirmClearAll(context),
                  icon: const Icon(Icons.delete_sweep, color: Colors.white54, size: 18),
                  label: const Text('Temizle', style: TextStyle(color: Colors.white54, fontSize: 12)),
                ),
            ],
          ),
        );
      },
    );
  }

  void _confirmClearAll(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Logları Temizle'),
        content: const Text('Tüm hata kayıtları silinecek. Emin misiniz?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('İptal')),
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              final snap = await FirebaseFirestore.instance.collection('chatbot_logs').get();
              final batch = FirebaseFirestore.instance.batch();
              for (final doc in snap.docs) {
                batch.delete(doc.reference);
              }
              await batch.commit();
            },
            child: const Text('Sil', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }
}

class _StatChip extends StatelessWidget {
  final String label;
  final String value;
  final Color color;

  const _StatChip({required this.label, required this.value, required this.color});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(value, style: TextStyle(color: color, fontSize: 18, fontWeight: FontWeight.bold)),
        Text(label, style: const TextStyle(color: Colors.white54, fontSize: 11)),
      ],
    );
  }
}

class _LogCard extends StatelessWidget {
  final QueryDocumentSnapshot doc;

  const _LogCard({required this.doc});

  @override
  Widget build(BuildContext context) {
    final data = doc.data() as Map<String, dynamic>;
    final type = data['type'] as String? ?? '';
    final statusCode = data['statusCode'] as int?;
    final errorMessage = data['errorMessage'] as String? ?? '';
    final userQuery = data['userQuery'] as String? ?? '';
    final timestamp = (data['timestamp'] as Timestamp?)?.toDate();

    final isApiError = type == 'api_error';
    final color = isApiError ? Colors.orange : Colors.red;
    final icon = isApiError ? Icons.cloud_off : Icons.wifi_off;
    final label = isApiError
        ? 'API Hatası${statusCode != null ? ' ($statusCode)' : ''}'
        : 'Bağlantı Hatası';

    return Container(
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: color.withOpacity(0.3)),
        boxShadow: [
          BoxShadow(color: Colors.black.withOpacity(0.04), blurRadius: 4, offset: const Offset(0, 2)),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: color, size: 16),
                const SizedBox(width: 6),
                Text(label,
                    style: TextStyle(color: color, fontWeight: FontWeight.bold, fontSize: 13)),
                const Spacer(),
                if (timestamp != null)
                  Text(
                    DateFormat('dd MMM HH:mm', 'tr_TR').format(timestamp),
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
              ],
            ),
            if (userQuery.isNotEmpty) ...[
              const SizedBox(height: 8),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Sorgu: ', style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.w600)),
                  Expanded(
                    child: Text(userQuery, style: const TextStyle(fontSize: 12, color: Colors.black87)),
                  ),
                ],
              ),
            ],
            if (errorMessage.isNotEmpty) ...[
              const SizedBox(height: 6),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: color.withOpacity(0.05),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  errorMessage,
                  style: TextStyle(fontSize: 11, color: color.shade700, fontFamily: 'monospace'),
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
