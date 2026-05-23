import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:image_picker/image_picker.dart';
import 'package:intl/intl.dart';

enum CampaignType { buyOneGetOne, priceDiscount, secondDiscount }

class AddCampaignScreen extends StatefulWidget {
  final DocumentSnapshot? campaignDoc;
  final String? preselectedMarketId;
  final String? preselectedMarketName;
  final String? preselectedCategoryId;
  final String? preselectedCategoryName;
  const AddCampaignScreen({super.key, this.campaignDoc, this.preselectedMarketId, this.preselectedMarketName, this.preselectedCategoryId, this.preselectedCategoryName});

  @override
  State<AddCampaignScreen> createState() => _AddCampaignScreenState();
}

class _AddCampaignScreenState extends State<AddCampaignScreen> {
  final _productController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _oldPriceController = TextEditingController();
  final _newPriceController = TextEditingController();
  final _discountRateController = TextEditingController();
  final _productPriceController = TextEditingController();
  final _dateFormat = DateFormat('dd.MM.yyyy', 'tr_TR');

  String? _selectedMarketId;
  String? _selectedMarketName;
  String? _selectedCategoryId;
  String? _selectedCategoryName;
  DateTime? _startDate;
  DateTime? _endDate;
  CampaignType _campaignType = CampaignType.priceDiscount;
  bool _loading = false;

  XFile? _pickedImage;
  String? _existingImageUrl;

  @override
  void initState() {
    super.initState();
    // Pre-selected market/category (market veya kategori ekranından gelince)
    if (widget.preselectedMarketId != null) {
      _selectedMarketId = widget.preselectedMarketId;
      _selectedMarketName = widget.preselectedMarketName;
    }
    if (widget.preselectedCategoryId != null) {
      _selectedCategoryId = widget.preselectedCategoryId;
      _selectedCategoryName = widget.preselectedCategoryName;
    }
    if (widget.campaignDoc != null) {
      final data = widget.campaignDoc!.data() as Map<String, dynamic>;
      _productController.text = data['product'] ?? '';
      _descriptionController.text = data['description'] ?? '';
      _selectedMarketId = data['marketId'];
      _selectedMarketName = data['marketName'];
      _selectedCategoryId = data['categoryId'];
      _selectedCategoryName = data['categoryName'];
      _startDate = (data['startDate'] as Timestamp?)?.toDate();
      _endDate = (data['endDate'] as Timestamp?)?.toDate();
      if (data['campaignType'] == 'priceDiscount') {
        _campaignType = CampaignType.priceDiscount;
        _oldPriceController.text = data['oldPrice']?.toString() ?? '';
        _newPriceController.text = data['newPrice']?.toString() ?? '';
      } else if (data['campaignType'] == 'secondDiscount') {
        _campaignType = CampaignType.secondDiscount;
        _discountRateController.text = data['discountRate']?.toString() ?? '';
        _productPriceController.text = data['productPrice']?.toString() ?? '';
      } else if (data['campaignType'] == 'buyOneGetOne') {
        _campaignType = CampaignType.buyOneGetOne;
        _productPriceController.text = data['productPrice']?.toString() ?? '';
      }
      _existingImageUrl = data['productImageUrl'] as String?;
    }
  }

  @override
  void dispose() {
    _productController.dispose();
    _descriptionController.dispose();
    _oldPriceController.dispose();
    _newPriceController.dispose();
    _discountRateController.dispose();
    _productPriceController.dispose();
    super.dispose();
  }

  String _buildSecondDiscountHelper() {
    final price = double.tryParse(_productPriceController.text.trim());
    final rate = int.tryParse(_discountRateController.text.trim());
    if (price == null || rate == null || price <= 0) return '2. ürün indirimli fiyatı otomatik hesaplanır';
    final discounted = price * (1 - rate / 100);
    return '1. ürün: ${price.toStringAsFixed(2)} TL  |  2. ürün: ${discounted.toStringAsFixed(2)} TL';
  }

  String _buildAutoTitle() {
    final product = _productController.text.trim();
    if (_campaignType == CampaignType.buyOneGetOne) {
      return product.isEmpty ? '1 Alana 1 Bedava' : '$product - 1 Alana 1 Bedava';
    } else if (_campaignType == CampaignType.secondDiscount) {
      final rate = _discountRateController.text.trim();
      return product.isEmpty ? '1 Alana İkincisi %$rate İndirimli' : '$product - 1 Alana İkincisi %$rate İndirimli';
    } else {
      final oldPrice = _oldPriceController.text.trim();
      final newPrice = _newPriceController.text.trim();
      return product.isEmpty ? '$oldPrice TL yerine $newPrice TL' : '$product - $oldPrice TL yerine $newPrice TL';
    }
  }

  Future<void> _pickDateRange() async {
    final picked = await showDateRangePicker(
      context: context,
      initialDateRange: (_startDate != null && _endDate != null)
          ? DateTimeRange(start: _startDate!, end: _endDate!)
          : null,
      firstDate: DateTime.now().subtract(const Duration(days: 30)),
      lastDate: DateTime.now().add(const Duration(days: 365)),
      locale: const Locale('tr', 'TR'),
      builder: (context, child) => Theme(
        data: Theme.of(context).copyWith(
          colorScheme: const ColorScheme.light(primary: Color(0xFF2563EB)),
        ),
        child: child!,
      ),
    );
    if (picked != null) {
      setState(() {
        _startDate = picked.start;
        _endDate = picked.end;
      });
    }
  }

  Future<void> _save() async {
    if (_productController.text.trim().isEmpty) {
      _showError('Ürün adı giriniz');
      return;
    }
    if (_selectedMarketId == null) {
      _showError('Market seçiniz');
      return;
    }
    if (_selectedCategoryId == null) {
      _showError('Kategori seçiniz');
      return;
    }
    if (_campaignType == CampaignType.priceDiscount &&
        (_oldPriceController.text.trim().isEmpty || _newPriceController.text.trim().isEmpty)) {
      _showError('Eski ve yeni fiyatı giriniz');
      return;
    }
    if (_campaignType == CampaignType.secondDiscount &&
        _discountRateController.text.trim().isEmpty) {
      _showError('İndirim oranını giriniz');
      return;
    }
    if (_startDate == null || _endDate == null) {
      _showError('Tarih aralığı seçiniz');
      return;
    }
    if (_endDate!.isBefore(_startDate!)) {
      _showError('Bitiş tarihi başlangıçtan önce olamaz');
      return;
    }

    // Mükerrer kampanya kontrolü (sadece yeni kayıtta)
    if (widget.campaignDoc == null) {
      final productName = _productController.text.trim().toLowerCase();
      final draftsSnap = await FirebaseFirestore.instance
          .collection('catalog_drafts')
          .where('marketId', isEqualTo: _selectedMarketId)
          .get();
      final campaignsSnap = await FirebaseFirestore.instance
          .collection('campaigns')
          .where('marketId', isEqualTo: _selectedMarketId)
          .get();

      bool duplicate = false;
      for (final doc in [...draftsSnap.docs, ...campaignsSnap.docs]) {
        final data = doc.data();
        final existingProduct = ((data['productName'] ?? data['product'] ?? '') as String).toLowerCase();
        if (existingProduct != productName) continue;
        final existingStart = (data['startDate'] as Timestamp?)?.toDate();
        final existingEnd = (data['endDate'] as Timestamp?)?.toDate();
        if (existingStart == null || existingEnd == null) continue;
        // Tarih aralığı çakışıyor mu?
        if (_startDate!.isBefore(existingEnd) && _endDate!.isAfter(existingStart)) {
          duplicate = true;
          break;
        }
      }

      if (duplicate) {
        _showError('Bu market için aynı ürünle çakışan tarihli bir kampanya zaten mevcut');
        return;
      }
    }

    setState(() => _loading = true);
    try {
      // Fotoğraf yükle (varsa)
      String? productImageUrl = _existingImageUrl;
      if (_pickedImage != null) {
        final ext = _pickedImage!.name.contains('.') ? _pickedImage!.name.split('.').last : 'jpg';
        final ref = FirebaseStorage.instance
            .ref('campaign_images/${DateTime.now().millisecondsSinceEpoch}.$ext');
        await ref.putFile(File(_pickedImage!.path));
        productImageUrl = await ref.getDownloadURL();
      }

      if (widget.campaignDoc == null) {
        // Yeni kampanya → catalog_drafts'a taslak olarak kaydet
        final draftData = <String, dynamic>{
          'productName': _productController.text.trim(),
          'description': _descriptionController.text.trim(),
          'marketId': _selectedMarketId,
          'marketName': _selectedMarketName,
          'categoryId': _selectedCategoryId,
          'categoryName': _selectedCategoryName,
          'startDate': Timestamp.fromDate(_startDate!),
          'endDate': Timestamp.fromDate(_endDate!),
          'campaignType': _campaignType.name,
          'productImageUrl': productImageUrl ?? '',
          'status': 'draft',
          'createdAt': FieldValue.serverTimestamp(),
        };
        if (_campaignType == CampaignType.buyOneGetOne) {
          draftData['productPrice'] = double.tryParse(_productPriceController.text.trim()) ?? 0;
        } else if (_campaignType == CampaignType.priceDiscount) {
          draftData['originalPrice'] = double.tryParse(_oldPriceController.text.trim()) ?? 0;
          draftData['discountedPrice'] = double.tryParse(_newPriceController.text.trim()) ?? 0;
        } else if (_campaignType == CampaignType.secondDiscount) {
          draftData['discountRate'] = int.tryParse(_discountRateController.text.trim()) ?? 0;
          draftData['productPrice'] = double.tryParse(_productPriceController.text.trim()) ?? 0;
        }
        await FirebaseFirestore.instance.collection('catalog_drafts').add(draftData);
      } else {
        // Düzenleme → campaigns koleksiyonunu direkt güncelle
        final editData = <String, dynamic>{
          'title': _buildAutoTitle(),
          'product': _productController.text.trim(),
          'description': _descriptionController.text.trim(),
          'marketId': _selectedMarketId,
          'marketName': _selectedMarketName,
          'categoryId': _selectedCategoryId,
          'categoryName': _selectedCategoryName,
          'startDate': Timestamp.fromDate(_startDate!),
          'endDate': Timestamp.fromDate(_endDate!),
          'campaignType': _campaignType.name,
          'updatedAt': FieldValue.serverTimestamp(),
          'productImageUrl': productImageUrl ?? '',
        };
        if (_campaignType == CampaignType.buyOneGetOne) {
          editData['productPrice'] = double.tryParse(_productPriceController.text.trim()) ?? 0;
        } else if (_campaignType == CampaignType.priceDiscount) {
          editData['oldPrice'] = double.tryParse(_oldPriceController.text.trim()) ?? 0;
          editData['newPrice'] = double.tryParse(_newPriceController.text.trim()) ?? 0;
        } else if (_campaignType == CampaignType.secondDiscount) {
          editData['discountRate'] = int.tryParse(_discountRateController.text.trim()) ?? 0;
          editData['productPrice'] = double.tryParse(_productPriceController.text.trim()) ?? 0;
        }
        await widget.campaignDoc!.reference.update(editData);
      }

      if (mounted) {
        if (Navigator.canPop(context)) {
          Navigator.pop(context);
        } else {
          // Sekme modunda: formu sıfırla
          _productController.clear();
          _descriptionController.clear();
          _oldPriceController.clear();
          _newPriceController.clear();
          _discountRateController.clear();
          _productPriceController.clear();
          setState(() {
            _selectedMarketId = null;
            _selectedMarketName = null;
            _selectedCategoryId = null;
            _selectedCategoryName = null;
            _startDate = null;
            _endDate = null;
            _campaignType = CampaignType.priceDiscount;
            _pickedImage = null;
            _existingImageUrl = null;
          });
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Taslak olarak kaydedildi!'), backgroundColor: Colors.green),
          );
        }
      }
    } catch (e) {
      _showError('Kayıt hatası: $e');
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _pickImage() async {
    final picker = ImagePicker();
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Galeriden Seç'),
              onTap: () => Navigator.pop(ctx, ImageSource.gallery),
            ),
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('Kamera ile Çek'),
              onTap: () => Navigator.pop(ctx, ImageSource.camera),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    final picked = await picker.pickImage(source: source, imageQuality: 80, maxWidth: 1200);
    if (picked != null) setState(() => _pickedImage = picked);
  }

  Widget _buildImagePicker() {
    final hasNewImage = _pickedImage != null;
    final hasExistingImage = _existingImageUrl != null && _existingImageUrl!.isNotEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'Ürün Fotoğrafı (opsiyonel)',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey),
        ),
        const SizedBox(height: 8),
        if (hasNewImage || hasExistingImage) ...[
          Stack(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: hasNewImage
                    ? Image.file(
                        File(_pickedImage!.path),
                        height: 180,
                        width: double.infinity,
                        fit: BoxFit.cover,
                      )
                    : Image.network(
                        _existingImageUrl!,
                        height: 180,
                        width: double.infinity,
                        fit: BoxFit.cover,
                        loadingBuilder: (_, child, progress) => progress == null
                            ? child
                            : const SizedBox(
                                height: 180,
                                child: Center(child: CircularProgressIndicator()),
                              ),
                      ),
              ),
              Positioned(
                top: 8,
                right: 8,
                child: GestureDetector(
                  onTap: () => setState(() {
                    _pickedImage = null;
                    _existingImageUrl = null;
                  }),
                  child: Container(
                    decoration: const BoxDecoration(
                      color: Colors.black54,
                      shape: BoxShape.circle,
                    ),
                    padding: const EdgeInsets.all(4),
                    child: const Icon(Icons.close, color: Colors.white, size: 18),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.edit, size: 16),
            label: const Text('Fotoğrafı Değiştir'),
          ),
        ] else
          OutlinedButton.icon(
            onPressed: _pickImage,
            icon: const Icon(Icons.add_photo_alternate_outlined),
            label: const Text('Fotoğraf Ekle'),
            style: OutlinedButton.styleFrom(
              minimumSize: const Size(double.infinity, 52),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
      ],
    );
  }

  Map<String, String> _generateNotificationTexts() {
    final product = _productController.text.trim();
    final market = _selectedMarketName ?? '';

    String title, body;

    if (_campaignType == CampaignType.buyOneGetOne) {
      title = '📣 1 Alana 1 Bedava Başladı!';
      body = product.isNotEmpty && market.isNotEmpty
          ? '$product — ${market}\'da 1 alana 1 bedava! 🛒'
          : market.isNotEmpty
              ? '${market}\'da 1 alana 1 bedava kampanyası başladı!'
              : 'Kampanya detayları girilince önizleme güncellenir.';
    } else if (_campaignType == CampaignType.secondDiscount) {
      final rate = _discountRateController.text.trim();
      final pct = rate.isNotEmpty ? '%$rate' : '';
      title = pct.isNotEmpty ? '📣 2. Ürüne $pct İndirim!' : '📣 2. Ürüne Özel İndirim!';
      body = product.isNotEmpty && market.isNotEmpty
          ? '$product — ${market}\'da 2. ürüne${pct.isNotEmpty ? ' $pct' : ''} indirim! 👀'
          : market.isNotEmpty
              ? '${market}\'da 2. ürüne indirim kampanyası başladı!'
              : 'Kampanya detayları girilince önizleme güncellenir.';
    } else {
      final oldP = double.tryParse(_oldPriceController.text.trim());
      final newP = double.tryParse(_newPriceController.text.trim());
      final pct = (oldP != null && newP != null && oldP > 0)
          ? '%${((oldP - newP) / oldP * 100).round()}'
          : '';
      title = pct.isNotEmpty ? '📣 $pct İndirim Başladı!' : '📣 İndirim Başladı!';
      body = product.isNotEmpty && market.isNotEmpty
          ? '$product — ${market}\'da${pct.isNotEmpty ? ' $pct' : ''} indirimli! 🛒 Hemen incele.'
          : market.isNotEmpty
              ? '${market}\'da fiyat indirimi kampanyası başladı!'
              : 'Kampanya detayları girilince önizleme güncellenir.';
    }

    return {'title': title, 'body': body};
  }

  Widget _buildNotificationPreview() {
    final texts = _generateNotificationTexts();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.notifications_outlined, size: 15, color: Colors.grey),
            const SizedBox(width: 6),
            const Text(
              'Kullanıcıya Gidecek Bildirim Önizlemesi',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: const Color(0xFFF8FAFF),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: const Color(0xFFBFD3FF), width: 1.2),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(
                  color: const Color(0xFF16A34A),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: const Icon(Icons.door_front_door_outlined, color: Colors.white, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        const Text('İndirim Kapısı',
                            style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Colors.grey)),
                        const Spacer(),
                        Text('şimdi',
                            style: TextStyle(fontSize: 11, color: Colors.grey.shade400)),
                      ],
                    ),
                    const SizedBox(height: 3),
                    Text(texts['title']!,
                        style: const TextStyle(fontSize: 13, fontWeight: FontWeight.bold, color: Colors.black87)),
                    const SizedBox(height: 2),
                    Text(texts['body']!,
                        style: TextStyle(fontSize: 12, color: Colors.grey.shade700)),
                  ],
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.only(top: 6, left: 2),
          child: Text(
            '* Gerçek bildirimde mesajlar rastgele farklı şablonlardan seçilir.',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
          ),
        ),
      ],
    );
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.red),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isEditMode = widget.campaignDoc != null;
    final content = SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Market
          _buildMarketDropdown(),
          const SizedBox(height: 16),

          // Kategori
          _buildCategoryDropdown(),
          const SizedBox(height: 16),

          // Ürün
          TextField(
            controller: _productController,
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Ürün Adı *',
              hintText: 'örn: Bebek Bezi No.4',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.inventory_2_outlined),
            ),
          ),
          const SizedBox(height: 16),

          // Ürün Fotoğrafı
          _buildImagePicker(),
          const SizedBox(height: 20),

          // Kampanya Tipi
          const Text(
            'Kampanya Şekli *',
            style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: Colors.grey),
          ),
          const SizedBox(height: 8),
          _buildCampaignTypeSelector(),
          const SizedBox(height: 16),

          // Tip'e göre ek alanlar
          _buildCampaignTypeFields(),

          // Tarihler
          InkWell(
            onTap: _pickDateRange,
            borderRadius: BorderRadius.circular(4),
            child: InputDecorator(
              decoration: const InputDecoration(
                labelText: 'Tarih Aralığı *',
                border: OutlineInputBorder(),
                suffixIcon: Icon(Icons.date_range, size: 20),
              ),
              child: Text(
                (_startDate != null && _endDate != null)
                    ? '${_dateFormat.format(_startDate!)}  →  ${_dateFormat.format(_endDate!)}'
                    : 'Başlangıç – Bitiş seçin',
                style: TextStyle(
                  color: (_startDate != null) ? null : Colors.grey,
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Açıklama
          TextField(
            controller: _descriptionController,
            maxLines: 2,
            decoration: const InputDecoration(
              labelText: 'Ek Açıklama (opsiyonel)',
              hintText: 'Kampanya hakkında ek bilgi...',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 24),

          // Bildirim Önizlemesi
          _buildNotificationPreview(),
          const SizedBox(height: 24),

          // Kaydet
          SizedBox(
            width: double.infinity,
            height: 52,
            child: ElevatedButton(
              onPressed: _loading ? null : _save,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF2563EB),
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              child: _loading
                  ? const CircularProgressIndicator(color: Colors.white, strokeWidth: 2)
                  : const Text('Kaydet', style: TextStyle(fontSize: 16)),
            ),
          ),
          const SizedBox(height: 16),
        ],
      ),
    );

    if (isEditMode) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Kampanya Düzenle'),
          backgroundColor: const Color(0xFF2563EB),
          foregroundColor: Colors.white,
        ),
        body: content,
      );
    }
    return content;
  }

  Widget _buildCampaignTypeSelector() {
    return Column(
      children: [
        _buildTypeCard(
          type: CampaignType.priceDiscount,
          icon: '💰',
          title: 'Fiyat İndirimi',
          subtitle: 'Eski fiyat → Yeni fiyat',
        ),
        const SizedBox(height: 8),
        _buildTypeCard(
          type: CampaignType.buyOneGetOne,
          icon: '🎁',
          title: '1 Alana 1 Bedava',
          subtitle: 'Aynı üründen 2. adet ücretsiz',
        ),
        const SizedBox(height: 8),
        _buildTypeCard(
          type: CampaignType.secondDiscount,
          icon: '🏷️',
          title: '1 Alana İkincisi İndirimli',
          subtitle: '2. üründe %X indirim (örn: %50)',
        ),
      ],
    );
  }

  Widget _buildTypeCard({
    required CampaignType type,
    required String icon,
    required String title,
    required String subtitle,
  }) {
    final isSelected = _campaignType == type;
    return InkWell(
      onTap: () => setState(() => _campaignType = type),
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
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
            Text(icon, style: const TextStyle(fontSize: 24)),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title,
                      style: TextStyle(
                        fontWeight: FontWeight.w600,
                        color: isSelected ? const Color(0xFF2563EB) : Colors.black87,
                      )),
                  Text(subtitle,
                      style: TextStyle(fontSize: 12, color: Colors.grey.shade600)),
                ],
              ),
            ),
            if (isSelected)
              const Icon(Icons.check_circle, color: Color(0xFF2563EB)),
          ],
        ),
      ),
    );
  }

  Widget _buildCampaignTypeFields() {
    switch (_campaignType) {
      case CampaignType.buyOneGetOne:
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: TextField(
            controller: _productPriceController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
            onChanged: (_) => setState(() {}),
            decoration: const InputDecoration(
              labelText: 'Ürün Fiyatı (opsiyonel)',
              hintText: '49.90',
              border: OutlineInputBorder(),
              suffixText: 'TL',
              prefixIcon: Icon(Icons.sell_outlined),
              helperText: '2 adet toplam maliyet otomatik hesaplanır',
            ),
          ),
        );

      case CampaignType.secondDiscount:
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Column(
            children: [
              TextField(
                controller: _discountRateController,
                keyboardType: TextInputType.number,
                inputFormatters: [FilteringTextInputFormatter.digitsOnly],
                decoration: const InputDecoration(
                  labelText: '2. Ürün İndirim Oranı *',
                  hintText: '50',
                  border: OutlineInputBorder(),
                  suffixText: '%',
                  prefixIcon: Icon(Icons.percent),
                ),
                onChanged: (_) => setState(() {}),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _productPriceController,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                decoration: InputDecoration(
                  labelText: 'Ürün Fiyatı (opsiyonel)',
                  hintText: '300.00',
                  border: const OutlineInputBorder(),
                  suffixText: 'TL',
                  prefixIcon: const Icon(Icons.sell_outlined),
                  helperText: _buildSecondDiscountHelper(),
                ),
                onChanged: (_) => setState(() {}),
              ),
            ],
          ),
        );

      case CampaignType.priceDiscount:
        return Padding(
          padding: const EdgeInsets.only(bottom: 16),
          child: Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _oldPriceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                  decoration: const InputDecoration(
                    labelText: 'Eski Fiyat *',
                    hintText: '100',
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
                  controller: _newPriceController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[\d.]'))],
                  decoration: const InputDecoration(
                    labelText: 'Yeni Fiyat *',
                    hintText: '55',
                    border: OutlineInputBorder(),
                    suffixText: 'TL',
                  ),
                ),
              ),
            ],
          ),
        );
    }
  }

  Widget _buildMarketDropdown() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('markets').orderBy('name').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const InputDecorator(
            decoration: InputDecoration(
              labelText: 'Market *',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.store_outlined),
            ),
            child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final docs = snapshot.data!.docs;
        final validValue = docs.any((d) => d.id == _selectedMarketId) ? _selectedMarketId : null;
        return DropdownButtonFormField<String>(
          value: validValue,
          decoration: const InputDecoration(
            labelText: 'Market *',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.store_outlined),
          ),
          hint: const Text('Market seçin'),
          items: docs.map((doc) {
            final d = doc.data() as Map<String, dynamic>;
            final logoUrl = d['logoUrl'] as String?;
            final name = d['name'] as String? ?? '';
            return DropdownMenuItem(
              value: doc.id,
              child: Row(
                children: [
                  SizedBox(
                    width: 28, height: 28,
                    child: (logoUrl != null && logoUrl.isNotEmpty)
                        ? ClipOval(
                            child: Image.network(logoUrl, width: 28, height: 28, fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => const Icon(Icons.store, size: 20, color: Color(0xFF2563EB))),
                          )
                        : const Icon(Icons.store, size: 20, color: Color(0xFF2563EB)),
                  ),
                  const SizedBox(width: 8),
                  Text(name),
                ],
              ),
            );
          }).toList(),
          onChanged: (id) {
            if (id == null) return;
            final doc = docs.firstWhere((d) => d.id == id);
            setState(() {
              _selectedMarketId = id;
              _selectedMarketName = doc.get('name');
            });
          },
        );
      },
    );
  }

  Widget _buildCategoryDropdown() {
    return StreamBuilder<QuerySnapshot>(
      stream: FirebaseFirestore.instance.collection('categories').orderBy('name').snapshots(),
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return const InputDecorator(
            decoration: InputDecoration(
              labelText: 'Kategori *',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.category_outlined),
            ),
            child: SizedBox(height: 20, width: 20, child: CircularProgressIndicator(strokeWidth: 2)),
          );
        }
        final docs = snapshot.data!.docs;
        final validValue = docs.any((d) => d.id == _selectedCategoryId) ? _selectedCategoryId : null;
        return DropdownButtonFormField<String>(
          value: validValue,
          decoration: const InputDecoration(
            labelText: 'Kategori *',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.category_outlined),
          ),
          hint: const Text('Kategori seçin'),
          items: docs.map((doc) {
            final d = doc.data() as Map<String, dynamic>;
            final iconUrl = d['iconUrl'] as String?;
            final icon = d['icon'] as String? ?? '';
            final name = d['name'] as String? ?? '';
            return DropdownMenuItem(
              value: doc.id,
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
            final doc = docs.firstWhere((d) => d.id == id);
            setState(() {
              _selectedCategoryId = id;
              _selectedCategoryName = doc.get('name');
            });
          },
        );
      },
    );
  }

}
