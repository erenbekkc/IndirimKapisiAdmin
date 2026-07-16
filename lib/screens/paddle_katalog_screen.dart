import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'katalog_giris_screen.dart' show CatalogDraft;

class PaddleKatalogScreen extends StatefulWidget {
  const PaddleKatalogScreen({super.key});

  @override
  State<PaddleKatalogScreen> createState() => _PaddleKatalogScreenState();
}

class _PaddleKatalogScreenState extends State<PaddleKatalogScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  XFile? _pickedImage;
  bool _analyzing = false;
  String? _analyzeStatus;
  List<CatalogDraft> _aiItems = [];
  String? _analyzeError;
  String? _ocrRawText;

  final Set<String> _selectedDraftIds = {};
  bool _publishing = false;
  DateTime? _bulkStartDate;
  DateTime? _bulkEndDate;
  bool _applyingBulkDates = false;

  static const _geminiKey    = 'gemini_api_key';
  static const _googleApiKey = 'google_api_key';
  static const _googleCxKey  = 'google_cx';

  final _dateFormat = DateFormat('dd.MM.yyyy', 'tr_TR');
  final _priceFmt   = NumberFormat('#,##0.00', 'tr_TR');

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  // -----------------------------------------------------------------------
  // Campaign type card helper
  // -----------------------------------------------------------------------

  Widget _editTypeCard(
    StateSetter setS, String type, String icon, String title, String subtitle,
    String currentType, void Function(String) onSelect,
  ) {
    final isSelected = currentType == type;
    return GestureDetector(
      onTap: () => setS(() => onSelect(type)),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFEFF6FF) : Colors.grey.shade50,
          border: Border.all(
            color: isSelected ? const Color(0xFF2563EB) : Colors.grey.shade300,
            width: isSelected ? 2 : 1,
          ),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Row(children: [
          Text(icon, style: const TextStyle(fontSize: 20)),
          const SizedBox(width: 10),
          Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title, style: TextStyle(
              fontWeight: FontWeight.w600, fontSize: 13,
              color: isSelected ? const Color(0xFF2563EB) : Colors.black87,
            )),
            Text(subtitle, style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
          ])),
          if (isSelected) const Icon(Icons.check_circle, color: Color(0xFF2563EB), size: 20),
        ]),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Settings (Gemini + görsel arama — sunucu URL yok artık)
  // -----------------------------------------------------------------------

  void _showSettingsDialog() async {
    final prefs = await SharedPreferences.getInstance();
    final geminiCtrl    = TextEditingController(text: prefs.getString(_geminiKey) ?? '');
    final googleApiCtrl = TextEditingController(text: prefs.getString(_googleApiKey) ?? '');
    final googleCxCtrl  = TextEditingController(text: prefs.getString(_googleCxKey) ?? '');
    bool obscureG = true;

    if (!mounted) return;
    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          title: const Row(children: [
            Icon(Icons.settings, color: Color(0xFF2563EB), size: 20),
            SizedBox(width: 8),
            Text('API Ayarları'),
          ]),
          content: SingleChildScrollView(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              const Text(
                '📱 OCR tamamen cihaz içinde çalışır\n(ML Kit — internet gerekmez)',
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 12, color: Colors.green, fontWeight: FontWeight.w500),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: geminiCtrl,
                obscureText: obscureG,
                decoration: InputDecoration(
                  labelText: 'Gemini API Key (metin parse için)',
                  border: const OutlineInputBorder(),
                  hintText: 'AIzaSy...',
                  helperText: 'OCR metnini yapılandırmak için kullanılır',
                  suffixIcon: IconButton(
                    icon: Icon(obscureG ? Icons.visibility_outlined : Icons.visibility_off_outlined),
                    onPressed: () => setD(() => obscureG = !obscureG),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: googleApiCtrl,
                decoration: const InputDecoration(
                  labelText: 'Google API Key (görsel arama)',
                  border: OutlineInputBorder(),
                  hintText: 'AIzaSy...',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: googleCxCtrl,
                decoration: const InputDecoration(
                  labelText: 'Google Search Engine ID (cx)',
                  border: OutlineInputBorder(),
                  hintText: 'xxxxxxxxxxxxxxx',
                ),
              ),
            ]),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
            ElevatedButton(
              onPressed: () async {
                await prefs.setString(_geminiKey,     geminiCtrl.text.trim());
                await prefs.setString(_googleApiKey,  googleApiCtrl.text.trim());
                await prefs.setString(_googleCxKey,   googleCxCtrl.text.trim());
                if (ctx.mounted) Navigator.pop(ctx);
              },
              style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF2563EB), foregroundColor: Colors.white),
              child: const Text('Kaydet'),
            ),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // File pick
  // -----------------------------------------------------------------------

  Future<void> _pickFile() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(
            leading: const Icon(Icons.photo_library_outlined),
            title: const Text('Galeriden Fotoğraf Seç'),
            onTap: () => Navigator.pop(ctx, 'gallery'),
          ),
          ListTile(
            leading: const Icon(Icons.camera_alt_outlined),
            title: const Text('Kamera ile Çek'),
            onTap: () => Navigator.pop(ctx, 'camera'),
          ),
        ]),
      ),
    );
    if (choice == null) return;
    final src = choice == 'gallery' ? ImageSource.gallery : ImageSource.camera;
    final picked = await ImagePicker().pickImage(source: src, imageQuality: 90, maxWidth: 1600);
    if (picked != null) {
      setState(() {
        _pickedImage = picked;
        _aiItems = [];
        _analyzeError = null;
        _ocrRawText = null;
      });
    }
  }

  // -----------------------------------------------------------------------
  // Analyze — ML Kit OCR (cihaz içi) → Gemini text parse
  // -----------------------------------------------------------------------

  Future<void> _analyze() async {
    if (_pickedImage == null) return;

    final prefs = await SharedPreferences.getInstance();
    String geminiKey = '';
    try {
      final doc = await FirebaseFirestore.instance.collection('config').doc('gemini').get();
      geminiKey = (doc.data()?['apiKey'] as String? ?? '').trim();
    } catch (_) {}
    if (geminiKey.isEmpty) geminiKey = prefs.getString(_geminiKey) ?? '';

    if (geminiKey.isEmpty) {
      _showSettingsDialog();
      return;
    }

    setState(() {
      _analyzing = true;
      _analyzeStatus = 'ML Kit ile metin okunuyor...';
      _analyzeError = null;
      _aiItems = [];
      _ocrRawText = null;
    });

    try {
      // --- Adım 1: ML Kit ile cihaz içi OCR ---
      final inputImage = InputImage.fromFilePath(_pickedImage!.path);
      final textRecognizer = TextRecognizer(script: TextRecognitionScript.latin);
      final RecognizedText recognizedText = await textRecognizer.processImage(inputImage);
      await textRecognizer.close();

      final rawText = recognizedText.text.trim();

      if (rawText.isEmpty) {
        setState(() => _analyzeError = 'Görselde metin bulunamadı. Daha net bir fotoğraf deneyin.');
        return;
      }

      setState(() {
        _ocrRawText = rawText;
        _analyzeStatus = 'Gemini ile ürünler ayrıştırılıyor...';
      });

      // --- Adım 2: Gemini ile parse et ---
      final catsSnap = await FirebaseFirestore.instance.collection('categories').orderBy('name').get();
      final categoryNames = catsSnap.docs.map((d) => d.get('name') as String).join(', ');

      final prompt = '''Aşağıdaki metin bir market indirim broşüründen OCR ile okunmuştur. İçerisindeki TÜM ürünleri analiz et.

OCR METNİ:
$rawText

SADECE aşağıdaki JSON formatında döndür, başka hiçbir metin ekleme:

{"items":[{"marketName":"market adı (bulamazsan boş)","productName":"ürünün tam adı","categoryName":"aşağıdaki listeden en uygun kategori","originalPrice":sayı_veya_null,"discountedPrice":sayı_veya_null,"startDate":"GG.AA.YYYY_veya_null","endDate":"GG.AA.YYYY_veya_null"}]}

Mevcut kategoriler (SADECE bu listeden seç, birebir aynı yaz): $categoryNames

Kurallar:
- categoryName alanı için mutlaka yukarıdaki listeden birini seç
- Fiyatlar ondalık noktalı sayı (TL işareti yok), bulamazsan null
- Tarih bulamazsan null
- Tüm ürünleri dahil et, hiçbirini atlama
- productName alanında broşürde ne yazıyorsa HARFİYEN yaz''';

      final geminiResp = await http.post(
        Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=$geminiKey',
        ),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'contents': [{'parts': [{'text': prompt}]}],
          'generationConfig': {'temperature': 0.1, 'maxOutputTokens': 8192},
        }),
      ).timeout(const Duration(seconds: 60));

      if (geminiResp.statusCode == 200) {
        final body = jsonDecode(utf8.decode(geminiResp.bodyBytes));
        final text = (body['candidates'] as List).first['content']['parts'][0]['text'] as String;
        final s = text.indexOf('{');
        final e = text.lastIndexOf('}') + 1;
        if (s >= 0 && e > s) {
          final parsed = jsonDecode(text.substring(s, e));
          final list = (parsed['items'] as List?) ?? [];
          final items = list
              .map((j) => CatalogDraft.fromAiJson(j as Map<String, dynamic>))
              .where((d) => d.productName.isNotEmpty)
              .toList();
          setState(() => _aiItems = items);
          if (_aiItems.isEmpty) {
            setState(() => _analyzeError = 'Ürün bulunamadı. OCR metnini kontrol edin.');
          } else {
            await _fetchProductImages();
          }
        } else {
          setState(() => _analyzeError = 'Gemini yanıtı ayrıştırılamadı, tekrar deneyin.');
        }
      } else {
        String msg;
        try {
          final errBody = jsonDecode(geminiResp.body);
          msg = (errBody['error']?['message'] as String?) ?? 'HTTP ${geminiResp.statusCode}';
        } catch (_) {
          msg = 'HTTP ${geminiResp.statusCode}';
        }
        setState(() => _analyzeError = 'Gemini Hatası: $msg');
      }
    } on SocketException {
      setState(() => _analyzeError = 'İnternet bağlantısı yok (Gemini için gerekli).');
    } catch (e) {
      setState(() => _analyzeError = 'Hata: $e');
    } finally {
      setState(() { _analyzing = false; _analyzeStatus = null; });
    }
  }

  // -----------------------------------------------------------------------
  // Image search
  // -----------------------------------------------------------------------

  Future<String?> _searchImageInCampaigns(String productName) async {
    try {
      final snap = await FirebaseFirestore.instance
          .collection('campaigns')
          .where('product', isEqualTo: productName)
          .limit(5)
          .get();
      for (final doc in snap.docs) {
        final url = (doc.data()['productImageUrl'] as String? ?? '').trim();
        if (url.isNotEmpty) return url;
      }
    } catch (_) {}
    return null;
  }

  Future<String?> _searchImageDuckDuckGo(String query) async {
    try {
      final resp = await http.get(
        Uri.parse('https://europe-west1-indirim-takip-71bc8.cloudfunctions.net/searchImage?q=${Uri.encodeQueryComponent(query)}'),
      ).timeout(const Duration(seconds: 20));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return body['url'] as String?;
      }
    } catch (_) {}
    return null;
  }

  Future<void> _fetchProductImages() async {
    int found = 0, fromCache = 0;
    for (int i = 0; i < _aiItems.length; i++) {
      final item = _aiItems[i];
      if (mounted) setState(() => _analyzeStatus = 'Görsel ${i + 1}/${_aiItems.length} aranıyor...');
      String? imageUrl = await _searchImageInCampaigns(item.productName);
      if (imageUrl != null) {
        fromCache++;
      } else {
        imageUrl = await _searchImageDuckDuckGo(item.productName);
      }
      if (imageUrl != null) {
        item.productImageUrl = imageUrl;
        found++;
        if (mounted) setState(() {});
      }
    }
    if (mounted) {
      final cacheInfo = fromCache > 0
          ? ' ($fromCache kampanyadan, ${found - fromCache} internet)'
          : '';
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(found > 0
            ? '$found/${_aiItems.length} ürün için görsel bulundu.$cacheInfo'
            : 'Görsel bulunamadı.'),
        backgroundColor: found > 0 ? const Color(0xFF16A34A) : Colors.orange,
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
      ));
    }
  }

  // -----------------------------------------------------------------------
  // Edit bottom sheet
  // -----------------------------------------------------------------------

  Future<void> _showEditSheet(CatalogDraft draft, {VoidCallback? onSaved}) async {
    final prodCtrl      = TextEditingController(text: draft.productName);
    final origCtrl      = TextEditingController(text: draft.originalPrice != null ? draft.originalPrice!.toStringAsFixed(2) : '');
    final discCtrl      = TextEditingController(text: draft.discountedPrice != null ? draft.discountedPrice!.toStringAsFixed(2) : '');
    final discRateCtrl  = TextEditingController(text: draft.discountRate != null ? draft.discountRate.toString() : '');
    final prodPriceCtrl = TextEditingController(text: draft.productPrice != null ? draft.productPrice!.toStringAsFixed(2) : '');

    String campaignType = draft.campaignType;
    String marketId     = draft.marketId;
    String marketName   = draft.marketName;
    String categoryId   = draft.categoryId;
    String categoryName = draft.categoryName;
    DateTime? startDate = draft.startDate;
    DateTime? endDate   = draft.endDate;
    String? imageUrl    = draft.productImageUrl;
    bool uploadingImage = false;
    bool searchingImage = false;

    final marketsSnap = await FirebaseFirestore.instance.collection('markets').orderBy('name').get();
    final catsSnap    = await FirebaseFirestore.instance.collection('categories').orderBy('name').get();

    String normMkt(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s.\-_]'), '');
    const aliases = <String, String>{
      'money': 'migros', 'moneymigros': 'migros', 'carrfour': 'carrefour',
      'carrefoursa': 'carrefour', 'sok': 'şok', 'sokmarket': 'şok',
      'a101': 'a-101', 'bimeks': 'bim',
    };

    if (marketId.isEmpty && marketName.isNotEmpty) {
      final norm = normMkt(marketName);
      final aliasNorm = aliases[norm] ?? norm;
      final match = marketsSnap.docs.where((d) {
        final dbNorm = normMkt(d.get('name') as String);
        return dbNorm == aliasNorm || dbNorm == norm ||
               (d.get('name') as String).toLowerCase().contains(aliasNorm);
      }).firstOrNull;
      if (match != null) { marketId = match.id; marketName = match.get('name') as String; }
    }
    if (categoryId.isEmpty && categoryName.isNotEmpty) {
      final match = catsSnap.docs.where((d) =>
        (d.get('name') as String).toLowerCase() == categoryName.toLowerCase()
      ).firstOrNull;
      if (match != null) { categoryId = match.id; categoryName = match.get('name') as String; }
    }

    if (!mounted) return;

    await showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(20))),
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setS) => Padding(
          padding: EdgeInsets.fromLTRB(16, 16, 16,
              MediaQuery.of(ctx).viewInsets.bottom + MediaQuery.of(ctx).padding.bottom + 16),
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Center(
                  child: Container(
                    width: 40, height: 4,
                    decoration: BoxDecoration(color: Colors.grey.shade300, borderRadius: BorderRadius.circular(2)),
                  ),
                ),
                const SizedBox(height: 16),
                const Text('Ürün Düzenle', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),

                GestureDetector(
                  onTap: uploadingImage ? null : () async {
                    final src = await showModalBottomSheet<ImageSource>(
                      context: ctx,
                      builder: (c) => SafeArea(
                        child: Column(mainAxisSize: MainAxisSize.min, children: [
                          ListTile(
                            leading: const Icon(Icons.photo_library_outlined),
                            title: const Text('Galeriden Seç'),
                            onTap: () => Navigator.pop(c, ImageSource.gallery),
                          ),
                          ListTile(
                            leading: const Icon(Icons.camera_alt_outlined),
                            title: const Text('Kamera ile Çek'),
                            onTap: () => Navigator.pop(c, ImageSource.camera),
                          ),
                        ]),
                      ),
                    );
                    if (src == null) return;
                    final picked = await ImagePicker().pickImage(source: src, imageQuality: 85, maxWidth: 1000);
                    if (picked == null) return;
                    setS(() => uploadingImage = true);
                    try {
                      final bytes = await File(picked.path).readAsBytes();
                      final ref = FirebaseStorage.instance.ref()
                          .child('catalog_drafts/${DateTime.now().millisecondsSinceEpoch}.jpg');
                      final task = await ref.putData(bytes, SettableMetadata(contentType: 'image/jpeg'));
                      final url = await task.ref.getDownloadURL();
                      setS(() { imageUrl = url; uploadingImage = false; });
                    } catch (_) {
                      setS(() => uploadingImage = false);
                    }
                  },
                  child: Container(
                    height: 120,
                    width: double.infinity,
                    decoration: BoxDecoration(
                      color: const Color(0xFFEFF6FF),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: const Color(0xFF2563EB).withOpacity(0.3)),
                    ),
                    child: uploadingImage
                        ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                        : imageUrl != null && imageUrl!.isNotEmpty
                            ? Stack(fit: StackFit.expand, children: [
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(9),
                                  child: Image.network(imageUrl!, fit: BoxFit.contain,
                                      errorBuilder: (_, __, ___) => const Icon(Icons.broken_image_outlined, color: Colors.grey)),
                                ),
                                Positioned(
                                  top: 6, right: 6,
                                  child: Container(
                                    padding: const EdgeInsets.all(4),
                                    decoration: const BoxDecoration(color: Color(0xFF2563EB), shape: BoxShape.circle),
                                    child: const Icon(Icons.edit, color: Colors.white, size: 14),
                                  ),
                                ),
                              ])
                            : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                Icon(Icons.add_photo_alternate_outlined, size: 36, color: Color(0xFF2563EB)),
                                SizedBox(height: 6),
                                Text('Fotoğraf Ekle', style: TextStyle(color: Color(0xFF2563EB), fontSize: 13)),
                              ]),
                  ),
                ),
                const SizedBox(height: 8),

                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: searchingImage || uploadingImage ? null : () async {
                      final query = prodCtrl.text.trim();
                      if (query.isEmpty) return;
                      setS(() => searchingImage = true);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('"$query" için görsel aranıyor...'),
                        duration: const Duration(seconds: 30),
                        behavior: SnackBarBehavior.floating,
                      ));
                      try {
                        String? found = await _searchImageInCampaigns(query);
                        String source = found != null ? 'kampanya koleksiyonu' : '';
                        if (found == null) {
                          found = await _searchImageDuckDuckGo(query);
                          if (found != null) source = 'internet';
                        }
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        if (found != null) {
                          setS(() => imageUrl = found);
                          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                            content: Text('Görsel bulundu ($source)'),
                            backgroundColor: const Color(0xFF16A34A),
                            behavior: SnackBarBehavior.floating,
                            duration: const Duration(seconds: 4),
                          ));
                        } else {
                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                            content: Text('Görsel bulunamadı'),
                            backgroundColor: Colors.orange,
                            behavior: SnackBarBehavior.floating,
                          ));
                        }
                      } catch (e) {
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Hata: $e'),
                          backgroundColor: Colors.red,
                          behavior: SnackBarBehavior.floating,
                        ));
                      } finally {
                        setS(() => searchingImage = false);
                      }
                    },
                    icon: searchingImage
                        ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.image_search, size: 18),
                    label: Text(searchingImage ? 'Aranıyor...' : 'Ürün Fotoğrafı Ara'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF2563EB),
                      side: const BorderSide(color: Color(0xFF2563EB)),
                      padding: const EdgeInsets.symmetric(vertical: 10),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                TextField(
                  controller: prodCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Ürün Adı',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.inventory_2_outlined),
                  ),
                ),
                const SizedBox(height: 12),

                DropdownButtonFormField<String>(
                  value: marketsSnap.docs.any((d) => d.id == marketId) ? marketId : null,
                  decoration: const InputDecoration(
                    labelText: 'Market',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.store_outlined),
                  ),
                  hint: const Text('Market seçin'),
                  items: marketsSnap.docs.map((d) =>
                    DropdownMenuItem(value: d.id, child: Text(d.get('name') as String))
                  ).toList(),
                  onChanged: (id) {
                    if (id == null) return;
                    setS(() {
                      marketId   = id;
                      marketName = marketsSnap.docs.firstWhere((d) => d.id == id).get('name') as String;
                    });
                  },
                ),
                const SizedBox(height: 12),

                DropdownButtonFormField<String>(
                  value: catsSnap.docs.any((d) => d.id == categoryId) ? categoryId : null,
                  decoration: const InputDecoration(
                    labelText: 'Kategori',
                    border: OutlineInputBorder(),
                    prefixIcon: Icon(Icons.category_outlined),
                  ),
                  hint: const Text('Kategori seçin'),
                  items: catsSnap.docs.map((d) {
                    final data    = d.data() as Map<String, dynamic>;
                    final iconUrl = data['iconUrl'] as String?;
                    final icon    = data['icon'] as String? ?? '';
                    final name    = data['name'] as String? ?? '';
                    return DropdownMenuItem(
                      value: d.id,
                      child: Row(children: [
                        SizedBox(
                          width: 28, height: 28,
                          child: (iconUrl != null && iconUrl.isNotEmpty)
                              ? ClipOval(child: Image.network(iconUrl, width: 28, height: 28, fit: BoxFit.cover,
                                  errorBuilder: (_, __, ___) => icon.isNotEmpty
                                      ? Text(icon, style: const TextStyle(fontSize: 18))
                                      : const Icon(Icons.category, size: 20, color: Color(0xFF16A34A))))
                              : icon.isNotEmpty
                                  ? Text(icon, style: const TextStyle(fontSize: 18))
                                  : const Icon(Icons.category, size: 20, color: Color(0xFF16A34A)),
                        ),
                        const SizedBox(width: 8),
                        Text(name),
                      ]),
                    );
                  }).toList(),
                  onChanged: (id) {
                    if (id == null) return;
                    setS(() {
                      categoryId   = id;
                      categoryName = catsSnap.docs.firstWhere((d) => d.id == id).get('name') as String;
                    });
                  },
                ),
                const SizedBox(height: 12),

                const Text('Kampanya Şekli',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey)),
                const SizedBox(height: 8),
                ...[
                  _editTypeCard(setS, 'priceDiscount', '💰', 'Fiyat İndirimi', 'Eski fiyat → Yeni fiyat', campaignType, (t) { campaignType = t; }),
                  const SizedBox(height: 6),
                  _editTypeCard(setS, 'buyOneGetOne', '🎁', '1 Alana 1 Bedava', 'Aynı üründen 2. adet ücretsiz', campaignType, (t) { campaignType = t; }),
                  const SizedBox(height: 6),
                  _editTypeCard(setS, 'secondDiscount', '🏷️', '1 Alana İkincisi İndirimli', '2. üründe %X indirim', campaignType, (t) { campaignType = t; }),
                ],
                const SizedBox(height: 12),

                if (campaignType == 'priceDiscount') ...[
                  Row(children: [
                    Expanded(
                      child: TextField(
                        controller: origCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                        decoration: const InputDecoration(labelText: 'Eski Fiyat', border: OutlineInputBorder(), suffixText: 'TL'),
                      ),
                    ),
                    const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Icon(Icons.arrow_forward, color: Colors.grey)),
                    Expanded(
                      child: TextField(
                        controller: discCtrl,
                        keyboardType: const TextInputType.numberWithOptions(decimal: true),
                        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                        decoration: const InputDecoration(labelText: 'Yeni Fiyat', border: OutlineInputBorder(), suffixText: 'TL'),
                      ),
                    ),
                  ]),
                  const SizedBox(height: 12),
                ],
                if (campaignType == 'buyOneGetOne') ...[
                  TextField(
                    controller: prodPriceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                    decoration: const InputDecoration(
                      labelText: 'Ürün Fiyatı (opsiyonel)', border: OutlineInputBorder(), suffixText: 'TL',
                      prefixIcon: Icon(Icons.sell_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (campaignType == 'secondDiscount') ...[
                  TextField(
                    controller: discRateCtrl,
                    keyboardType: TextInputType.number,
                    inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                    decoration: const InputDecoration(
                      labelText: '2. Ürün İndirim Oranı', border: OutlineInputBorder(), suffixText: '%',
                      prefixIcon: Icon(Icons.percent),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: prodPriceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                    decoration: const InputDecoration(
                      labelText: 'Ürün Fiyatı (opsiyonel)', border: OutlineInputBorder(), suffixText: 'TL',
                      prefixIcon: Icon(Icons.sell_outlined),
                    ),
                  ),
                  const SizedBox(height: 12),
                ],

                InkWell(
                  onTap: () async {
                    final picked = await showDateRangePicker(
                      context: ctx,
                      initialDateRange: (startDate != null && endDate != null)
                          ? DateTimeRange(start: startDate!, end: endDate!)
                          : null,
                      firstDate: DateTime.now().subtract(const Duration(days: 60)),
                      lastDate: DateTime.now().add(const Duration(days: 365)),
                      locale: const Locale('tr', 'TR'),
                      builder: (context, child) => Theme(
                        data: Theme.of(context).copyWith(
                          colorScheme: const ColorScheme.light(primary: Color(0xFF2563EB)),
                        ),
                        child: child!,
                      ),
                    );
                    if (picked != null) setS(() { startDate = picked.start; endDate = picked.end; });
                  },
                  borderRadius: BorderRadius.circular(4),
                  child: InputDecorator(
                    decoration: const InputDecoration(labelText: 'Tarih Aralığı', border: OutlineInputBorder(), suffixIcon: Icon(Icons.date_range)),
                    child: Text(
                      (startDate != null && endDate != null)
                          ? '${_dateFormat.format(startDate!)}  →  ${_dateFormat.format(endDate!)}'
                          : 'Tarih seçin',
                      style: TextStyle(color: startDate != null ? Colors.black87 : Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      draft.productName    = prodCtrl.text.trim();
                      draft.marketId       = marketId;
                      draft.marketName     = marketName;
                      draft.categoryId     = categoryId;
                      draft.categoryName   = categoryName;
                      draft.campaignType   = campaignType;
                      draft.startDate      = startDate;
                      draft.endDate        = endDate;
                      draft.productImageUrl = imageUrl;
                      if (campaignType == 'priceDiscount') {
                        draft.originalPrice   = double.tryParse(origCtrl.text.trim());
                        draft.discountedPrice = double.tryParse(discCtrl.text.trim());
                        draft.discountRate    = null;
                        draft.productPrice    = null;
                      } else if (campaignType == 'buyOneGetOne') {
                        draft.originalPrice   = null;
                        draft.discountedPrice = null;
                        draft.discountRate    = null;
                        draft.productPrice    = double.tryParse(prodPriceCtrl.text.trim());
                      } else if (campaignType == 'secondDiscount') {
                        draft.originalPrice   = null;
                        draft.discountedPrice = null;
                        draft.discountRate    = int.tryParse(discRateCtrl.text.trim());
                        draft.productPrice    = double.tryParse(prodPriceCtrl.text.trim());
                      }
                      Navigator.pop(ctx);
                      onSaved?.call();
                      setState(() {});
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                    child: const Text('Güncelle'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Save drafts
  // -----------------------------------------------------------------------

  Future<void> _saveDrafts() async {
    final selected = _aiItems.where((i) => i.selected).toList();
    if (selected.isEmpty) return;
    final col = FirebaseFirestore.instance.collection('catalog_drafts');
    int saved = 0;
    for (final item in selected) {
      try { await col.add(item.toFirestore()); saved++; } catch (_) {}
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$saved ürün taslak olarak kaydedildi.'),
        backgroundColor: const Color(0xFF16A34A),
        behavior: SnackBarBehavior.floating,
        margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
      ));
      setState(() {
        _aiItems.removeWhere((i) => i.selected);
        if (_aiItems.isEmpty) { _pickedImage = null; _analyzeError = null; }
      });
      _tabController.animateTo(1);
    }
  }

  // -----------------------------------------------------------------------
  // Publish drafts
  // -----------------------------------------------------------------------

  Future<void> _publishSelected() async {
    if (_selectedDraftIds.isEmpty) return;
    final draftsCol   = FirebaseFirestore.instance.collection('catalog_drafts');
    final marketsSnap = await FirebaseFirestore.instance.collection('markets').get();
    final catsSnap    = await FirebaseFirestore.instance.collection('categories').get();

    String normMkt(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s.\-_]'), '');
    const marketAliases = <String, String>{
      'money': 'migros', 'moneymigros': 'migros', 'carrfour': 'carrefour',
      'carrefoursa': 'carrefour', 'sok': 'şok', 'sokmarket': 'şok',
      'a101': 'a-101', 'bimeks': 'bim',
    };

    String resolveMarketId(String id, String name) {
      if (id.isNotEmpty) return id;
      try {
        final norm = normMkt(name);
        final aliasNorm = marketAliases[norm] ?? norm;
        final match = marketsSnap.docs.firstWhere(
          (d) {
            final dbNorm = normMkt(d.get('name') as String);
            return dbNorm == aliasNorm || dbNorm == norm ||
                   (d.get('name') as String).toLowerCase().contains(aliasNorm);
          },
          orElse: () => throw StateError(''),
        );
        return match.id;
      } catch (_) { return ''; }
    }

    String resolveMarketName(String id, String name) {
      if (id.isNotEmpty) return (marketsSnap.docs.where((d) => d.id == id).firstOrNull?.get('name') as String?) ?? name;
      try {
        final norm = normMkt(name);
        final aliasNorm = marketAliases[norm] ?? norm;
        final match = marketsSnap.docs.firstWhere(
          (d) {
            final dbNorm = normMkt(d.get('name') as String);
            return dbNorm == aliasNorm || dbNorm == norm ||
                   (d.get('name') as String).toLowerCase().contains(aliasNorm);
          },
          orElse: () => throw StateError(''),
        );
        return match.get('name') as String;
      } catch (_) { return name; }
    }

    String resolveCategoryId(String id, String name) {
      if (id.isNotEmpty) return id;
      return catsSnap.docs.where((d) => (d.get('name') as String).toLowerCase() == name.toLowerCase()).firstOrNull?.id ?? '';
    }
    String resolveCategoryName(String id, String name) {
      if (id.isNotEmpty) return (catsSnap.docs.where((d) => d.id == id).firstOrNull?.get('name') as String?) ?? name;
      return (catsSnap.docs.where((d) => (d.get('name') as String).toLowerCase() == name.toLowerCase()).firstOrNull?.get('name') as String?) ?? name;
    }

    final List<String> eksikler = [];
    for (final id in _selectedDraftIds) {
      final doc = await draftsCol.doc(id).get();
      if (!doc.exists) continue;
      final data = doc.data()!;
      final product    = (data['productName'] as String? ?? '').trim();
      final marketId   = resolveMarketId((data['marketId'] as String? ?? '').trim(), (data['marketName'] as String? ?? '').trim());
      final categoryId = resolveCategoryId((data['categoryId'] as String? ?? '').trim(), (data['categoryName'] as String? ?? '').trim());
      final startDate  = data['startDate'] as Timestamp?;
      final endDate    = data['endDate'] as Timestamp?;
      final missingFields = <String>[];
      if (product.isEmpty) missingFields.add('ürün adı');
      if (marketId.isEmpty) missingFields.add('market');
      if (categoryId.isEmpty) missingFields.add('kategori');
      if (startDate == null || endDate == null) missingFields.add('tarih');
      if (missingFields.isNotEmpty) {
        final label = product.isNotEmpty ? product : '(isimsiz ürün)';
        eksikler.add('$label → ${missingFields.join(', ')}');
      }
    }

    if (eksikler.isNotEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Eksik alan var:\n${eksikler.join('\n')}'),
          backgroundColor: Colors.orange.shade700,
          duration: const Duration(seconds: 6),
        ));
      }
      return;
    }

    setState(() => _publishing = true);
    final campaignsCol   = FirebaseFirestore.instance.collection('campaigns');
    int published        = 0;
    final duplicateNames = <String>[];

    for (final id in _selectedDraftIds.toList()) {
      try {
        final draftDoc = await draftsCol.doc(id).get();
        if (!draftDoc.exists) continue;
        final data = draftDoc.data()!;

        final campaignType = (data['campaignType'] as String? ?? 'priceDiscount');
        final oldPrice     = (data['originalPrice'] as num?)?.toDouble() ?? 0;
        final newPrice     = (data['discountedPrice'] as num?)?.toDouble() ?? 0;
        final productPrice = (data['productPrice'] as num?)?.toDouble() ?? 0;
        final discountRate = (data['discountRate'] as num?)?.toInt() ?? 0;
        final productName  = data['productName'] as String? ?? '';

        final mId   = resolveMarketId((data['marketId'] as String? ?? '').trim(), (data['marketName'] as String? ?? '').trim());
        final mName = resolveMarketName((data['marketId'] as String? ?? '').trim(), (data['marketName'] as String? ?? '').trim());
        final cId   = resolveCategoryId((data['categoryId'] as String? ?? '').trim(), (data['categoryName'] as String? ?? '').trim());
        final cName = resolveCategoryName((data['categoryId'] as String? ?? '').trim(), (data['categoryName'] as String? ?? '').trim());

        String autoTitle;
        if (campaignType == 'buyOneGetOne') {
          autoTitle = productName.isNotEmpty ? '$productName - 1 Alana 1 Bedava' : '1 Alana 1 Bedava';
        } else if (campaignType == 'secondDiscount') {
          autoTitle = productName.isNotEmpty ? '$productName - 1 Alana İkincisi %$discountRate İndirimli' : '1 Alana İkincisi %$discountRate İndirimli';
        } else {
          autoTitle = productName.isNotEmpty ? '$productName - ${oldPrice.toStringAsFixed(2)} TL yerine ${newPrice.toStringAsFixed(2)} TL' : 'Fiyat İndirimi';
        }

        final campaignData = <String, dynamic>{
          'product':         productName,
          'title':           autoTitle,
          'description':     data['description'] ?? '',
          'campaignType':    campaignType,
          'marketId':        mId,
          'marketName':      mName,
          'categoryId':      cId,
          'categoryName':    cName,
          'startDate':       data['startDate'],
          'endDate':         data['endDate'],
          'productImageUrl': data['productImageUrl'] ?? '',
          'createdAt':       FieldValue.serverTimestamp(),
        };
        if (campaignType == 'priceDiscount') {
          campaignData['oldPrice'] = oldPrice;
          campaignData['newPrice'] = newPrice > 0 ? newPrice : oldPrice;
        } else if (campaignType == 'buyOneGetOne') {
          campaignData['productPrice'] = productPrice;
        } else if (campaignType == 'secondDiscount') {
          campaignData['discountRate'] = discountRate;
          campaignData['productPrice'] = productPrice;
        }

        final endDate = data['endDate'];
        if (productName.isNotEmpty && mId.isNotEmpty && endDate != null) {
          final existing = await campaignsCol
              .where('product', isEqualTo: productName)
              .where('marketId', isEqualTo: mId)
              .where('endDate', isEqualTo: endDate)
              .limit(1).get();
          if (existing.docs.isNotEmpty) { duplicateNames.add(productName); continue; }
        }

        await campaignsCol.add(campaignData);
        await draftsCol.doc(id).delete();
        published++;
      } catch (_) {}
    }

    setState(() { _publishing = false; _selectedDraftIds.clear(); });

    if (mounted) {
      showDialog(
        context: context,
        barrierDismissible: true,
        builder: (_) {
          Future.delayed(const Duration(seconds: 2), () {
            if (Navigator.of(context, rootNavigator: true).canPop()) {
              Navigator.of(context, rootNavigator: true).pop();
            }
          });
          return AlertDialog(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
            content: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(Icons.check_circle_rounded, color: Color(0xFF16A34A), size: 32),
                const SizedBox(width: 12),
                Flexible(
                  child: Text(
                    duplicateNames.isNotEmpty
                        ? '$published kampanya yayınlandı.\n\nBu kampanyalar zaten mevcut:\n${duplicateNames.map((n) => '• $n').join('\n')}'
                        : '$published kampanya yayınlandı!',
                    style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          );
        },
      );
    }
  }

  Future<void> _confirmDeleteAllDrafts(List<QueryDocumentSnapshot> docs) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tümünü Sil'),
        content: Text('${docs.length} taslağı silmek istiyor musunuz?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('İptal')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('Sil'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    final col = FirebaseFirestore.instance.collection('catalog_drafts');
    for (final doc in docs) {
      await col.doc(doc.id).delete();
    }
  }

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('ML Kit OCR Katalog'),
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _showSettingsDialog,
            tooltip: 'Ayarlar',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: [
            const Tab(text: 'Analiz', icon: Icon(Icons.document_scanner_outlined, size: 18)),
            StreamBuilder<QuerySnapshot>(
              stream: FirebaseFirestore.instance
                  .collection('catalog_drafts')
                  .where('status', isEqualTo: 'draft')
                  .snapshots(),
              builder: (_, snap) {
                final count = snap.data?.docs.length ?? 0;
                return Tab(
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    const Icon(Icons.pending_actions_outlined, size: 18),
                    const SizedBox(width: 6),
                    const Text('Taslaklar'),
                    if (count > 0) ...[
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(color: Colors.white, borderRadius: BorderRadius.circular(10)),
                        child: Text('$count',
                            style: const TextStyle(fontSize: 10, color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
                      ),
                    ],
                  ]),
                );
              },
            ),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _buildAnalizTab(),
          _buildTaslakTab(),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Tab 1: Analiz
  // -----------------------------------------------------------------------

  Widget _buildAnalizTab() {
    final selectedCount = _aiItems.where((i) => i.selected).length;

    return Stack(
      children: [
        CustomScrollView(
          slivers: [
            SliverToBoxAdapter(
              child: GestureDetector(
                onTap: _pickFile,
                child: Container(
                  height: 150,
                  margin: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEFF6FF),
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFF2563EB).withOpacity(0.35), width: 1.5),
                  ),
                  child: _pickedImage != null
                      ? Stack(fit: StackFit.expand, children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(11),
                            child: Image.file(File(_pickedImage!.path), fit: BoxFit.contain),
                          ),
                          Positioned(
                            top: 8, right: 8,
                            child: GestureDetector(
                              onTap: _pickFile,
                              child: Container(
                                padding: const EdgeInsets.all(6),
                                decoration: const BoxDecoration(color: Color(0xFF2563EB), shape: BoxShape.circle),
                                child: const Icon(Icons.edit, color: Colors.white, size: 16),
                              ),
                            ),
                          ),
                        ])
                      : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                          Icon(Icons.add_photo_alternate_outlined, size: 44, color: Color(0xFF2563EB)),
                          SizedBox(height: 8),
                          Text('Katalog / Broşür Fotoğrafı Yükle',
                              style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.w600)),
                          SizedBox(height: 4),
                          Text('📱 Tamamen cihaz içinde — internet gerekmez',
                              style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.w500)),
                        ]),
                ),
              ),
            ),

            if (_pickedImage != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: ElevatedButton.icon(
                    onPressed: _analyzing ? null : _analyze,
                    icon: _analyzing
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.document_scanner),
                    label: Text(_analyzing ? (_analyzeStatus ?? 'Analiz ediliyor...') : 'OCR ile Analiz Et'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF2563EB),
                      foregroundColor: Colors.white,
                      minimumSize: const Size(double.infinity, 48),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
                    ),
                  ),
                ),
              ),

            if (_analyzeError != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.red.shade50,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.red.shade200),
                    ),
                    child: Row(children: [
                      const Icon(Icons.error_outline, color: Colors.red, size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_analyzeError!, style: const TextStyle(color: Colors.red, fontSize: 13))),
                    ]),
                  ),
                ),
              ),

            if (_ocrRawText != null && _aiItems.isEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: ExpansionTile(
                    title: Text('Ham OCR Metni (${_ocrRawText!.split('\n').length} satır)',
                        style: const TextStyle(fontSize: 13, color: Colors.grey)),
                    children: [
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: Colors.grey.shade50,
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.grey.shade200),
                        ),
                        child: Text(_ocrRawText!, style: const TextStyle(fontSize: 11, fontFamily: 'monospace')),
                      ),
                    ],
                  ),
                ),
              ),

            if (_aiItems.isNotEmpty)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(children: [
                    Text('${_aiItems.length} ürün bulundu',
                        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    const Spacer(),
                    TextButton(
                      onPressed: () => setState(() {
                        final all = _aiItems.every((i) => i.selected);
                        for (final i in _aiItems) i.selected = !all;
                      }),
                      child: Text(_aiItems.every((i) => i.selected) ? 'Tümünü Kaldır' : 'Tümünü Seç',
                          style: const TextStyle(fontSize: 12)),
                    ),
                  ]),
                ),
              ),

            if (_aiItems.isNotEmpty)
              SliverList(
                delegate: SliverChildBuilderDelegate(
                  (ctx, i) {
                    if (i == _aiItems.length) return const SizedBox(height: 80);
                    return _buildAiItemCard(_aiItems[i]);
                  },
                  childCount: _aiItems.length + 1,
                ),
              ),

            if (_aiItems.isEmpty && !_analyzing && _pickedImage == null)
              SliverFillRemaining(
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.phone_android_outlined, size: 72, color: Colors.grey.shade200),
                    const SizedBox(height: 12),
                    Text('Broşür fotoğrafı yükleyip analiz edin',
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text('ML Kit OCR → Gemini ile ürünler listelenir',
                        style: TextStyle(color: Colors.grey.shade300, fontSize: 13)),
                    const SizedBox(height: 4),
                    const Text('📱 Tamamen cihaz içinde çalışır',
                        style: TextStyle(color: Colors.green, fontSize: 12, fontWeight: FontWeight.w500)),
                  ]),
                ),
              ),
          ],
        ),

        if (selectedCount > 0)
          Positioned(
            bottom: 16, left: 16, right: 16,
            child: ElevatedButton.icon(
              onPressed: _saveDrafts,
              icon: const Icon(Icons.save_outlined),
              label: Text('$selectedCount Ürünü Taslak Olarak Kaydet'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF16A34A),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                elevation: 4,
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildAiItemCard(CatalogDraft item) {
    final hasDiscount = item.originalPrice != null && item.discountedPrice != null &&
        item.originalPrice! > 0 && item.discountedPrice! < item.originalPrice!;
    final pct = hasDiscount
        ? ((item.originalPrice! - item.discountedPrice!) / item.originalPrice! * 100).round()
        : 0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: item.selected ? const Color(0xFFEFF6FF) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: item.selected ? const Color(0xFF2563EB) : Colors.grey.shade200,
            width: item.selected ? 1.5 : 1,
          ),
        ),
        child: InkWell(
          onTap: () => setState(() => item.selected = !item.selected),
          borderRadius: BorderRadius.circular(10),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: item.selected,
                      onChanged: (v) => setState(() => item.selected = v ?? false),
                      activeColor: const Color(0xFF2563EB),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(children: [
                            if (item.marketName.isNotEmpty) ...[
                              _badge(item.marketName, const Color(0xFF2563EB)),
                              const SizedBox(width: 4),
                            ],
                            if (item.categoryName.isNotEmpty) ...[
                              _badge(item.categoryName, Colors.purple),
                              const SizedBox(width: 4),
                            ],
                            if (hasDiscount) _badge('🔥 %$pct', Colors.deepOrange),
                          ]),
                          const SizedBox(height: 5),
                          Text(item.productName,
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          const SizedBox(height: 4),
                          Row(children: [
                            if (item.originalPrice != null)
                              Text('${_priceFmt.format(item.originalPrice)} TL',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: hasDiscount ? Colors.grey : Colors.black87,
                                    decoration: hasDiscount ? TextDecoration.lineThrough : null,
                                  )),
                            if (hasDiscount) ...[
                              const SizedBox(width: 6),
                              Text('${_priceFmt.format(item.discountedPrice)} TL',
                                  style: const TextStyle(fontSize: 13, color: Colors.deepOrange, fontWeight: FontWeight.bold)),
                            ],
                            if (!hasDiscount && item.discountedPrice != null && item.originalPrice == null)
                              Text('${_priceFmt.format(item.discountedPrice)} TL',
                                  style: const TextStyle(fontSize: 13, color: Colors.deepOrange, fontWeight: FontWeight.bold)),
                            const Spacer(),
                            if (item.startDate != null && item.endDate != null)
                              Text('${_dateFormat.format(item.startDate!)} - ${_dateFormat.format(item.endDate!)}',
                                  style: const TextStyle(fontSize: 11, color: Colors.grey)),
                          ]),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF2563EB)),
                      onPressed: () => _showEditSheet(item),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                      onPressed: () => setState(() => _aiItems.remove(item)),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                  ],
                ),
                if (item.productImageUrl != null && item.productImageUrl!.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Image.network(
                      item.productImageUrl!,
                      height: 100,
                      width: double.infinity,
                      fit: BoxFit.contain,
                      loadingBuilder: (_, child, progress) => progress == null
                          ? child
                          : const SizedBox(height: 100, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                      errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _badge(String text, Color color) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
    decoration: BoxDecoration(
      color: color.withOpacity(0.1),
      borderRadius: BorderRadius.circular(6),
      border: Border.all(color: color.withOpacity(0.3)),
    ),
    child: Text(text, style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
  );

  // -----------------------------------------------------------------------
  // Tab 2: Taslaklar
  // -----------------------------------------------------------------------

  Widget _buildTaslakTab() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance
          .collection('catalog_drafts')
          .where('status', isEqualTo: 'draft')
          .snapshots(),
      builder: (context, snap) {
        if (snap.hasError) return Center(child: Text('Hata: ${snap.error}', style: const TextStyle(color: Colors.red)));
        if (!snap.hasData) return const Center(child: CircularProgressIndicator());

        final docs = snap.data!.docs.toList()
          ..sort((a, b) {
            final aTs = (a.data() as Map<String, dynamic>)['createdAt'] as Timestamp?;
            final bTs = (b.data() as Map<String, dynamic>)['createdAt'] as Timestamp?;
            if (aTs == null && bTs == null) return 0;
            if (aTs == null) return 1;
            if (bTs == null) return -1;
            return bTs.compareTo(aTs);
          });

        if (docs.isEmpty) {
          return Center(
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              Icon(Icons.pending_actions_outlined, size: 72, color: Colors.grey.shade200),
              const SizedBox(height: 12),
              Text('Kayıtlı taslak yok', style: TextStyle(color: Colors.grey.shade400, fontSize: 15)),
              const SizedBox(height: 4),
              Text('Analiz ekranından taslak kaydedin', style: TextStyle(color: Colors.grey.shade300, fontSize: 13)),
            ]),
          );
        }

        return Stack(
          children: [
            CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
                    child: Row(children: [
                      Text('${docs.length} taslak', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                      const Spacer(),
                      TextButton(
                        onPressed: () => setState(() {
                          if (_selectedDraftIds.length == docs.length) {
                            _selectedDraftIds.clear();
                          } else {
                            _selectedDraftIds.addAll(docs.map((d) => d.id));
                          }
                        }),
                        child: Text(
                          _selectedDraftIds.length == docs.length ? 'Tümünü Kaldır' : 'Tümünü Seç',
                          style: const TextStyle(fontSize: 12),
                        ),
                      ),
                      TextButton.icon(
                        onPressed: () => _confirmDeleteAllDrafts(docs),
                        icon: const Icon(Icons.delete_sweep_outlined, size: 16, color: Colors.red),
                        label: const Text('Tümünü Sil', style: TextStyle(fontSize: 12, color: Colors.red)),
                        style: TextButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 8)),
                      ),
                    ]),
                  ),
                ),

                SliverToBoxAdapter(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                    child: Card(
                      color: const Color(0xFFF0F9FF),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                        side: BorderSide(color: const Color(0xFF2563EB).withOpacity(0.25)),
                      ),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            const Text('Kampanya Tarih Girişi',
                                style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13)),
                            const SizedBox(height: 2),
                            Text('Tüm taslakların tarihlerini toplu günceller',
                                style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                            const SizedBox(height: 10),
                            Row(children: [
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.calendar_today_outlined, size: 15),
                                  label: Text(
                                    _bulkStartDate != null ? _dateFormat.format(_bulkStartDate!) : 'Başlangıç',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  onPressed: () async {
                                    final d = await showDatePicker(
                                      context: context,
                                      initialDate: _bulkStartDate ?? DateTime.now(),
                                      firstDate: DateTime(2020), lastDate: DateTime(2030),
                                      locale: const Locale('tr', 'TR'),
                                    );
                                    if (d != null) setState(() => _bulkStartDate = d);
                                  },
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                                    side: BorderSide(color: _bulkStartDate != null ? const Color(0xFF2563EB) : Colors.grey.shade400),
                                  ),
                                ),
                              ),
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 6),
                                child: Text('–', style: TextStyle(fontWeight: FontWeight.bold)),
                              ),
                              Expanded(
                                child: OutlinedButton.icon(
                                  icon: const Icon(Icons.calendar_today_outlined, size: 15),
                                  label: Text(
                                    _bulkEndDate != null ? _dateFormat.format(_bulkEndDate!) : 'Bitiş',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  onPressed: () async {
                                    final d = await showDatePicker(
                                      context: context,
                                      initialDate: _bulkEndDate ?? _bulkStartDate ?? DateTime.now(),
                                      firstDate: DateTime(2020), lastDate: DateTime(2030),
                                      locale: const Locale('tr', 'TR'),
                                    );
                                    if (d != null) setState(() => _bulkEndDate = d);
                                  },
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                                    side: BorderSide(color: _bulkEndDate != null ? const Color(0xFF2563EB) : Colors.grey.shade400),
                                  ),
                                ),
                              ),
                            ]),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              child: ElevatedButton(
                                onPressed: (_bulkStartDate == null || _bulkEndDate == null || _applyingBulkDates)
                                    ? null
                                    : () async {
                                        setState(() => _applyingBulkDates = true);
                                        final col = FirebaseFirestore.instance.collection('catalog_drafts');
                                        for (final doc in docs) {
                                          await col.doc(doc.id).update({
                                            'startDate': Timestamp.fromDate(_bulkStartDate!),
                                            'endDate':   Timestamp.fromDate(_bulkEndDate!),
                                          });
                                        }
                                        setState(() => _applyingBulkDates = false);
                                        if (mounted) {
                                          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                                            content: Text('Tarihler güncellendi.'),
                                            backgroundColor: Color(0xFF16A34A),
                                            behavior: SnackBarBehavior.floating,
                                          ));
                                        }
                                      },
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: const Color(0xFF2563EB),
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(vertical: 10),
                                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                ),
                                child: _applyingBulkDates
                                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                    : const Text('Tarihleri Uygula', style: TextStyle(fontSize: 13)),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),

                SliverList(
                  delegate: SliverChildBuilderDelegate(
                    (ctx, i) {
                      if (i == docs.length) return const SizedBox(height: 80);
                      final doc  = docs[i];
                      final data = doc.data() as Map<String, dynamic>;
                      final isSelected = _selectedDraftIds.contains(doc.id);
                      final product    = data['productName'] as String? ?? '(isimsiz)';
                      final market     = data['marketName']  as String? ?? '';
                      final category   = data['categoryName'] as String? ?? '';
                      final imageUrl   = data['productImageUrl'] as String? ?? '';
                      final startDate  = (data['startDate'] as Timestamp?)?.toDate();
                      final endDate    = (data['endDate']   as Timestamp?)?.toDate();
                      final type       = data['campaignType'] as String? ?? '';
                      final oldP       = (data['originalPrice'] as num?)?.toDouble();
                      final newP       = (data['discountedPrice'] as num?)?.toDouble();

                      return Padding(
                        padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 120),
                          decoration: BoxDecoration(
                            color: isSelected ? const Color(0xFFEFF6FF) : Colors.white,
                            borderRadius: BorderRadius.circular(10),
                            border: Border.all(
                              color: isSelected ? const Color(0xFF2563EB) : Colors.grey.shade200,
                              width: isSelected ? 1.5 : 1,
                            ),
                          ),
                          child: InkWell(
                            onTap: () => setState(() {
                              if (isSelected) _selectedDraftIds.remove(doc.id);
                              else _selectedDraftIds.add(doc.id);
                            }),
                            borderRadius: BorderRadius.circular(10),
                            child: Padding(
                              padding: const EdgeInsets.fromLTRB(8, 10, 8, 10),
                              child: Row(
                                children: [
                                  Checkbox(
                                    value: isSelected,
                                    onChanged: (v) => setState(() {
                                      if (v == true) _selectedDraftIds.add(doc.id);
                                      else _selectedDraftIds.remove(doc.id);
                                    }),
                                    activeColor: const Color(0xFF2563EB),
                                    materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                                    visualDensity: VisualDensity.compact,
                                  ),
                                  if (imageUrl.isNotEmpty) ...[
                                    const SizedBox(width: 4),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
                                      child: Image.network(imageUrl, width: 40, height: 40, fit: BoxFit.cover,
                                          errorBuilder: (_, __, ___) => const SizedBox(width: 40, height: 40)),
                                    ),
                                  ],
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(children: [
                                          if (market.isNotEmpty) ...[_badge(market, const Color(0xFF2563EB)), const SizedBox(width: 4)],
                                          if (category.isNotEmpty) _badge(category, Colors.purple),
                                        ]),
                                        const SizedBox(height: 3),
                                        Text(product, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                                        const SizedBox(height: 3),
                                        if (type == 'priceDiscount' && oldP != null && newP != null)
                                          Text('${_priceFmt.format(oldP)} → ${_priceFmt.format(newP)} TL',
                                              style: const TextStyle(fontSize: 11, color: Colors.deepOrange))
                                        else if (type == 'buyOneGetOne')
                                          const Text('1 alana 1 bedava', style: TextStyle(fontSize: 11, color: Colors.deepOrange))
                                        else if (type == 'secondDiscount')
                                          Text('2. üründe %${data['discountRate'] ?? 0} indirim',
                                              style: const TextStyle(fontSize: 11, color: Colors.deepOrange)),
                                        if (startDate != null && endDate != null)
                                          Text('${_dateFormat.format(startDate)} – ${_dateFormat.format(endDate)}',
                                              style: const TextStyle(fontSize: 11, color: Colors.grey)),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF2563EB)),
                                    onPressed: () {
                                      final draft = CatalogDraft(
                                        productName:    data['productName'] as String? ?? '',
                                        marketId:       data['marketId']    as String? ?? '',
                                        marketName:     data['marketName']  as String? ?? '',
                                        categoryId:     data['categoryId']  as String? ?? '',
                                        categoryName:   data['categoryName'] as String? ?? '',
                                        campaignType:   data['campaignType'] as String? ?? 'priceDiscount',
                                        originalPrice:  (data['originalPrice'] as num?)?.toDouble(),
                                        discountedPrice:(data['discountedPrice'] as num?)?.toDouble(),
                                        discountRate:   (data['discountRate'] as num?)?.toInt(),
                                        productPrice:   (data['productPrice'] as num?)?.toDouble(),
                                        startDate:      (data['startDate'] as Timestamp?)?.toDate(),
                                        endDate:        (data['endDate']   as Timestamp?)?.toDate(),
                                        productImageUrl: data['productImageUrl'] as String?,
                                      );
                                      _showEditSheet(draft, onSaved: () async {
                                        await FirebaseFirestore.instance
                                            .collection('catalog_drafts')
                                            .doc(doc.id)
                                            .update(draft.toFirestore());
                                      });
                                    },
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                                    onPressed: () async {
                                      await FirebaseFirestore.instance.collection('catalog_drafts').doc(doc.id).delete();
                                      setState(() => _selectedDraftIds.remove(doc.id));
                                    },
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    childCount: docs.length + 1,
                  ),
                ),
              ],
            ),

            if (_selectedDraftIds.isNotEmpty)
              Positioned(
                bottom: 16, left: 16, right: 16,
                child: ElevatedButton.icon(
                  onPressed: _publishing ? null : _publishSelected,
                  icon: _publishing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.rocket_launch_outlined),
                  label: Text(_publishing
                      ? 'Yayınlanıyor...'
                      : '${_selectedDraftIds.length} Kampanyayı Yayınla'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF16A34A),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                    elevation: 4,
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
