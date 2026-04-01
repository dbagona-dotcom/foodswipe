import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../data/database.dart';
import '../models/restaurant.dart';

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

  Future<void> _ziskejPolohu() async {
    bool sluzbaZapnuta = await Geolocator.isLocationServiceEnabled();
    if (!sluzbaZapnuta) return;

    LocationPermission opravneni = await Geolocator.checkPermission();
    if (opravneni == LocationPermission.denied) {
      opravneni = await Geolocator.requestPermission();
      if (opravneni == LocationPermission.denied) return;
    }
    if (opravneni == LocationPermission.deniedForever) return;

    Position poloha = await Geolocator.getCurrentPosition();
    setState(() {
      mojePoloha = poloha;
      vyfiltrujKarty(aktualniKategorie);
    });
  }

  Future<void> _stahniDataZeServeru() async {
    await _ziskejPolohu();

    if (mojePoloha == null) {
      debugPrint('🔥 CHYBA: Nepodařilo se získat polohu.');
      vyfiltrujKarty('vse');
      setState(() { nacitamData = false; });
      return;
    }

    try {
      const String apiKey = 'AIzaSyD0-jEMg-OxcEXgXd2QASX2wR7N7YdRaV8';
      final adresa = Uri.parse('https://places.googleapis.com/v1/places:searchNearby');
      double radiusMetry = vybranaVzdalenost * 1000;

      final body = jsonEncode({
        "includedTypes": ["restaurant", "fast_food_restaurant", "cafe", "pizza_restaurant"],
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
      });

      final odpoved = await http.post(
        adresa,
        headers: {
          'Content-Type': 'application/json',
          'X-Goog-Api-Key': apiKey,
          'X-Goog-FieldMask': 'places.id,places.displayName.text,places.primaryType,places.location,places.photos,places.rating,places.priceLevel'
        },
        body: body,
      ).timeout(const Duration(seconds: 15));

      if (odpoved.statusCode == 200) {
        final data = jsonDecode(odpoved.body);
        final places = data['places'] as List?;

        if (places != null) {
          List<Restaurant> stazeneRestaurace = [];

          for (var place in places) {
            String type = place['primaryType'] ?? 'restaurant';

            // Filtrování nežádoucích typů
            final List<String> zakazaneTypy = [
              'hotel', 'lodging', 'bed_and_breakfast', 'shopping_mall',
              'supermarket', 'grocery_store', 'convenience_store',
              'gas_station', 'pharmacy', 'beauty_salon', 'spa',
              'car_wash', 'parking', 'bank', 'atm', 'clothing_store',
              'department_store', 'furniture_store', 'electronics_store',
              'home_goods_store', 'pet_store', 'florist', 'gym', 'library',
            ];
            if (zakazaneTypy.contains(type)) continue;

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

            // Mapování tagu podle typu a názvu
            String nameLower = name.toLowerCase();
            String typeLower = type.toLowerCase();
            String nasTag = 'klasika';

            // FASTFOOD
            if (typeLower.contains('fast_food') ||
                nameLower.contains('mcdonald') ||
                nameLower.contains('mac donald') ||
                nameLower.contains('kfc') ||
                nameLower.contains('burger king') ||
                nameLower.contains('subway') ||
                nameLower.contains('taco bell') ||
                nameLower.contains('wendy') ||
                nameLower.contains('popeyes') ||
                nameLower.contains('five guys') ||
                nameLower.contains('domino') ||
                nameLower.contains('papa john') ||
                nameLower.contains('chipotle') ||
                nameLower.contains('panda express') ||
                nameLower.contains('arby') ||
                nameLower.contains('kebab') ||
                nameLower.contains('kebap') ||
                nameLower.contains('döner') ||
                nameLower.contains('doner') ||
                nameLower.contains('gyros') ||
                nameLower.contains('shawarma') ||
                nameLower.contains('shawurma') ||
                nameLower.contains('lahmacun') ||
                nameLower.contains('falafel') ||
                nameLower.contains('pita') ||
                nameLower.contains('wrap') ||
                nameLower.contains('hot dog') ||
                nameLower.contains('hotdog') ||
                nameLower.contains('párek') ||
                nameLower.contains('friterie') ||
                nameLower.contains('frytárna') ||
                nameLower.contains('snack') ||
                nameLower.contains('občerstvení') ||
                nameLower.contains('rychlé jídlo') ||
                nameLower.contains('bufet') ||
                nameLower.contains('jídelna') ||
                nameLower.contains('kantýna') ||
                nameLower.contains('stánek') ||
                nameLower.contains('okénko') ||
                nameLower.contains('street food') ||
                nameLower.contains('food truck') ||
                nameLower.contains('take away') ||
                nameLower.contains('takeaway') ||
                nameLower.contains('express')) {
              nasTag = 'fastfood';
            }

            // BURGER
            else if (typeLower.contains('hamburger') ||
                nameLower.contains('burger') ||
                nameLower.contains('burgers') ||
                nameLower.contains('smash') ||
                nameLower.contains('smashburger') ||
                nameLower.contains('hamburger') ||
                nameLower.contains('hamburgr') ||
                nameLower.contains('cheeseburger') ||
                nameLower.contains('bbq burger') ||
                nameLower.contains('gourmet burger') ||
                nameLower.contains('craft burger') ||
                nameLower.contains('patty') ||
                nameLower.contains('& bun') ||
                nameLower.contains('bun &')) {
              nasTag = 'burger';
            }

            // KAVÁRNA
            else if (typeLower.contains('cafe') ||
                typeLower.contains('coffee') ||
                typeLower.contains('bakery') ||
                typeLower.contains('dessert') ||
                typeLower.contains('ice_cream') ||
                typeLower.contains('tea') ||
                nameLower.contains('café') ||
                nameLower.contains('cafe') ||
                nameLower.contains('caffe') ||
                nameLower.contains('caffè') ||
                nameLower.contains('caffé') ||
                nameLower.contains('kafe') ||
                nameLower.contains('kavárna') ||
                nameLower.contains('kaviareň') ||
                nameLower.contains('coffee') ||
                nameLower.contains('espresso') ||
                nameLower.contains('cappuccino') ||
                nameLower.contains('latte') ||
                nameLower.contains('barista') ||
                nameLower.contains('roastery') ||
                nameLower.contains('pražírna') ||
                nameLower.contains('starbucks') ||
                nameLower.contains('costa coffee') ||
                nameLower.contains('croissant') ||
                nameLower.contains('pekárna') ||
                nameLower.contains('pekáreň') ||
                nameLower.contains('cukrárna') ||
                nameLower.contains('cukráreň') ||
                nameLower.contains('zákusky') ||
                nameLower.contains('dorty') ||
                nameLower.contains('patisserie') ||
                nameLower.contains('pâtisserie') ||
                nameLower.contains('boulangerie') ||
                nameLower.contains('waffle') ||
                nameLower.contains('wafl') ||
                nameLower.contains('palačinka') ||
                nameLower.contains('crepe') ||
                nameLower.contains('crêpe') ||
                nameLower.contains('pancake') ||
                nameLower.contains('zmrzlina') ||
                nameLower.contains('gelato') ||
                nameLower.contains('gelateria') ||
                nameLower.contains('ice cream') ||
                nameLower.contains('frozen yogurt') ||
                nameLower.contains('bubble tea') ||
                nameLower.contains('boba') ||
                nameLower.contains('milkshake') ||
                nameLower.contains('čajovna') ||
                nameLower.contains('tearoom') ||
                nameLower.contains('čaj')) {
              nasTag = 'kavarna';
            }

            // PIZZA
            else if (typeLower.contains('pizza') ||
                nameLower.contains('pizza') ||
                nameLower.contains('pizzeria') ||
                nameLower.contains('pizzéria') ||
                nameLower.contains('pizzerie') ||
                nameLower.contains('calzone') ||
                nameLower.contains('focaccia') ||
                nameLower.contains('neapolitan') ||
                nameLower.contains('margherita') ||
                nameLower.contains('diavola') ||
                nameLower.contains('wood fire') ||
                nameLower.contains('woodfire') ||
                nameLower.contains('kamenná pec')) {
              nasTag = 'pizza';
            }

            // ČÍNA / ASIE
            else if (typeLower.contains('chinese') ||
                typeLower.contains('asian') ||
                typeLower.contains('japanese') ||
                typeLower.contains('vietnamese') ||
                typeLower.contains('thai') ||
                typeLower.contains('korean') ||
                typeLower.contains('ramen') ||
                typeLower.contains('sushi') ||
                typeLower.contains('noodle') ||
                nameLower.contains('chinese') ||
                nameLower.contains('china') ||
                nameLower.contains('čína') ||
                nameLower.contains('číňan') ||
                nameLower.contains('čínská') ||
                nameLower.contains('dim sum') ||
                nameLower.contains('dumpling') ||
                nameLower.contains('jiaozi') ||
                nameLower.contains('baozi') ||
                nameLower.contains('peking') ||
                nameLower.contains('szechuan') ||
                nameLower.contains('sichuan') ||
                nameLower.contains('wonton') ||
                nameLower.contains('chow mein') ||
                nameLower.contains('wok') ||
                nameLower.contains('vietnam') ||
                nameLower.contains('viet') ||
                nameLower.contains('pho') ||
                nameLower.contains('phở') ||
                nameLower.contains('bun bo') ||
                nameLower.contains('bún bò') ||
                nameLower.contains('banh mi') ||
                nameLower.contains('bánh mì') ||
                nameLower.contains('spring roll') ||
                nameLower.contains('japan') ||
                nameLower.contains('japonsk') ||
                nameLower.contains('sushi') ||
                nameLower.contains('sashimi') ||
                nameLower.contains('ramen') ||
                nameLower.contains('udon') ||
                nameLower.contains('soba') ||
                nameLower.contains('tempura') ||
                nameLower.contains('teriyaki') ||
                nameLower.contains('yakitori') ||
                nameLower.contains('tonkatsu') ||
                nameLower.contains('gyoza') ||
                nameLower.contains('miso') ||
                nameLower.contains('matcha') ||
                nameLower.contains('onigiri') ||
                nameLower.contains('bento') ||
                nameLower.contains('izakaya') ||
                nameLower.contains('teppanyaki') ||
                nameLower.contains('korean') ||
                nameLower.contains('korea') ||
                nameLower.contains('korejsk') ||
                nameLower.contains('kimchi') ||
                nameLower.contains('bibimbap') ||
                nameLower.contains('bulgogi') ||
                nameLower.contains('kbbq') ||
                nameLower.contains('thai') ||
                nameLower.contains('thajsk') ||
                nameLower.contains('pad thai') ||
                nameLower.contains('tom yum') ||
                nameLower.contains('green curry') ||
                nameLower.contains('asia') ||
                nameLower.contains('asian') ||
                nameLower.contains('orient') ||
                nameLower.contains('noodle') ||
                nameLower.contains('nudle') ||
                nameLower.contains('nudl') ||
                nameLower.contains('ni hao') ||
                nameLower.contains('pan asian') ||
                nameLower.contains('pan-asian') ||
                nameLower.contains('india') ||
                nameLower.contains('indick') ||
                nameLower.contains('curry') ||
                nameLower.contains('tikka') ||
                nameLower.contains('masala') ||
                nameLower.contains('tandoor') ||
                nameLower.contains('biryani') ||
                nameLower.contains('naan') ||
                nameLower.contains('samosa') ||
                nameLower.contains('pakista')) {
              nasTag = 'cina';
            }

            // ITÁLIE
            else if (typeLower.contains('italian') ||
                nameLower.contains('italian') ||
                nameLower.contains('italiano') ||
                nameLower.contains('italiana') ||
                nameLower.contains('italská') ||
                nameLower.contains('italske') ||
                nameLower.contains('italia') ||
                nameLower.contains('italy') ||
                nameLower.contains('ristorante') ||
                nameLower.contains('trattoria') ||
                nameLower.contains('osteria') ||
                nameLower.contains('enoteca') ||
                nameLower.contains('locanda') ||
                nameLower.contains('taverna') ||
                nameLower.contains('pasta') ||
                nameLower.contains('spaghetti') ||
                nameLower.contains('fettuccine') ||
                nameLower.contains('tagliatelle') ||
                nameLower.contains('pappardelle') ||
                nameLower.contains('linguine') ||
                nameLower.contains('penne') ||
                nameLower.contains('rigatoni') ||
                nameLower.contains('gnocchi') ||
                nameLower.contains('risotto') ||
                nameLower.contains('carbonara') ||
                nameLower.contains('lasagna') ||
                nameLower.contains('lasagne') ||
                nameLower.contains('ravioli') ||
                nameLower.contains('tortellini') ||
                nameLower.contains('ossobuco') ||
                nameLower.contains('tiramisu') ||
                nameLower.contains('tiramisù') ||
                nameLower.contains('bruschetta') ||
                nameLower.contains('antipasto') ||
                nameLower.contains('prosciutto') ||
                nameLower.contains('mozzarella') ||
                nameLower.contains('parmigiano') ||
                nameLower.contains('arancini') ||
                nameLower.contains('minestrone') ||
                nameLower.contains('bolognese') ||
                nameLower.contains('amatriciana') ||
                nameLower.contains('milano') ||
                nameLower.contains('napoli') ||
                nameLower.contains('venezia') ||
                nameLower.contains('toscana') ||
                nameLower.contains('sicilia')) {
              nasTag = 'italie';
            }

            // ZDRAVÉ
            else if (typeLower.contains('vegan') ||
                typeLower.contains('vegetarian') ||
                typeLower.contains('salad') ||
                typeLower.contains('health') ||
                typeLower.contains('organic') ||
                nameLower.contains('vegan') ||
                nameLower.contains('vegán') ||
                nameLower.contains('vegansk') ||
                nameLower.contains('vegetarian') ||
                nameLower.contains('vegetariánsk') ||
                nameLower.contains('plant based') ||
                nameLower.contains('plant-based') ||
                nameLower.contains('raw food') ||
                nameLower.contains('gluten free') ||
                nameLower.contains('gluten-free') ||
                nameLower.contains('bez lepku') ||
                nameLower.contains('bio ') ||
                nameLower.contains('organic') ||
                nameLower.contains('zdravě') ||
                nameLower.contains('zdravá') ||
                nameLower.contains('zdravé') ||
                nameLower.contains('poke') ||
                nameLower.contains('bowl') ||
                nameLower.contains('salát') ||
                nameLower.contains('salad') ||
                nameLower.contains('smoothie') ||
                nameLower.contains('detox') ||
                nameLower.contains('fresh') ||
                nameLower.contains('fitness') ||
                nameLower.contains('low carb') ||
                nameLower.contains('keto') ||
                nameLower.contains('protein') ||
                nameLower.contains('superfood') ||
                nameLower.contains('acai') ||
                nameLower.contains('açaí') ||
                nameLower.contains('granola') ||
                nameLower.contains('avocado') ||
                nameLower.contains('avokádo') ||
                nameLower.contains('hummus') ||
                nameLower.contains('quinoa') ||
                nameLower.contains('tofu') ||
                nameLower.contains('tempeh') ||
                nameLower.contains('green ') ||
                nameLower.contains('zelená') ||
                nameLower.contains('zelenina') ||
                nameLower.contains('zeleninový')) {
              nasTag = 'zdrave';
            }

            // KLASIKA – vše ostatní + explicitně česká kuchyně
            else {
              if (typeLower.contains('czech') ||
                  typeLower.contains('european') ||
                  typeLower.contains('steakhouse') ||
                  nameLower.contains('restaurace') ||
                  nameLower.contains('hospoda') ||
                  nameLower.contains('hostinec') ||
                  nameLower.contains('pivnice') ||
                  nameLower.contains('šenk') ||
                  nameLower.contains('krčma') ||
                  nameLower.contains('česká') ||
                  nameLower.contains('moravsk') ||
                  nameLower.contains('svíčková') ||
                  nameLower.contains('guláš') ||
                  nameLower.contains('řízek') ||
                  nameLower.contains('knedlík') ||
                  nameLower.contains('bramborák') ||
                  nameLower.contains('grill') ||
                  nameLower.contains('steakhouse') ||
                  nameLower.contains('steak') ||
                  nameLower.contains('žebírka') ||
                  nameLower.contains('zvěřina') ||
                  nameLower.contains('schnitzel') ||
                  nameLower.contains('wiener') ||
                  nameLower.contains('brasserie')) {
                nasTag = 'klasika';
              }
            }

            stazeneRestaurace.add(
              Restaurant(
                id: place['id'].toString(),
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

          if (stazeneRestaurace.isNotEmpty) {
            databaze = stazeneRestaurace;
          }
        }
        vyfiltrujKarty(aktualniKategorie);
      } else {
        throw Exception('Chybový kód od Googlu: ${odpoved.statusCode}\nOdpověď: ${odpoved.body}');
      }
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
    var viteznyTag = skore.entries.reduce((a, b) => a.value > b.value ? a : b).key;
    var viteznyNazev = kategorie.firstWhere((k) => k['tag'] == viteznyTag)['nazev'];
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
