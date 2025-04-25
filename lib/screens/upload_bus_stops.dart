import 'package:cloud_firestore/cloud_firestore.dart';

Future<void> uploadStaticBusStops() async {
  final stops = [
    {
      'name': 'DK A',
      'location': GeoPoint(5.358472063851898, 100.30358172014454),
    },
    {
      'name': 'Desasiswa Tekun',
      'location': GeoPoint(5.356164243999046, 100.29137000150655),
    },
    {
      'name': 'Padang Kawad USM',
      'location': GeoPoint(5.356575824397347, 100.29438698781404),
    },
    {
      'name': 'Aman Damai',
      'location': GeoPoint(5.355016860781792, 100.29772995685882),
    },
    {
      'name': 'Informm',
      'location': GeoPoint( 5.355756904620433, 100.30022534653023),
    },
    {
      'name': 'Stor Pusat Kimia',
      'location': GeoPoint(5.356432270401126, 100.30096914945585),
    },
    {
      'name': 'BHEPA',
      'location': GeoPoint(5.35921073913782, 100.30250488384392),
    },
    {
      'name': 'DKSK',
      'location': GeoPoint(5.359404468217731, 100.30451729410511),
    },
    {
      'name': 'SOLLAT',
      'location': GeoPoint(5.357330653809769, 100.30720848569456),
    },
    {
      'name': 'GSB',
      'location': GeoPoint(5.356934272035779, 100.30757773835158),
    },
    {
      'name': 'HBP',
      'location': GeoPoint(5.355040006814353, 100.30626811136635),
    },
    {
      'name': 'PHS',
      'location': GeoPoint(5.354941724482438, 100.30370271691852),
    },
    {
      'name': 'Eureka',
      'location': GeoPoint(5.354770901747802, 100.30414474646078),
    },
    {
      'name': 'Harapan',
      'location': GeoPoint(5.355241844849605, 100.29968061136645),
    },
    {
      'name': 'Indah Kembara',
      'location': GeoPoint(5.355791916604481, 100.29544875369481),
    },
    {
      'name': 'Jabatan Keselamatan',
      'location': GeoPoint(5.355676144659425, 100.29790864945589),
    },
    {
      'name': 'Nasi Kandar Subaidah USM',
      'location': GeoPoint(5.35689190629461, 100.30459688993344),
    },
    {
      'name': 'M07 USM',
      'location': GeoPoint(5.356677224370704, 100.28989391453047),
    },
    {
      'name': 'M01 USM',
      'location': GeoPoint(5.356141098470615, 100.28953752062004),
    },
  ];

  final batch = FirebaseFirestore.instance.batch();

  for (var stop in stops) {
    final docRef = FirebaseFirestore.instance.collection('busStops').doc(stop['name'] as String);
    batch.set(docRef, {
      'name': stop['name'],
      'location': stop['location'], // GeoPoint
    });
  }

  await batch.commit();
  print("✅ Static bus stops uploaded to Firestore.");
}
