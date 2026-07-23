import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:intl/intl.dart';
import 'katalog_giris_screen.dart' show CatalogDraft;

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------

class GeminiKatalogScreen extends StatefulWidget {
  const GeminiKatalogScreen({super.key});

  @override
  State<GeminiKatalogScreen> createState() => _GeminiKatalogScreenState();
}

class _GeminiKatalogScreenState extends State<GeminiKatalogScreen>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  // Analiz tab state
  XFile? _pickedImage;
  Uint8List? _pickedPdfBytes;
  String? _pickedPdfName;
  bool _analyzing = false;
  String? _analyzeStatus;
  List<CatalogDraft> _aiItems = [];
  String? _analyzeError;

  // Taslaklar tab state
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
    StateSetter setS,
    String type,
    String icon,
    String title,
    String subtitle,
    String currentType,
    void Function(String) onSelect,
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
        child: Row(
          children: [
            Text(icon, style: const TextStyle(fontSize: 20)),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: isSelected ? const Color(0xFF2563EB) : Colors.black87,
                      )),
                  Text(subtitle,
                      style: TextStyle(fontSize: 11, color: Colors.grey.shade600)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: Color(0xFF2563EB), size: 20),
          ],
        ),
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Settings
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
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: geminiCtrl,
                  obscureText: obscureG,
                  decoration: InputDecoration(
                    labelText: 'Gemini API Key',
                    border: const OutlineInputBorder(),
                    hintText: 'AIzaSy...',
                    helperText: 'Broşür analizi için (aistudio.google.com)',
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
                    helperText: 'console.cloud.google.com',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: googleCxCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Google Search Engine ID (cx)',
                    border: OutlineInputBorder(),
                    hintText: 'xxxxxxxxxxxxxxx',
                    helperText: 'programmablesearchengine.google.com',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
            ElevatedButton(
              onPressed: () async {
                await prefs.setString(_geminiKey,    geminiCtrl.text.trim());
                await prefs.setString(_googleApiKey, googleApiCtrl.text.trim());
                await prefs.setString(_googleCxKey,  googleCxCtrl.text.trim());
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
          ListTile(
            leading: const Icon(Icons.picture_as_pdf_outlined),
            title: const Text('PDF Belgesi Yükle'),
            onTap: () => Navigator.pop(ctx, 'pdf'),
          ),
        ]),
      ),
    );
    if (choice == null) return;
    if (choice == 'pdf') {
      await _pickPdf();
    } else {
      final src = choice == 'gallery' ? ImageSource.gallery : ImageSource.camera;
      final picked = await ImagePicker().pickImage(source: src, imageQuality: 60, maxWidth: 900);
      if (picked != null) {
        setState(() {
          _pickedImage = picked;
          _pickedPdfBytes = null;
          _pickedPdfName = null;
          _aiItems = [];
          _analyzeError = null;
        });
      }
    }
  }

  Future<void> _pickPdf() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['pdf'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    Uint8List? bytes = file.bytes;
    if (bytes == null && file.path != null) {
      bytes = await File(file.path!).readAsBytes();
    }
    if (bytes != null) {
      setState(() {
        _pickedPdfBytes = bytes;
        _pickedPdfName = file.name;
        _pickedImage = null;
        _aiItems = [];
        _analyzeError = null;
      });
    }
  }

  // -----------------------------------------------------------------------
  // Analyze — Gemini API
  // -----------------------------------------------------------------------

  Future<void> _analyze() async {
    if (_pickedImage == null && _pickedPdfBytes == null) return;

    String apiKey = '';
    try {
      final doc = await FirebaseFirestore.instance.collection('config').doc('gemini').get();
      apiKey = (doc.data()?['apiKey'] as String? ?? '').trim();
    } catch (_) {}
    if (apiKey.isEmpty) {
      final prefs = await SharedPreferences.getInstance();
      apiKey = prefs.getString(_geminiKey) ?? '';
    }
    if (apiKey.isEmpty) {
      _showSettingsDialog();
      return;
    }

    setState(() {
      _analyzing = true;
      _analyzeStatus = 'Analiz ediliyor...';
      _analyzeError = null;
      _aiItems = [];
    });

    try {
      final catsSnap = await FirebaseFirestore.instance.collection('categories').orderBy('name').get();
      final categoryNames = catsSnap.docs.map((d) => d.get('name') as String).join(', ');

      const prompt = '''Bu bir market indirim broşürü veya katalogu. İçerisindeki TÜM ürünleri analiz et.

SADECE aşağıdaki JSON formatında döndür, başka hiçbir metin ekleme:

{"items":[{"marketName":"ŞOK","productName":"Jacobs Filtre Kahve 250 g","categoryName":"Kahve & Çay","originalPrice":329.90,"discountedPrice":249.90,"startDate":"18.07.2026","endDate":"21.07.2026"}]}

Yukarıdaki örnek gibi: productName her zaman gramaj/miktar/hacim bilgisini içermelidir.

Mevcut kategoriler (SADECE bu listeden seç, birebir aynı yaz): CATEGORY_NAMES

Kurallar:
- categoryName alanı için mutlaka yukarıdaki listeden birini seç, ürünün içeriğine göre en mantıklısını seç
- Fiyatlar ondalık noktalı sayı (TL işareti yok), bulamazsan null
- Tarih bulamazsan null (string "null" değil, gerçek null)
- Tüm ürünleri dahil et, hiçbirini atlama
- productName alanında broşürde ne yazıyorsa HARFİYEN yaz, kesinlikle matematiksel işlem yapma (örnek: "2*90 gr" yazıyorsa "180 gr" değil "2*90 gr" yaz)
- productName içine gramaj, miktar, hacim bilgilerini mutlaka dahil et (örnek: "100 g", "500 ml", "1 kg", "2 lt", "3x90 gr", "6x250 ml" gibi ifadeler ürün adının ayrılmaz parçasıdır, atlama)
- Gramaj/miktar bilgisi ürün adının altında "•" veya ayrı satırda yazılmış olsa bile productName'e ekle (örnek: ürün adı "Jacobs Filtre Kahve", altında "• 250 g" yazıyorsa productName = "Jacobs Filtre Kahve 250 g")
- Adet bilgisi varsa onu da ekle (örnek: "6x250 ml", "25 li paket", "3'lü")''';

      final finalPrompt = prompt.replaceFirst('CATEGORY_NAMES', categoryNames);

      final String base64Data;
      final String mimeType;

      if (_pickedPdfBytes != null) {
        base64Data = base64Encode(_pickedPdfBytes!);
        mimeType = 'application/pdf';
      } else {
        final bytes = await File(_pickedImage!.path).readAsBytes();
        base64Data = base64Encode(bytes);
        final ext = _pickedImage!.name.split('.').last.toLowerCase();
        mimeType = ext == 'png' ? 'image/png' : ext == 'webp' ? 'image/webp' : 'image/jpeg';
      }

      final resp = await http.post(
        Uri.parse(
          'https://generativelanguage.googleapis.com/v1beta/models/gemini-3.1-flash-lite:generateContent?key=$apiKey',
        ),
        headers: {'content-type': 'application/json'},
        body: jsonEncode({
          'contents': [
            {
              'parts': [
                {
                  'inline_data': {
                    'mime_type': mimeType,
                    'data': base64Data,
                  }
                },
                {'text': finalPrompt},
              ]
            }
          ],
          'generationConfig': {
            'temperature': 0.1,
            'maxOutputTokens': 8192,
          },
        }),
      ).timeout(const Duration(seconds: 120));

      if (resp.statusCode == 200) {
        final body = jsonDecode(utf8.decode(resp.bodyBytes));
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
            setState(() => _analyzeError = 'Ürün bulunamadı. Görseli kontrol edin.');
          } else {
            await _fetchProductImages();
          }
        } else {
          setState(() => _analyzeError = 'Yanıt ayrıştırılamadı, tekrar deneyin.');
        }
      } else {
        String msg;
        try {
          final errBody = jsonDecode(resp.body);
          msg = (errBody['error']?['message'] as String?) ?? 'HTTP ${resp.statusCode}';
        } catch (_) {
          msg = 'HTTP ${resp.statusCode}';
        }
        setState(() => _analyzeError = 'API Hatası: $msg');
      }
    } on SocketException {
      setState(() => _analyzeError = 'İnternet bağlantısı yok.');
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
      // 1. Tam eşleşme
      final exactSnap = await FirebaseFirestore.instance
          .collection('campaigns')
          .where('product', isEqualTo: productName)
          .limit(5)
          .get();
      for (final doc in exactSnap.docs) {
        final url = (doc.data()['productImageUrl'] as String? ?? '').trim();
        if (url.isNotEmpty) return url;
      }

      // 2. Kelime örtüşme skoru (Jaccard ≥ 0.6)
      Set<String> _words(String s) => s
          .toLowerCase()
          .replaceAll(RegExp(r'[^\w\s]'), ' ')
          .split(RegExp(r'\s+'))
          .where((w) => w.length > 1)
          .toSet();

      final queryWords = _words(productName);
      if (queryWords.isEmpty) return null;

      final allSnap = await FirebaseFirestore.instance
          .collection('campaigns')
          .where('productImageUrl', isGreaterThan: '')
          .limit(300)
          .get();

      String? bestUrl;
      double bestScore = 0;

      for (final doc in allSnap.docs) {
        final data = doc.data();
        final candidate = (data['product'] as String? ?? '').trim();
        final url = (data['productImageUrl'] as String? ?? '').trim();
        if (url.isEmpty || candidate.isEmpty) continue;

        final candWords = _words(candidate);
        final intersection = queryWords.intersection(candWords).length;
        final union = queryWords.union(candWords).length;
        final score = union == 0 ? 0.0 : intersection / union;

        if (score > bestScore) {
          bestScore = score;
          bestUrl = url;
        }
      }

      if (bestScore >= 0.6) return bestUrl;
    } catch (_) {}
    return null;
  }

  Future<void> _fetchProductImages() async {
    int found = 0;
    int fromCache = 0;

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

  Future<String?> _searchImageDuckDuckGo(String query) async {
    try {
      final resp = await http.get(
        Uri.parse('https://europe-west1-indirim-takip-71bc8.cloudfunctions.net/searchImage?q=${Uri.encodeQueryComponent(query)}'),
      ).timeout(const Duration(seconds: 20));

      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        return body['url'] as String?;
      }
    } catch (e, s) {
      FirebaseFirestore.instance.collection('app_logs').add({
        'location':     'geminiImageSearch',
        'errorType':    e.runtimeType.toString(),
        'errorMessage': e.toString(),
        'stackSummary': s.toString().split('\n').take(4).join(' | '),
        'context':      query,
        'timestamp':    FieldValue.serverTimestamp(),
      });
    }
    return null;
  }

  // -----------------------------------------------------------------------
  // Edit bottom sheet
  // -----------------------------------------------------------------------

  Future<void> _showEditSheet(CatalogDraft draft, {VoidCallback? onSaved}) async {
    final prodCtrl = TextEditingController(text: draft.productName);
    final origCtrl = TextEditingController(
        text: draft.originalPrice != null ? draft.originalPrice!.toStringAsFixed(2) : '');
    final discCtrl = TextEditingController(
        text: draft.discountedPrice != null ? draft.discountedPrice!.toStringAsFixed(2) : '');
    final discRateCtrl = TextEditingController(
        text: draft.discountRate != null ? draft.discountRate.toString() : '');
    final prodPriceCtrl = TextEditingController(
        text: draft.productPrice != null ? draft.productPrice!.toStringAsFixed(2) : '');

    String campaignType = draft.campaignType;
    String marketId   = draft.marketId;
    String marketName = draft.marketName;
    String categoryId   = draft.categoryId;
    String categoryName = draft.categoryName;
    DateTime? startDate = draft.startDate;
    DateTime? endDate   = draft.endDate;
    String? imageUrl    = draft.productImageUrl;
    bool uploadingImage = false;
    bool searchingImage = false;

    final marketsSnap = await FirebaseFirestore.instance.collection('markets').orderBy('name').get();
    final catsSnap    = await FirebaseFirestore.instance.collection('categories').orderBy('name').get();

    if (marketId.isEmpty && marketName.isNotEmpty) {
      String normMkt(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s.\-_]'), '');
      const aliases = <String, String>{
        'money': 'migros', 'moneymigros': 'migros', 'carrfour': 'carrefour',
        'carrefoursa': 'carrefour', 'sok': 'şok', 'sokmarket': 'şok',
        'a101': 'a-101', 'bimeks': 'bim',
      };
      final norm = normMkt(marketName);
      final aliasNorm = aliases[norm] ?? norm;
      final match = marketsSnap.docs.where((d) {
        final dbNorm = normMkt(d.get('name') as String);
        return dbNorm == aliasNorm || dbNorm == norm ||
               (d.get('name') as String).toLowerCase().contains(aliasNorm);
      }).firstOrNull;
      if (match != null) {
        marketId   = match.id;
        marketName = match.get('name') as String;
      }
    }

    if (categoryId.isEmpty && categoryName.isNotEmpty) {
      final match = catsSnap.docs.where((d) =>
        (d.get('name') as String).toLowerCase() == categoryName.toLowerCase()
      ).firstOrNull;
      if (match != null) {
        categoryId   = match.id;
        categoryName = match.get('name') as String;
      }
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
                const Text('Ürün Düzenle',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                const SizedBox(height: 16),

                // Ürün fotoğrafı
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

                // Ürün Fotoğrafı Ara butonu
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
                        String? found;
                        String source = '';
                        found = await _searchImageInCampaigns(query);
                        if (found != null) {
                          source = 'kampanya koleksiyonu';
                        } else {
                          found = await _searchImageDuckDuckGo(query);
                          if (found != null) source = 'internet';
                        }
                        ScaffoldMessenger.of(context).hideCurrentSnackBar();
                        final String msg;
                        final Color msgColor;
                        if (found != null) {
                          setS(() => imageUrl = found);
                          msg = 'Görsel bulundu ($source)';
                          msgColor = const Color(0xFF16A34A);
                        } else {
                          msg = 'Görsel bulunamadı';
                          msgColor = Colors.orange;
                        }
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text(msg),
                          backgroundColor: msgColor,
                          behavior: SnackBarBehavior.floating,
                          duration: const Duration(seconds: 4),
                        ));
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
                        ? const SizedBox(width: 14, height: 14,
                            child: CircularProgressIndicator(strokeWidth: 2))
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
                      child: Row(
                        children: [
                          SizedBox(
                            width: 28, height: 28,
                            child: (iconUrl != null && iconUrl.isNotEmpty)
                                ? ClipOval(
                                    child: Image.network(iconUrl, width: 28, height: 28, fit: BoxFit.cover,
                                        errorBuilder: (_, __, ___) => icon.isNotEmpty
                                            ? Text(icon, style: const TextStyle(fontSize: 18))
                                            : const Icon(Icons.category, size: 20, color: Color(0xFF16A34A))),
                                  )
                                : icon.isNotEmpty
                                    ? Text(icon, style: const TextStyle(fontSize: 18))
                                    : const Icon(Icons.category, size: 20, color: Color(0xFF16A34A)),
                          ),
                          const SizedBox(width: 8),
                          Text(name),
                        ],
                      ),
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
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          controller: origCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                          decoration: const InputDecoration(
                            labelText: 'Eski Fiyat',
                            border: OutlineInputBorder(),
                            suffixText: 'TL',
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.arrow_forward, color: Colors.grey),
                      ),
                      Expanded(
                        child: TextField(
                          controller: discCtrl,
                          keyboardType: const TextInputType.numberWithOptions(decimal: true),
                          inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                          decoration: const InputDecoration(
                            labelText: 'Yeni Fiyat',
                            border: OutlineInputBorder(),
                            suffixText: 'TL',
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                if (campaignType == 'buyOneGetOne') ...[
                  TextField(
                    controller: prodPriceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                    decoration: const InputDecoration(
                      labelText: 'Ürün Fiyatı (opsiyonel)',
                      border: OutlineInputBorder(),
                      suffixText: 'TL',
                      prefixIcon: Icon(Icons.sell_outlined),
                      helperText: '2 adet toplam maliyet otomatik hesaplanır',
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
                      labelText: '2. Ürün İndirim Oranı',
                      border: OutlineInputBorder(),
                      suffixText: '%',
                      prefixIcon: Icon(Icons.percent),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: prodPriceCtrl,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.,]'))],
                    decoration: const InputDecoration(
                      labelText: 'Ürün Fiyatı (opsiyonel)',
                      border: OutlineInputBorder(),
                      suffixText: 'TL',
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
                    decoration: const InputDecoration(
                      labelText: 'Tarih Aralığı',
                      border: OutlineInputBorder(),
                      suffixIcon: Icon(Icons.date_range),
                    ),
                    child: Text(
                      (startDate != null && endDate != null)
                          ? '${_dateFormat.format(startDate!)}  →  ${_dateFormat.format(endDate!)}'
                          : 'Tarih seçin',
                      style: TextStyle(
                          color: startDate != null ? Colors.black87 : Colors.grey),
                    ),
                  ),
                ),
                const SizedBox(height: 20),

                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    onPressed: () {
                      draft.productName   = prodCtrl.text.trim();
                      draft.marketId      = marketId;
                      draft.marketName    = marketName;
                      draft.categoryId    = categoryId;
                      draft.categoryName  = categoryName;
                      draft.campaignType  = campaignType;
                      draft.startDate     = startDate;
                      draft.endDate       = endDate;
                      draft.productImageUrl = imageUrl;
                      if (campaignType == 'priceDiscount') {
                        draft.originalPrice  = double.tryParse(origCtrl.text.trim().replaceAll(',', '.'));
                        draft.discountedPrice = double.tryParse(discCtrl.text.trim().replaceAll(',', '.'));
                        draft.discountRate   = null;
                        draft.productPrice   = null;
                      } else if (campaignType == 'buyOneGetOne') {
                        draft.originalPrice  = null;
                        draft.discountedPrice = null;
                        draft.discountRate   = null;
                        draft.productPrice   = double.tryParse(prodPriceCtrl.text.trim().replaceAll(',', '.'));
                      } else if (campaignType == 'secondDiscount') {
                        draft.originalPrice  = null;
                        draft.discountedPrice = null;
                        draft.discountRate   = int.tryParse(discRateCtrl.text.trim());
                        draft.productPrice   = double.tryParse(prodPriceCtrl.text.trim().replaceAll(',', '.'));
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
  // Save AI items to Firestore as drafts
  // -----------------------------------------------------------------------

  Future<void> _saveDrafts() async {
    final selected = _aiItems.where((i) => i.selected).toList();
    if (selected.isEmpty) return;

    final col = FirebaseFirestore.instance.collection('catalog_drafts');

    // Market/kategori ID'lerini kaydet öncesi çöz
    final marketsSnap = await FirebaseFirestore.instance.collection('markets').get();
    final catsSnap    = await FirebaseFirestore.instance.collection('categories').get();
    String normMkt(String s) => s.toLowerCase().replaceAll(RegExp(r'[\s.\-_]'), '');
    const mktAliases = <String, String>{
      'money': 'migros', 'moneymigros': 'migros',
      'carrfour': 'carrefour', 'carrefoursa': 'carrefour',
      'sok': 'şok', 'sokmarket': 'şok',
      'a101': 'a-101', 'bimeks': 'bim',
    };
    for (final item in selected) {
      if (item.marketId.isEmpty && item.marketName.isNotEmpty) {
        final norm = normMkt(item.marketName);
        final aliasNorm = mktAliases[norm] ?? norm;
        final match = marketsSnap.docs.where((d) {
          final dbNorm = normMkt(d.get('name') as String);
          return dbNorm == aliasNorm || dbNorm == norm ||
                 (d.get('name') as String).toLowerCase().contains(aliasNorm);
        }).firstOrNull;
        if (match != null) {
          item.marketId   = match.id;
          item.marketName = match.get('name') as String;
        }
      }
      if (item.categoryId.isEmpty && item.categoryName.isNotEmpty) {
        final match = catsSnap.docs.where((d) =>
          (d.get('name') as String).toLowerCase() == item.categoryName.toLowerCase()
        ).firstOrNull;
        if (match != null) {
          item.categoryId   = match.id;
          item.categoryName = match.get('name') as String;
        }
      }
    }

    int saved = 0;
    for (final item in selected) {
      try {
        await col.add(item.toFirestore());
        saved++;
      } catch (_) {}
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

    // Nokta, tire, boşluk sil ve küçük harfe çevir: "A.101" → "a101", "A-101" → "a101"
    String normalizeMarket(String s) =>
        s.toLowerCase().replaceAll(RegExp(r'[\s.\-_]'), '');

    // AI'ın yanlış yazabileceği market adları için alias tablosu
    const marketAliases = <String, String>{
      'money': 'migros',
      'moneymigros': 'migros',
      'carrfour': 'carrefour',
      'carrefoursa': 'carrefour',
      'sok': 'şok',
      'sokmarket': 'şok',
      'a101': 'a-101',
      'bimeks': 'bim',
    };

    String resolveMarketId(String id, String name) {
      if (id.isNotEmpty) return id;
      try {
        final normalized = normalizeMarket(name);
        final aliasResolved = marketAliases[normalized] ?? normalized;
        final match = marketsSnap.docs.firstWhere(
          (d) {
            final dbNorm = normalizeMarket(d.get('name') as String);
            return dbNorm == aliasResolved || dbNorm == normalized;
          },
          orElse: () => marketsSnap.docs.firstWhere(
            (d) => (d.get('name') as String).toLowerCase().contains(aliasResolved),
            orElse: () => marketsSnap.docs.firstWhere(
              (d) => aliasResolved.contains(normalizeMarket(d.get('name') as String)) && normalizeMarket(d.get('name') as String).length >= 3,
              orElse: () => throw StateError(''),
            ),
          ),
        );
        return match.id;
      } catch (_) {
        return '';
      }
    }

    String resolveMarketName(String id, String name) {
      if (id.isNotEmpty) {
        final match = marketsSnap.docs.where((d) => d.id == id).firstOrNull;
        return match != null ? (match.get('name') as String) : name;
      }
      if (name.isNotEmpty) {
        final match = marketsSnap.docs.where((d) =>
            (d.get('name') as String).toLowerCase() == name.toLowerCase()).firstOrNull;
        if (match != null) return match.get('name') as String;
      }
      return name;
    }

    String resolveCategoryId(String id, String name) {
      if (id.isNotEmpty) return id;
      final match = catsSnap.docs.where((d) =>
          (d.get('name') as String).toLowerCase() == name.toLowerCase()).firstOrNull;
      return match?.id ?? '';
    }

    String resolveCategoryName(String id, String name) {
      if (id.isNotEmpty) {
        final match = catsSnap.docs.where((d) => d.id == id).firstOrNull;
        return match != null ? (match.get('name') as String) : name;
      }
      if (name.isNotEmpty) {
        final match = catsSnap.docs.where((d) =>
            (d.get('name') as String).toLowerCase() == name.toLowerCase()).firstOrNull;
        if (match != null) return match.get('name') as String;
      }
      return name;
    }

    final List<String> eksikler = [];
    for (final id in _selectedDraftIds) {
      final doc = await draftsCol.doc(id).get();
      if (!doc.exists) continue;
      final data = doc.data()!;
      final product    = (data['productName'] as String? ?? '').trim();
      final marketId   = resolveMarketId(
          (data['marketId'] as String? ?? '').trim(),
          (data['marketName'] as String? ?? '').trim());
      final categoryId = resolveCategoryId(
          (data['categoryId'] as String? ?? '').trim(),
          (data['categoryName'] as String? ?? '').trim());
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
          content: Text(
            'Eksik alan var:\n${eksikler.join('\n')}',
          ),
          backgroundColor: Colors.orange.shade700,
          duration: const Duration(seconds: 6),
        ));
      }
      return;
    }

    setState(() => _publishing = true);

    final campaignsCol  = FirebaseFirestore.instance.collection('campaigns');
    int published        = 0;
    final duplicateNames = <String>[];

    for (final id in _selectedDraftIds.toList()) {
      try {
        final draftDoc = await draftsCol.doc(id).get();
        if (!draftDoc.exists) continue;
        final data = draftDoc.data()!;

        final campaignType  = (data['campaignType'] as String? ?? 'priceDiscount');
        final oldPrice      = (data['originalPrice'] as num?)?.toDouble() ?? 0;
        final newPrice      = (data['discountedPrice'] as num?)?.toDouble() ?? 0;
        final productPrice  = (data['productPrice'] as num?)?.toDouble() ?? 0;
        final discountRate  = (data['discountRate'] as num?)?.toInt() ?? 0;
        final productName   = data['productName'] as String? ?? '';

        final mId   = resolveMarketId((data['marketId'] as String? ?? '').trim(), (data['marketName'] as String? ?? '').trim());
        final mName = resolveMarketName((data['marketId'] as String? ?? '').trim(), (data['marketName'] as String? ?? '').trim());
        final cId   = resolveCategoryId((data['categoryId'] as String? ?? '').trim(), (data['categoryName'] as String? ?? '').trim());
        final cName = resolveCategoryName((data['categoryId'] as String? ?? '').trim(), (data['categoryName'] as String? ?? '').trim());

        String autoTitle;
        if (campaignType == 'buyOneGetOne') {
          autoTitle = productName.isNotEmpty ? '$productName - 1 Alana 1 Bedava' : '1 Alana 1 Bedava';
        } else if (campaignType == 'secondDiscount') {
          autoTitle = productName.isNotEmpty
              ? '$productName - 1 Alana İkincisi %$discountRate İndirimli'
              : '1 Alana İkincisi %$discountRate İndirimli';
        } else {
          autoTitle = productName.isNotEmpty
              ? '$productName - ${oldPrice.toStringAsFixed(2)} TL yerine ${newPrice.toStringAsFixed(2)} TL'
              : 'Fiyat İndirimi';
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
              .limit(1)
              .get();
          if (existing.docs.isNotEmpty) {
            duplicateNames.add(productName);
            continue;
          }
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

  // -----------------------------------------------------------------------
  // Build
  // -----------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Gemini Katalog'),
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        automaticallyImplyLeading: false,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings_outlined),
            onPressed: _showSettingsDialog,
            tooltip: 'API Ayarları',
          ),
        ],
        bottom: TabBar(
          controller: _tabController,
          indicatorColor: Colors.white,
          labelColor: Colors.white,
          unselectedLabelColor: Colors.white60,
          tabs: [
            const Tab(text: 'Analiz', icon: Icon(Icons.auto_awesome_outlined, size: 18)),
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
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(10),
                        ),
                        child: Text('$count',
                            style: const TextStyle(
                                fontSize: 10, color: Color(0xFF2563EB), fontWeight: FontWeight.bold)),
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
                                decoration: const BoxDecoration(
                                    color: Color(0xFF2563EB), shape: BoxShape.circle),
                                child: const Icon(Icons.edit, color: Colors.white, size: 16),
                              ),
                            ),
                          ),
                        ])
                      : _pickedPdfBytes != null
                          ? Stack(fit: StackFit.expand, children: [
                              Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                                const Icon(Icons.picture_as_pdf, size: 48, color: Color(0xFFDC2626)),
                                const SizedBox(height: 8),
                                Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 16),
                                  child: Text(
                                    _pickedPdfName ?? 'PDF Belgesi',
                                    style: const TextStyle(
                                        color: Color(0xFF1E40AF),
                                        fontWeight: FontWeight.w600,
                                        fontSize: 13),
                                    textAlign: TextAlign.center,
                                    maxLines: 2,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                const Text('PDF yüklendi',
                                    style: TextStyle(color: Colors.grey, fontSize: 12)),
                              ]),
                              Positioned(
                                top: 8, right: 8,
                                child: GestureDetector(
                                  onTap: _pickFile,
                                  child: Container(
                                    padding: const EdgeInsets.all(6),
                                    decoration: const BoxDecoration(
                                        color: Color(0xFF2563EB), shape: BoxShape.circle),
                                    child: const Icon(Icons.edit, color: Colors.white, size: 16),
                                  ),
                                ),
                              ),
                            ])
                          : const Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                              Icon(Icons.add_photo_alternate_outlined, size: 44, color: Color(0xFF2563EB)),
                              SizedBox(height: 8),
                              Text('Katalog / Broşür Yükle',
                                  style: TextStyle(color: Color(0xFF2563EB), fontWeight: FontWeight.w600)),
                              SizedBox(height: 4),
                              Text('Fotoğraf, kamera veya PDF',
                                  style: TextStyle(color: Colors.grey, fontSize: 12)),
                            ]),
                ),
              ),
            ),

            if (_pickedImage != null || _pickedPdfBytes != null)
              SliverToBoxAdapter(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                  child: ElevatedButton.icon(
                    onPressed: _analyzing ? null : _analyze,
                    icon: _analyzing
                        ? const SizedBox(width: 18, height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                        : const Icon(Icons.auto_awesome),
                    label: Text(_analyzing ? (_analyzeStatus ?? 'Analiz ediliyor...') : 'Analiz Et'),
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
                      Expanded(child: Text(_analyzeError!,
                          style: const TextStyle(color: Colors.red, fontSize: 13))),
                    ]),
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

            if (_aiItems.isEmpty && !_analyzing && _pickedImage == null && _pickedPdfBytes == null)
              SliverFillRemaining(
                child: Center(
                  child: Column(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.auto_awesome_outlined, size: 72, color: Colors.grey.shade200),
                    const SizedBox(height: 12),
                    Text('Broşür yükleyip analiz edin',
                        style: TextStyle(color: Colors.grey.shade400, fontSize: 15)),
                    const SizedBox(height: 4),
                    Text('Gemini ile ürünler otomatik listelenecek',
                        style: TextStyle(color: Colors.grey.shade300, fontSize: 13)),
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
                                  style: const TextStyle(
                                      fontSize: 13, color: Colors.deepOrange, fontWeight: FontWeight.bold)),
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
                      tooltip: 'Düzenle',
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                    ),
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                      onPressed: () => setState(() => _aiItems.remove(item)),
                      tooltip: 'Sil',
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
              Text('Kayıtlı taslak yok',
                  style: TextStyle(color: Colors.grey.shade400, fontSize: 15)),
              const SizedBox(height: 4),
              Text('Analiz ekranından taslak kaydedin',
                  style: TextStyle(color: Colors.grey.shade300, fontSize: 13)),
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
                      Text('${docs.length} taslak',
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
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
                                    _bulkStartDate != null
                                        ? _dateFormat.format(_bulkStartDate!)
                                        : 'Başlangıç',
                                    style: const TextStyle(fontSize: 13),
                                  ),
                                  onPressed: () async {
                                    final d = await showDatePicker(
                                      context: context,
                                      initialDate: _bulkStartDate ?? DateTime.now(),
                                      firstDate: DateTime(2020),
                                      lastDate: DateTime(2030),
                                      locale: const Locale('tr', 'TR'),
                                    );
                                    if (d != null) setState(() => _bulkStartDate = d);
                                  },
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                                    side: BorderSide(
                                        color: _bulkStartDate != null
                                            ? const Color(0xFF2563EB)
                                            : Colors.grey.shade400),
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
                                      firstDate: DateTime(2020),
                                      lastDate: DateTime(2030),
                                      locale: const Locale('tr', 'TR'),
                                    );
                                    if (d != null) setState(() => _bulkEndDate = d);
                                  },
                                  style: OutlinedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
                                    side: BorderSide(
                                        color: _bulkEndDate != null
                                            ? const Color(0xFF2563EB)
                                            : Colors.grey.shade400),
                                  ),
                                ),
                              ),
                            ]),
                            if (_bulkStartDate != null && _bulkEndDate != null) ...[
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton(
                                  onPressed: _applyingBulkDates ? null : () => _applyBulkDates(docs),
                                  style: ElevatedButton.styleFrom(
                                    backgroundColor: const Color(0xFF2563EB),
                                    foregroundColor: Colors.white,
                                    padding: const EdgeInsets.symmetric(vertical: 10),
                                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                                  ),
                                  child: _applyingBulkDates
                                      ? const SizedBox(
                                          width: 18, height: 18,
                                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                                      : Text('${docs.length} Taslağa Uygula',
                                          style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                                ),
                              ),
                            ],
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
                      return _buildDraftCard(docs[i]);
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
                      ? const SizedBox(width: 20, height: 20,
                          child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.rocket_launch_outlined),
                  label: Text(_publishing
                      ? 'Yayınlanıyor...'
                      : '${_selectedDraftIds.length} Kampanyayı Yayınla'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFDC2626),
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

  Widget _buildDraftCard(DocumentSnapshot doc) {
    final data       = doc.data() as Map<String, dynamic>;
    final isSelected = _selectedDraftIds.contains(doc.id);

    final campaignType  = data['campaignType'] as String? ?? 'priceDiscount';
    final origPrice     = (data['originalPrice'] as num?)?.toDouble();
    final discPrice     = (data['discountedPrice'] as num?)?.toDouble();
    final discountRate  = (data['discountRate'] as num?)?.toInt();
    final productPrice  = (data['productPrice'] as num?)?.toDouble();

    final hasDiscount = campaignType == 'priceDiscount' &&
        origPrice != null && discPrice != null && origPrice > 0 && discPrice < origPrice;
    final pct = (hasDiscount && origPrice != null && origPrice > 0 && discPrice != null)
        ? ((origPrice - discPrice) / origPrice * 100).round()
        : 0;

    final startTs = data['startDate'] as Timestamp?;
    final endTs   = data['endDate'] as Timestamp?;

    final missingFields = <String>[];
    if ((data['productName'] as String? ?? '').trim().isEmpty) missingFields.add('Ürün adı');
    if ((data['marketId'] as String? ?? '').trim().isEmpty && (data['marketName'] as String? ?? '').trim().isEmpty) missingFields.add('Market');
    if ((data['categoryId'] as String? ?? '').trim().isEmpty && (data['categoryName'] as String? ?? '').trim().isEmpty) missingFields.add('Kategori');
    if (startTs == null || endTs == null) missingFields.add('Tarih aralığı');
    // Fotoğraf zorunlu değil — yayın engellenmez
    final hasWarning = missingFields.isNotEmpty;

    final draft = CatalogDraft(
      productName:   data['productName'] as String? ?? '',
      marketId:      data['marketId'] as String? ?? '',
      marketName:    data['marketName'] as String? ?? '',
      categoryId:    data['categoryId'] as String? ?? '',
      categoryName:  data['categoryName'] as String? ?? '',
      campaignType:  campaignType,
      originalPrice: origPrice,
      discountedPrice: discPrice,
      discountRate:  discountRate,
      productPrice:  productPrice,
      startDate:     startTs?.toDate(),
      endDate:       endTs?.toDate(),
      productImageUrl: data['productImageUrl'] as String?,
    );

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFFFF7ED) : Colors.white,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected ? const Color(0xFFDC2626) : Colors.grey.shade200,
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
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Checkbox(
                      value: isSelected,
                      onChanged: (v) => setState(() {
                        if (v == true) _selectedDraftIds.add(doc.id);
                        else _selectedDraftIds.remove(doc.id);
                      }),
                      activeColor: const Color(0xFFDC2626),
                      materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Wrap(
                            spacing: 4,
                            runSpacing: 2,
                            children: [
                              if ((data['marketName'] as String? ?? '').isNotEmpty)
                                _badge(data['marketName'] as String, const Color(0xFF2563EB)),
                              if ((data['categoryName'] as String? ?? '').isNotEmpty)
                                _badge(data['categoryName'] as String, Colors.purple),
                              if (campaignType == 'priceDiscount' && hasDiscount)
                                _badge('💰 %$pct', Colors.deepOrange),
                              if (campaignType == 'buyOneGetOne')
                                _badge('🎁 1+1', Colors.green.shade700),
                              if (campaignType == 'secondDiscount')
                                _badge('🏷️ 2.si %${discountRate ?? '?'}', Colors.purple.shade700),
                            ],
                          ),
                          const SizedBox(height: 5),
                          Text(data['productName'] as String? ?? '',
                              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold)),
                          if (hasWarning) ...[
                            const SizedBox(height: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.orange.shade50,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.orange.shade300),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.warning_amber_rounded, size: 13, color: Colors.orange.shade700),
                                  const SizedBox(width: 4),
                                  Text(
                                    'Eksik: ${missingFields.join(', ')}',
                                    style: TextStyle(fontSize: 11, color: Colors.orange.shade800, fontWeight: FontWeight.w600),
                                  ),
                                ],
                              ),
                            ),
                          ],
                          const SizedBox(height: 4),
                          Row(children: [
                            if (campaignType == 'priceDiscount') ...[
                              if (origPrice != null)
                                Text('${_priceFmt.format(origPrice)} TL',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: hasDiscount ? Colors.grey : Colors.black87,
                                      decoration: hasDiscount ? TextDecoration.lineThrough : null,
                                    )),
                              if (hasDiscount) ...[
                                const SizedBox(width: 6),
                                Text('${_priceFmt.format(discPrice)} TL',
                                    style: const TextStyle(
                                        fontSize: 13, color: Colors.deepOrange, fontWeight: FontWeight.bold)),
                              ],
                            ] else if (campaignType == 'buyOneGetOne' && productPrice != null && productPrice > 0)
                              Text('${_priceFmt.format(productPrice)} TL',
                                  style: const TextStyle(fontSize: 12, color: Colors.black87))
                            else if (campaignType == 'secondDiscount' && productPrice != null && productPrice > 0)
                              Text('${_priceFmt.format(productPrice)} TL / ürün',
                                  style: const TextStyle(fontSize: 12, color: Colors.black87)),
                            const Spacer(),
                            if (startTs != null && endTs != null)
                              Text(
                                '${_dateFormat.format(startTs.toDate())} - ${_dateFormat.format(endTs.toDate())}',
                                style: const TextStyle(fontSize: 11, color: Colors.grey),
                              ),
                          ]),
                        ],
                      ),
                    ),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18, color: Color(0xFF2563EB)),
                          onPressed: () async {
                            await _showEditSheet(draft, onSaved: () async {
                              await doc.reference.update(draft.toFirestore()..remove('createdAt'));
                            });
                          },
                          tooltip: 'Düzenle',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                        IconButton(
                          icon: const Icon(Icons.delete_outline, size: 18, color: Colors.red),
                          onPressed: () => _confirmDelete(doc),
                          tooltip: 'Sil',
                          padding: EdgeInsets.zero,
                          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                        ),
                      ],
                    ),
                  ],
                ),
                if ((data['productImageUrl'] as String? ?? '').isNotEmpty) ...[
                  const SizedBox(height: 8),
                  GestureDetector(
                    onTap: () {
                      final url = data['productImageUrl'] as String;
                      showDialog(
                        context: context,
                        builder: (_) => Dialog(
                          backgroundColor: Colors.transparent,
                          insetPadding: const EdgeInsets.all(12),
                          child: GestureDetector(
                            onTap: () => Navigator.pop(context),
                            child: InteractiveViewer(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.network(url, fit: BoxFit.contain),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(6),
                      child: Image.network(
                        data['productImageUrl'] as String,
                        height: 100,
                        width: double.infinity,
                        fit: BoxFit.contain,
                        loadingBuilder: (_, child, progress) => progress == null
                            ? child
                            : const SizedBox(height: 100, child: Center(child: CircularProgressIndicator(strokeWidth: 2))),
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      ),
                    ),
                  ),
                ],
                _buildNotifPreview(
                  data['productName'] as String? ?? '',
                  data['marketName'] as String? ?? '',
                  origPrice,
                  discPrice,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNotifPreview(String productName, String marketName, double? origPrice, double? discPrice) {
    final hasDiscount = origPrice != null && discPrice != null && origPrice > 0 && discPrice < origPrice;
    final pct = hasDiscount ? ((origPrice - discPrice) / origPrice * 100).round() : 0;

    final String title;
    final String body;

    if (hasDiscount && pct > 0) {
      title = '📣 %$pct İndirim Başladı!';
      body  = '$productName — ${marketName.isNotEmpty ? "$marketName'da" : "markette"} %$pct indirimli! 🛒 Hemen incele.';
    } else {
      title = '📣 İndirim Başladı!';
      body  = '$productName — ${marketName.isNotEmpty ? "$marketName'da" : "markette"} indirimde! 🛒 Hemen incele.';
    }

    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFF8FAFF),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFFBFD3FF), width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 30, height: 30,
            decoration: BoxDecoration(
              color: const Color(0xFF16A34A),
              borderRadius: BorderRadius.circular(6),
            ),
            child: const Icon(Icons.door_front_door_outlined, color: Colors.white, size: 16),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(children: [
                  const Text('İndirim Kapısı',
                      style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: Colors.grey)),
                  const Spacer(),
                  Text('örnek bildirim',
                      style: TextStyle(fontSize: 10, color: Colors.grey.shade400)),
                ]),
                const SizedBox(height: 2),
                Text(title,
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.black87)),
                Text(body,
                    style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyBulkDates(List<DocumentSnapshot> docs) async {
    if (_bulkStartDate == null || _bulkEndDate == null) return;
    setState(() => _applyingBulkDates = true);
    try {
      final startTs = Timestamp.fromDate(_bulkStartDate!);
      final endTs   = Timestamp.fromDate(_bulkEndDate!);
      final batch   = FirebaseFirestore.instance.batch();
      for (final doc in docs) {
        batch.update(doc.reference, {'startDate': startTs, 'endDate': endTs});
      }
      await batch.commit();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('${docs.length} taslağın tarihi güncellendi.'),
          backgroundColor: const Color(0xFF16A34A),
          behavior: SnackBarBehavior.floating,
          margin: const EdgeInsets.only(bottom: 80, left: 16, right: 16),
        ));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text('Hata: $e'),
          backgroundColor: Colors.red,
        ));
      }
    } finally {
      if (mounted) setState(() => _applyingBulkDates = false);
    }
  }

  void _confirmDeleteAllDrafts(List<DocumentSnapshot> docs) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Tüm Taslakları Sil'),
        content: Text('${docs.length} taslak silinsin mi? Bu işlem geri alınamaz.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              Navigator.pop(ctx);
              final batch = FirebaseFirestore.instance.batch();
              for (final doc in docs) { batch.delete(doc.reference); }
              await batch.commit();
              setState(() => _selectedDraftIds.clear());
            },
            child: const Text('Tümünü Sil'),
          ),
        ],
      ),
    );
  }

  void _confirmDelete(DocumentSnapshot doc) {
    final name = (doc.data() as Map<String, dynamic>)['productName'] as String? ?? '';
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Taslağı Sil'),
        content: Text('"$name" taslağı silinsin mi?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('İptal')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red, foregroundColor: Colors.white),
            onPressed: () async {
              await doc.reference.delete();
              setState(() => _selectedDraftIds.remove(doc.id));
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('Sil'),
          ),
        ],
      ),
    );
  }

  // -----------------------------------------------------------------------
  // Helpers
  // -----------------------------------------------------------------------

  Widget _badge(String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(text,
          style: TextStyle(fontSize: 10, color: color, fontWeight: FontWeight.w600)),
    );
  }
}
