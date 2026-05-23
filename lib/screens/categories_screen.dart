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

class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key});

  void _showAddDialog(BuildContext context, {DocumentSnapshot? doc}) {
    final nameController = TextEditingController(text: doc?.get('name') ?? '');
    final data = doc?.data() as Map<String, dynamic>?;
    XFile? pickedImage;
    String? existingIconUrl = data?['iconUrl'] as String?;
    bool saving = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setStateDialog) => AlertDialog(
          title: Text(doc == null ? 'Kategori Ekle' : 'Kategori Düzenle'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    labelText: 'Kategori Adı',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 16),
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
                      color: const Color(0xFFF0FDF4),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                          color: const Color(0xFF16A34A).withOpacity(0.3)),
                    ),
                    child: pickedImage != null
                        ? ClipRRect(
                            borderRadius: BorderRadius.circular(12),
                            child: Image.file(
                              File(pickedImage!.path),
                              fit: BoxFit.contain,
                            ),
                          )
                        : (existingIconUrl != null && existingIconUrl!.isNotEmpty)
                            ? ClipRRect(
                                borderRadius: BorderRadius.circular(12),
                                child: Image.network(
                                  existingIconUrl!,
                                  fit: BoxFit.contain,
                                ),
                              )
                            : const Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Icon(Icons.add_photo_alternate_outlined,
                                      color: Color(0xFF16A34A), size: 28),
                                  SizedBox(height: 4),
                                  Text('İkon',
                                      style: TextStyle(
                                          fontSize: 11,
                                          color: Color(0xFF16A34A))),
                                ],
                              ),
                  ),
                ),
                if (pickedImage != null ||
                    (existingIconUrl != null && existingIconUrl!.isNotEmpty))
                  TextButton.icon(
                    onPressed: () => setStateDialog(() {
                      pickedImage = null;
                      existingIconUrl = null;
                    }),
                    icon: const Icon(Icons.delete_outline,
                        size: 16, color: Colors.red),
                    label: const Text('İkonu Kaldır',
                        style: TextStyle(color: Colors.red, fontSize: 12)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('İptal')),
            ElevatedButton(
              onPressed: saving
                  ? null
                  : () async {
                      final name = nameController.text.trim();
                      if (name.isEmpty) return;
                      setStateDialog(() => saving = true);
                      try {
                        String? iconUrl = existingIconUrl;
                        if (pickedImage != null) {
                          final ext = pickedImage!.name.contains('.')
                              ? pickedImage!.name.split('.').last
                              : 'jpg';
                          final ref = FirebaseStorage.instance.ref(
                              'category_icons/${DateTime.now().millisecondsSinceEpoch}.$ext');
                          await ref.putFile(File(pickedImage!.path));
                          iconUrl = await ref.getDownloadURL();
                        }
                        final col =
                            FirebaseFirestore.instance.collection('categories');
                        if (doc == null) {
                          await col.add({
                            'name': name,
                            'topicKey': _toTopicKey(name),
                            'iconUrl': iconUrl ?? '',
                            'createdAt': FieldValue.serverTimestamp(),
                          });
                        } else {
                          await doc.reference.update({
                            'name': name,
                            'topicKey': _toTopicKey(name),
                            'iconUrl': iconUrl ?? '',
                          });
                        }
                        if (ctx.mounted) Navigator.pop(ctx);
                      } catch (e) {
                        setStateDialog(() => saving = false);
                        if (ctx.mounted) {
                          ScaffoldMessenger.of(ctx).showSnackBar(
                            SnackBar(
                                content: Text('Hata: $e'),
                                backgroundColor: Colors.red),
                          );
                        }
                      }
                    },
              child: saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                          strokeWidth: 2, color: Colors.white),
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
        title: const Text('Kategoriyi Sil'),
        content: Text('"${doc.get('name')}" silinsin mi?'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('Iptal')),
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
            .collection('categories')
            .orderBy('name')
            .snapshots(),
        builder: (context, snapshot) {
          if (snapshot.hasError)
            return const Center(child: Text('Hata olustu'));
          if (!snapshot.hasData)
            return const Center(child: CircularProgressIndicator());
          final docs = snapshot.data!.docs;
          if (docs.isEmpty) {
            return const Center(
              child: Text('Henuz kategori eklenmedi',
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
              final iconUrl = data['iconUrl'] as String?;
              return ListTile(
                leading: CircleAvatar(
                  backgroundColor: const Color(0xFFF0FDF4),
                  child: (iconUrl != null && iconUrl.isNotEmpty)
                      ? ClipOval(
                          child: Image.network(
                            iconUrl,
                            fit: BoxFit.contain,
                            errorBuilder: (_, __, ___) => const Icon(
                                Icons.category,
                                color: Color(0xFF16A34A)),
                          ),
                        )
                      : const Icon(Icons.category, color: Color(0xFF16A34A)),
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
        backgroundColor: const Color(0xFF16A34A),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('Kategori Ekle'),
      ),
    );
  }
}
