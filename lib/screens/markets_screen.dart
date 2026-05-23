import 'dart:io';
import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';

String _toTopicKey(String name) {
  const tr = 'şŞıİğĞüÜöÖçÇ';
  const en = 'sSiIgGuUoOcC';
  var s = name;
  for (var i = 0; i < tr.length; i++) {
    s = s.replaceAll(tr[i], en[i]);
  }
  return s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '_');
}

class MarketsScreen extends StatelessWidget {
  const MarketsScreen({super.key});

  void _showAddDialog(BuildContext context, {DocumentSnapshot? doc}) {
    final controller = TextEditingController(text: doc?.get('name') ?? '');
    final data = doc?.data() as Map<String, dynamic>?;
    XFile? pickedImage;
    String? existingLogoUrl = data?['logoUrl'] as String?;
    bool saving = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: Text(doc == null ? 'Market Ekle' : 'Market Düzenle'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Market Adı',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
                // Logo alanı
                GestureDetector(
                  onTap: () async {
                    final source = await showModalBottomSheet<ImageSource>(
                      context: ctx,
                      builder: (bCtx) => SafeArea(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            ListTile(
                              leading: const Icon(Icons.photo_library_outlined),
                              title: const Text('Galeriden Seç'),
                              onTap: () => Navigator.pop(bCtx, ImageSource.gallery),
                            ),
                            ListTile(
                              leading: const Icon(Icons.camera_alt_outlined),
                              title: const Text('Kamera ile Çek'),
                              onTap: () => Navigator.pop(bCtx, ImageSource.camera),
                            ),
                          ],
                        ),
                      ),
                    );
                    if (source == null) return;
                    final picked = await ImagePicker().pickImage(
                      source: source,
                      imageQuality: 85,
                      maxWidth: 400,
                    );
                    if (picked != null) setStateDialog(() => pickedImage = picked);
                  },
                  child: Container(
                    height: 80,
                    width: 80,
                    decoration: BoxDecoration(
                      color: const Color(0xFFDCEDFF),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(color: const Color(0xFF2563EB).withOpacity(0.3)),
                    ),
                    child: pickedImage != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(pickedImage!.path),
                              fit: BoxFit.contain,
                            ),
                          )
                        : (existingLogoUrl != null && existingLogoUrl!.isNotEmpty)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.network(
                                  existingLogoUrl!,
                                  fit: BoxFit.contain,
                                ),
                              )
                            : const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_photo_alternate_outlined,
                                      color: Color(0xFF2563EB), size: 28),
                                  SizedBox(height: 4),
                                  Text('Logo',
                                      style: TextStyle(
                                          fontSize: 11, color: Color(0xFF2563EB))),
                                ],
                              ),
                  ),
                ),
                if (pickedImage != null || (existingLogoUrl != null && existingLogoUrl!.isNotEmpty))
                  TextButton.icon(
                    onPressed: () => setStateDialog(() {
                      pickedImage = null;
                      existingLogoUrl = null;
                    }),
                    icon: const Icon(Icons.delete_outline, size: 16, color: Colors.red),
                    label: const Text('Logoyu Kaldır',
                        style: TextStyle(color: Colors.red, fontSize: 12)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      final name = controller.text.trim();
                      if (name.isEmpty) return;
                      setStateDialog(() => saving = true);
                      try {
                        String? logoUrl = existingLogoUrl;
                        if (pickedImage != null) {
                          final ext = pickedImage!.name.contains('.')
                              ? pickedImage!.name.split('.').last
                              : 'jpg';
                          final ref = FirebaseStorage.instance.ref(
                              'market_logos/${DateTime.now().millisecondsSinceEpoch}.$ext');
                          await ref.putFile(File(pickedImage!.path));
                          logoUrl = await ref.getDownloadURL();
                        }
                        final col = FirebaseFirestore.instance.collection('markets');
                        if (doc == null) {
                          await col.add({
                            'name': name,
                            'topicKey': _toTopicKey(name),
                            'logoUrl': logoUrl ?? '',
                            'createdAt': FieldValue.serverTimestamp(),
                          });
                        } else {
                          await doc.reference.update({
                            'name': name,
                            'topicKey': _toTopicKey(name),
                            'logoUrl': logoUrl ?? '',
                          });
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setStateDialog(() => saving = false);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(content: Text('Hata: $e'), backgroundColor: Colors.red),
                          );
                        }
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  void _delete(BuildContext context, DocumentSnapshot doc) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Marketi Sil'),
        content: Text('"${doc.get('name')}" silinsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              await doc.reference.delete();
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Sil'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('markets')
            .orderBy('name')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError) return const Center(child: Text('Hata oluştu'));
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text('Henüz market eklenmedi',
                  style: TextStyle(color: Colors.grey)),
            );
          }
          return ListView.separated(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 80),
            itemCount: docs.length,
            separatorBuilder: (_, __) => const Divider(height: 1),
            itemBuilder: (context, i) {
              final doc = docs[i];
              final data = doc.data() as Map<String, dynamic>;
              final logoUrl = data['logoUrl'] as String?;
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFFDCEDFF),
                  child: (logoUrl != null && logoUrl.isNotEmpty)
                      ? ClipOval(
                          child: Image.network(
                            logoUrl,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) =>
                                const Icon(Icons.store, color: Color(0xFF2563EB)),
                          ),
                        )
                      : const Icon(Icons.store, color: Color(0xFF2563EB)),
                ),
                title: Text(doc.get('name'),
                    style: const TextStyle(fontWeight: FontWeight.w500)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      icon: const Icon(Icons.edit_outlined),
                      onPressed: () => _showAddDialog(context, doc: doc),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, color: Colors.red),
                      onPressed: () => _delete(context, doc),
                    ),
                  ],
                ),
              );
            },
          );
        },
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _showAddDialog(context),
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Market Ekle'),
      ),
    );
  }
}
