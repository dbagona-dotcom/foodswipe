class Restaurant {
  final String id; // OPRAVA: ID je nyní String kvůli formátu z Googlu
  final String name;
  final String type;
  final String tag;
  final String img;
  final double lat;
  final double lon;
  final double? rating;
  final String? price;

  Restaurant({
    required this.id,
    required this.name,
    required this.type,
    required this.tag,
    required this.img,
    required this.lat,
    required this.lon,
    this.rating,
    this.price,
  });
}