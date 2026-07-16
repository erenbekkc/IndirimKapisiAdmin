import 'package:flutter/material.dart';
import 'katalog_giris_screen.dart';
import 'gemini_katalog_screen.dart';
import 'paddle_katalog_screen.dart';

class KatalogWrapperScreen extends StatelessWidget {
  const KatalogWrapperScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: 3,
      child: Column(
        children: [
          Container(
            color: const Color(0xFF2563EB),
            child: const TabBar(
              labelColor: Colors.white,
              unselectedLabelColor: Colors.white70,
              indicatorColor: Colors.white,
              tabs: [
                Tab(text: 'OCR'),
                Tab(text: 'Gemini'),
                Tab(text: 'Claude'),
              ],
            ),
          ),
          const Expanded(
            child: TabBarView(
              children: [
                PaddleKatalogScreen(),
                GeminiKatalogScreen(),
                KatalogGirisScreen(),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
