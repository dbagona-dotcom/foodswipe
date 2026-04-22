import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:connectivity_plus/connectivity_plus.dart';
import '../data/database.dart';
import '../models/restaurant.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  List<Restaurant> dostupneKarty = [];
  Offset offsetZatazeni = Offset.zero;
  String aktualniKategorie = 'vse';
  int dobaAnimace = 0;
  double vybranaVzdalenost = 5.0;
  Position? mojePoloha;
  bool nacitamData = true;

  Timer? _debounce;
  List<String> oblibeneRestauraceIds = [];

  Map<String, int> skore = {
    'fastfood': 0, 'pizza': 0, 'cina': 0, 'burger': 0,
    'klasika': 0, 'italie': 0, 'kavarna': 0, 'zdrave': 0
  };

  final List<Map<String, String>> kategorie = [
    {'nazev': 'Vše', 'ikona': '🍽️', 'tag': 'vse'},
    {'nazev': 'Fastfood', 'ikona': '🍟', 'tag': 'fastfood'},
    {'nazev': 'Pizza', 'ikona': '🍕', 'tag': 'pizza'},
    {'nazev': 'Čína', 'ikona': '🥡', 'tag': 'cina'},
    {'nazev': 'Burger', 'ikona': '🍔', 'tag': 'burger'},
    {'nazev': 'Klasika', 'ikona': '🥩', 'tag': 'klasika'},
    {'nazev': 'Itálie', 'ikona': '🍝', 'tag': 'italie'},
    {'nazev': 'Kavárny', 'ikona': '☕', 'tag': 'kavarna'},
    {'nazev': 'Zdravé', 'ikona': '🥗', 'tag': 'zdrave'},
  ];

  @override
  void initState() {
    super.initState();
    _nactiZPameti();
    _stahniDataZeServeru();
  }

  Future<void> _nactiZPameti() async {
    final pamet = await SharedPreferences.getInstance();
    setState(() {
      for (var klic in skore.keys) {
        skore[klic] = pamet.getInt(klic) ?? 0;
      }
      oblibeneRestauraceIds = pamet.getStringList('seznam_oblibenych') ?? [];
    });
  }

  Future<void> _ulozDoPameti() async {
    final pamet = await SharedPreferences.getInstance();
    for (var klic in skore.keys) {
      await pamet.setInt(klic, skore[klic]!);
    }
    await pamet.setStringList('seznam_oblibenych', oblibeneRestauraceIds);
  }

  // ── NOVÁ FUNKCE: Kontrola internetu ──────────────────────────────────────
  Future<bool> _zkontrolujInternet() async {
    final connectivity = await Connectivity().checkConnectivity();
    final jePripojeny = connectivity.contains(ConnectivityResult.mobile) ||
        connectivity.contains(ConnectivityResult.wifi) ||
        connectivity.contains(ConnectivityResult.ethernet);

    if (!jePripojeny && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          backgroundColor: const Color(0xFF1E1E1E),
          duration: const Duration(seconds: 4),
          content: const Row(
            children: [
              Text('📡', style: TextStyle(fontSize: 20)),
              SizedBox(width: 10),
              Text(
                'Nejsi připojený k internetu',
                style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          action: SnackBarAction(
            label: 'OK',
            textColor: const Color(0xFFFF6B6B),
            onPressed: () {},
          ),
        ),
      );
      return false;
    }
    return true;
  }

  // ── NOVÁ FUNKCE: Dialog pro vypnutou GPS ─────────────────────────────────
  Future<void> _zobrazGpsDialog() async {
    if (mojePoloha != null) return;
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        backgroundColor: const Color(0xFF1E1E1E),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(20)),
        title: const Text(
          '📍 Poloha vypnutá',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
        ),
        content: const Text(
          'FoodSwipe potřebuje znát tvoji polohu aby našel restaurace v tvém okolí. Povol prosím přístup k poloze v nastavení.',
          style: TextStyle(color: Colors.grey),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Zrušit', style: TextStyle(color: Colors.grey)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B6B),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
            ),
            onPressed: () {
              Navigator.pop(context);
              Geolocator.openLocationSettings();
            },
            child: const Text('Otevřít nastavení', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Future<void> _ziskejPolohu() async {
    bool sluzbaZapnuta = await Geolocator.isLocationServiceEnabled();
    if (!sluzbaZapnuta) {
      await _zobrazGpsDialog(); // ── GPS dialog pokud je služba vypnutá
      return;
    }

    LocationPermission opravneni = await Geolocator.checkPermission();
    if (opravneni == LocationPermission.denied) {
      opravneni = await Geolocator.requestPermission();
      if (opravneni == LocationPermission.denied) {
        await _zobrazGpsDialog(); // ── GPS dialog pokud zamítl oprávnění
        return;
      }
    }
    if (opravneni == LocationPermission.deniedForever) {
      await _zobrazGpsDialog(); // ── GPS dialog pokud zamítl natrvalo
      return;
    }

    Position poloha = await Geolocator.getCurrentPosition();
    setState(() {
      mojePoloha = poloha;
      vyfiltrujKarty(aktualniKategorie);
    });
  }

  Future<void> _stahniDataZeServeru() async {
  final maPripojeni = await _zkontrolujInternet();
  if (!maPripojeni) {
    setState(() { nacitamData = false; });
    return;
  }

  await _ziskejPolohu();

  if (mojePoloha == null) {
    debugPrint('🔥 CHYBA: Nepodařilo se získat polohu.');
    vyfiltrujKarty('vse');
    setState(() { nacitamData = false; });
    return;
  }

  try {
    final String apiKey = dotenv.env['GOOGLE_API_KEY'] ?? '';
    final adresa = Uri.parse('https://places.googleapis.com/v1/places:searchNearby');
    double radiusMetry = vybranaVzdalenost * 1000;

    // Rozdělíme typy do dvou skupin pro 2 paralelní requesty = až 40 výsledků
    final skupiny = [
      ["restaurant", "fast_food_restaurant", "cafe", "pizza_restaurant",
       "hamburger_restaurant", "chinese_restaurant", "italian_restaurant"],
      ["vegan_restaurant", "vegetarian_restaurant", "japanese_restaurant",
       "american_restaurant", "sandwich_shop", "bakery",
       "ramen_restaurant", "korean_restaurant", "mexican_restaurant"],
    ];

    final hlavicky = {
      'Content-Type': 'application/json',
      'X-Goog-Api-Key': apiKey,
      'X-Goog-FieldMask': 'places.id,places.displayName.text,places.primaryType,places.location,places.photos,places.rating,places.priceLevel'
    };

    // Spustíme oba requesty paralelně
    final futures = skupiny.map((typy) => http.post(
      adresa,
      headers: hlavicky,
      body: jsonEncode({
        "includedTypes": typy,
        "maxResultCount": 20,
        "locationRestriction": {
          "circle": {
            "center": {
              "latitude": mojePoloha!.latitude,
              "longitude": mojePoloha!.longitude
            },
            "radius": radiusMetry
          }
        }
      }),
    ).timeout(const Duration(seconds: 10)));

    final odpovedi = await Future.wait(futures);

    List<Restaurant> stazeneRestaurace = [];
    Set<String> pouzitaId = {}; // deduplikace

    for (var odpoved in odpovedi) {
      if (odpoved.statusCode != 200) continue;

      final data = jsonDecode(odpoved.body);
      final places = data['places'] as List?;
      if (places == null) continue;

      for (var place in places) {
        String type = place['primaryType'] ?? 'restaurant';

        // Filtr nežádoucích typů
        if (type == 'hotel' || type == 'lodging' || type == 'bed_and_breakfast' ||
            type == 'shopping_mall' || type == 'department_store' ||
            type == 'supermarket' || type == 'grocery_store' ||
            type == 'food_court' || type == 'convenience_store') {
          continue;
        }

        String placeId = place['id'].toString();
        if (pouzitaId.contains(placeId)) continue; // přeskočit duplicity
        pouzitaId.add(placeId);

        String name = place['displayName']['text'];
        double? rating = place['rating'] != null ? (place['rating'] as num).toDouble() : null;

        String? cenaKc;
        if (place['priceLevel'] == 'PRICE_LEVEL_INEXPENSIVE') cenaKc = 'Do 200 Kč';
        else if (place['priceLevel'] == 'PRICE_LEVEL_MODERATE') cenaKc = '200 - 400 Kč';
        else if (place['priceLevel'] == 'PRICE_LEVEL_EXPENSIVE') cenaKc = '400 - 700 Kč';
        else if (place['priceLevel'] == 'PRICE_LEVEL_VERY_EXPENSIVE') cenaKc = 'Nad 700 Kč';

        String imageUrl = "https://images.unsplash.com/photo-1513639776629-7b61b0ac49cb?q=80&w=1080";
        if (place['photos'] != null && place['photos'].isNotEmpty) {
          String photoName = place['photos'][0]['name'];
          imageUrl = 'https://places.googleapis.com/v1/$photoName/media?key=$apiKey&maxHeightPx=1080&maxWidthPx=1080';
        }

        String nameLower = name.toLowerCase();
        String typeLower = type.toLowerCase();
        String nasTag = 'klasika';

        if (typeLower.contains('fast_food') || nameLower.contains('mcdonald') || nameLower.contains('kfc') || nameLower.contains('kebab')) nasTag = 'fastfood';
        else if (typeLower.contains('hamburger') || nameLower.contains('burger')) nasTag = 'burger';
        else if (typeLower.contains('cafe') || nameLower.contains('caffe') || nameLower.contains('kavárna') || nameLower.contains('coffee') || nameLower.contains('espresso')) nasTag = 'kavarna';
        else if (typeLower.contains('pizza') || nameLower.contains('pizza')) nasTag = 'pizza';
        else if (typeLower.contains('chinese') || typeLower.contains('asian') || typeLower.contains('korean') || typeLower.contains('japanese') || typeLower.contains('ramen') || nameLower.contains('wok') || nameLower.contains('sushi') || nameLower.contains('asia')) nasTag = 'cina';
        else if (typeLower.contains('italian') || nameLower.contains('pasta') || nameLower.contains('risotto')) nasTag = 'italie';
        else if (typeLower.contains('vegan') || typeLower.contains('vegetarian') || nameLower.contains('poke') || nameLower.contains('salat')) nasTag = 'zdrave';

        stazeneRestaurace.add(
          Restaurant(
            id: placeId,
            name: name,
            type: type.replaceAll('_', ' '),
            tag: nasTag,
            img: imageUrl,
            lat: place['location']['latitude'],
            lon: place['location']['longitude'],
            rating: rating,
            price: cenaKc,
          )
        );
      }
    }

    debugPrint('✅ Celkem načteno restaurací: ${stazeneRestaurace.length}');

    if (stazeneRestaurace.isNotEmpty) {
      databaze = stazeneRestaurace;
    }

    vyfiltrujKarty(aktualniKategorie);
  } catch (chyba) {
    debugPrint('🔥 CHYBA PŘI STAHOVÁNÍ DAT: $chyba');
    vyfiltrujKarty('vse');
  } finally {
    setState(() { nacitamData = false; });
  }
}

  void vyfiltrujKarty(String vybranyTag) {
    setState(() {
      aktualniKategorie = vybranyTag;
      offsetZatazeni = Offset.zero;
      dobaAnimace = 0;

      dostupneKarty = databaze.where((karta) {
        bool sediTag = (vybranyTag == 'vse' || karta.tag == vybranyTag);
        if (!sediTag) return false;

        if (mojePoloha != null) {
          double vzdalenostMetry = Geolocator.distanceBetween(
            mojePoloha!.latitude, mojePoloha!.longitude,
            karta.lat, karta.lon
          );
          return (vzdalenostMetry / 1000) <= vybranaVzdalenost;
        }

        return true;
      }).toList();
    });
  }

  void _tlacitkoKliknuto(bool doprava, Restaurant karta) {
    HapticFeedback.mediumImpact();
    setState(() {
      dobaAnimace = 300;
      offsetZatazeni = Offset(doprava ? 500 : -500, 0);
    });
    Future.delayed(const Duration(milliseconds: 300), () {
      zahoditKartu(doprava, karta);
    });
  }

  void zahoditKartu(bool doprava, Restaurant odhozenaKarta) {
    setState(() {
      if (aktualniKategorie == 'vse') {
        if (doprava) {
          skore[odhozenaKarta.tag] = (skore[odhozenaKarta.tag] ?? 0) + 1;
        } else {
          skore[odhozenaKarta.tag] = (skore[odhozenaKarta.tag] ?? 0) - 1;
        }
      }

      if (doprava && !oblibeneRestauraceIds.contains(odhozenaKarta.id)) {
        oblibeneRestauraceIds.add(odhozenaKarta.id);
      }

      _ulozDoPameti();

      if (dostupneKarty.isNotEmpty) {
        dostupneKarty.removeAt(0);
      }

      offsetZatazeni = Offset.zero;
      dobaAnimace = 0;
    });
  }

  String _vypocitejViteze() {
  // Zkontroluj jestli uživatel vůbec něco swajpnul
  int celkemSwipe = skore.values.fold(0, (suma, hodnota) => suma + hodnota);
  
  if (celkemSwipe <= 0) {
    return 'Zkus swajpovat 😄';
  }

  // Najdi kategorii s nejvyšším skóre
  var viteznyVstup = skore.entries.reduce((a, b) => a.value > b.value ? a : b);
  
  // Pokud je skóre záporné nebo nulové, nic nedoporučuj
  if (viteznyVstup.value <= 0) {
    return 'Těžký výběr 🤷';
  }

  var viteznyNazev = kategorie.firstWhere(
    (k) => k['tag'] == viteznyVstup.key,
    orElse: () => {'nazev': 'Neznámé'},
  )['nazev'];
  
  return viteznyNazev ?? 'Neznámé';
}

  void _zobrazOblibeneOkno() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        final naseOblibene = databaze.where((r) => oblibeneRestauraceIds.contains(r.id)).toList();

        return Column(
          children: [
            const Padding(
              padding: EdgeInsets.all(20.0),
              child: Text(
                'Moje oblíbené ❤️',
                style: TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold)
              ),
            ),
            Expanded(
              child: naseOblibene.isEmpty
                  ? const Center(
                      child: Text('Zatím jsi nic nelajknul.', style: TextStyle(color: Colors.grey, fontSize: 16))
                    )
                  : ListView.builder(
                      itemCount: naseOblibene.length,
                      itemBuilder: (context, index) {
                        final karta = naseOblibene[index];
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: Colors.grey[800],
                            backgroundImage: NetworkImage(karta.img),
                          ),
                          title: Text(karta.name, style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold)),
                          subtitle: Text(karta.type, style: const TextStyle(color: Colors.grey)),
                          trailing: IconButton(
                            icon: const Text('🗑️', style: TextStyle(fontSize: 20)),
                            onPressed: () {
                              HapticFeedback.selectionClick();
                              setState(() {
                                oblibeneRestauraceIds.remove(karta.id);
                                _ulozDoPameti();
                              });
                              Navigator.pop(context);
                            },
                          ),
                        );
                      },
                    ),
            ),
          ],
        );
      }
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF121212),
      appBar: AppBar(
        backgroundColor: const Color(0xFF121212),
        elevation: 0,
        title: const Text(
          'FoodSwipe 🔥',
          style: TextStyle(color: Color(0xFFFF6B6B), fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        actions: [
          IconButton(
            icon: const Text('❤️', style: TextStyle(fontSize: 22)),
            onPressed: _zobrazOblibeneOkno,
          ),
          IconButton(
            icon: Icon(mojePoloha == null ? Icons.gps_not_fixed : Icons.gps_fixed),
            color: mojePoloha == null ? Colors.white : const Color(0xFFFF6B6B),
            onPressed: _ziskejPolohu,
          ),
        ],
      ),
      body: nacitamData
          ? const Center(
              child: CircularProgressIndicator(color: Color(0xFFFF6B6B)),
            )
          : Column(
              children: [
                _vykresliHorniMenu(),

                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20.0, vertical: 10.0),
                  child: Row(
                    children: [
                      Text(
                        'Vzdálenost: ${vybranaVzdalenost.toInt()} km',
                        style: const TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      Expanded(
                        child: Slider(
                          value: vybranaVzdalenost,
                          min: 1,
                          max: 20,
                          divisions: 19,
                          activeColor: const Color(0xFFFF6B6B),
                          inactiveColor: Colors.grey[800],
                          label: '${vybranaVzdalenost.toInt()} km',
                          onChanged: (novaHodnota) {
                            HapticFeedback.selectionClick();
                            setState(() {
                              vybranaVzdalenost = novaHodnota;
                            });
                            if (_debounce?.isActive ?? false) _debounce!.cancel();
                            _debounce = Timer(const Duration(milliseconds: 500), () {
                              _stahniDataZeServeru();
                            });
                          },
                        ),
                      ),
                    ],
                  ),
                ),

                Expanded(
                  child: Center(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: dostupneKarty.isEmpty
                          ? Center(
                              child: Text(
                                aktualniKategorie == 'vse'
                                    ? 'Největší chuť máš dnes na:\n🎉 ${_vypocitejViteze()} 🎉'
                                    : 'V této vzdálenosti už nic není 🍽️',
                                textAlign: TextAlign.center,
                                style: const TextStyle(color: Colors.white, fontSize: 24, fontWeight: FontWeight.bold),
                              ),
                            )
                          : Stack(
                              alignment: Alignment.center,
                              children: [
                                if (dostupneKarty.isNotEmpty)
                                  Builder(
                                    builder: (context) {
                                      final karta = dostupneKarty.first;
                                      return GestureDetector(
                                        onPanUpdate: (details) {
                                          setState(() {
                                            dobaAnimace = 0;
                                            offsetZatazeni += details.delta;
                                          });
                                        },
                                        onPanEnd: (details) {
                                          if (offsetZatazeni.dx > 100) {
                                            HapticFeedback.mediumImpact();
                                            _tlacitkoKliknuto(true, karta);
                                          } else if (offsetZatazeni.dx < -100) {
                                            HapticFeedback.mediumImpact();
                                            _tlacitkoKliknuto(false, karta);
                                          } else {
                                            setState(() {
                                              dobaAnimace = 300;
                                              offsetZatazeni = Offset.zero;
                                            });
                                          }
                                        },
                                        child: AnimatedContainer(
                                          duration: Duration(milliseconds: dobaAnimace),
                                          curve: Curves.easeOut,
                                          transform: Matrix4.translationValues(offsetZatazeni.dx, offsetZatazeni.dy, 0)
                                            ..rotateZ(offsetZatazeni.dx / 400),
                                          alignment: Alignment.center,
                                          child: _vykresliGrafikuKarty(karta, karta.lat, karta.lon),
                                        ),
                                      );
                                    }
                                  ),
                              ],
                            ),
                    ),
                  ),
                ),

                if (dostupneKarty.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 30.0, top: 15.0),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        FloatingActionButton(
                          heroTag: "btnNe",
                          backgroundColor: Colors.white,
                          elevation: 5,
                          child: const Text('❌', style: TextStyle(fontSize: 22)),
                          onPressed: () => _tlacitkoKliknuto(false, dostupneKarty.first),
                        ),
                        const SizedBox(width: 40),
                        FloatingActionButton(
                          heroTag: "btnAno",
                          backgroundColor: Colors.white,
                          elevation: 5,
                          child: const Text('💚', style: TextStyle(fontSize: 26)),
                          onPressed: () => _tlacitkoKliknuto(true, dostupneKarty.first),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  Widget _vykresliHorniMenu() {
    return Container(
      height: 70,
      margin: const EdgeInsets.only(top: 10),
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        itemCount: kategorie.length,
        itemBuilder: (context, index) {
          final kat = kategorie[index];
          final jeAktivni = aktualniKategorie == kat['tag'];

          return GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () {
              HapticFeedback.selectionClick();
              vyfiltrujKarty(kat['tag']!);
            },
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 15),
              child: Column(
                children: [
                  Text(kat['ikona']!, style: const TextStyle(fontSize: 24)),
                  const SizedBox(height: 4),
                  Text(
                    kat['nazev']!,
                    style: TextStyle(
                      color: jeAktivni ? const Color(0xFFFF6B6B) : Colors.grey,
                      fontWeight: jeAktivni ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _vykresliGrafikuKarty(Restaurant karta, double lat, double lon) {
    String dodatecneInfo = "";
    if (karta.rating != null) dodatecneInfo += "⭐ ${karta.rating}  ";
    if (karta.price != null && karta.price!.isNotEmpty) dodatecneInfo += "•  ${karta.price}  ";
    if (mojePoloha != null) {
      double vzdalenostMetry = Geolocator.distanceBetween(
        mojePoloha!.latitude, mojePoloha!.longitude, lat, lon
      );
      dodatecneInfo += "•  ${(vzdalenostMetry / 1000).toStringAsFixed(1)} km";
    }

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(24),
          color: Colors.grey[900],
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.6),
              blurRadius: 20,
              spreadRadius: -2,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(24),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Image.network(
                karta.img,
                fit: BoxFit.cover,
                loadingBuilder: (BuildContext context, Widget child, ImageChunkEvent? loadingProgress) {
                  if (loadingProgress == null) return child;
                  return Center(
                    child: CircularProgressIndicator(
                      color: const Color(0xFFFF6B6B),
                      value: loadingProgress.expectedTotalBytes != null
                          ? loadingProgress.cumulativeBytesLoaded / loadingProgress.expectedTotalBytes!
                          : null,
                    ),
                  );
                },
              ),
              Container(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [Colors.transparent, Colors.black.withOpacity(0.95)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                    stops: const [0.4, 1.0],
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(24.0),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      karta.name,
                      style: const TextStyle(color: Colors.white, fontSize: 32, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      karta.type,
                      style: const TextStyle(color: Colors.grey, fontSize: 16),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      dodatecneInfo,
                      style: const TextStyle(color: Colors.white70, fontSize: 14, fontWeight: FontWeight.w500),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
