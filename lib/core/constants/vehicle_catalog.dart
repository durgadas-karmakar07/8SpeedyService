/// Vehicle catalog used by "Add Vehicle": type -> brand -> model.
///
/// Images in `assets/vehicles/` are original illustrations (no brand logos or
/// manufacturer photos). Brand and model names are shown as plain text only.
///
/// `category` is the pricing group used by the server
/// (`public.vehicle_category_for_body` must map the same keys).
library;

class BodyType {
  const BodyType({
    required this.key,
    required this.title,
    required this.subtitle,
    required this.category,
    required this.brands,
    this.hasFuel = true,
  });

  final String key;
  final String title;
  final String subtitle;
  final String category;
  final Map<String, List<String>> brands;
  final bool hasFuel;

  String get asset => 'assets/vehicles/$key.png';
}

class FuelOption {
  const FuelOption(this.key, this.label);
  final String key;
  final String label;
}

class VehicleCatalog {
  VehicleCatalog._();

  static const String otherBrand = 'Other';

  static const List<FuelOption> fuels = <FuelOption>[
    FuelOption('PETROL', 'Petrol'),
    FuelOption('DIESEL', 'Diesel'),
    FuelOption('CNG', 'CNG'),
    FuelOption('ELECTRIC', 'Electric'),
  ];

  static const List<BodyType> bodyTypes = <BodyType>[
    BodyType(
      key: 'scooter',
      title: 'Scooty',
      subtitle: 'Activa, Jupiter, Access, EV',
      category: 'two_wheeler',
      brands: <String, List<String>>{
        'Honda': <String>['Activa 6G', 'Activa 125', 'Dio', 'Grazia'],
        'TVS': <String>[
          'Jupiter',
          'Jupiter 125',
          'Ntorq 125',
          'Scooty Pep+',
          'Scooty Zest',
          'iQube',
        ],
        'Suzuki': <String>['Access 125', 'Burgman Street', 'Avenis'],
        'Hero': <String>[
          'Pleasure+',
          'Destini 125',
          'Maestro Edge',
          'Xoom',
          'Vida V1',
        ],
        'Yamaha': <String>['Fascino 125', 'RayZR 125', 'Aerox 155'],
        'Ola Electric': <String>['S1 Pro', 'S1 Air', 'S1 X'],
        'Ather': <String>['450X', '450S', 'Rizta'],
        'Bajaj': <String>['Chetak'],
        'Vespa': <String>['VXL 125', 'SXL 125'],
      },
    ),
    BodyType(
      key: 'motorcycle',
      title: 'Bike',
      subtitle: 'Splendor, Pulsar, Shine, Bullet',
      category: 'two_wheeler',
      brands: <String, List<String>>{
        'Hero': <String>[
          'Splendor Plus',
          'Super Splendor',
          'HF Deluxe',
          'Passion Pro',
          'Glamour',
          'Xtreme 160R',
        ],
        'Honda': <String>[
          'Shine',
          'SP 125',
          'Unicorn',
          'Livo',
          'Hornet 2.0',
          'CB350',
        ],
        'Bajaj': <String>[
          'Pulsar 125',
          'Pulsar 150',
          'Pulsar NS200',
          'Platina',
          'CT 110',
          'Avenger',
          'Dominar',
        ],
        'TVS': <String>[
          'Apache RTR 160',
          'Apache RTR 200',
          'Raider 125',
          'Radeon',
          'Star City+',
          'Sport',
          'Ronin',
        ],
        'Royal Enfield': <String>[
          'Classic 350',
          'Bullet 350',
          'Hunter 350',
          'Meteor 350',
          'Himalayan',
        ],
        'Yamaha': <String>['FZ-S', 'FZ-X', 'MT-15', 'R15'],
        'Suzuki': <String>['Gixxer', 'Gixxer SF'],
        'KTM': <String>['Duke 200', 'Duke 390', 'RC 200'],
        'Jawa': <String>['Jawa 42', 'Jawa 350'],
      },
    ),
    BodyType(
      key: 'hatchback',
      title: 'Hatchback',
      subtitle: 'Alto, Wagon R, Swift, i20',
      category: 'four_wheeler',
      brands: <String, List<String>>{
        'Maruti Suzuki': <String>[
          'Alto K10',
          'Wagon R',
          'Swift',
          'Baleno',
          'Celerio',
          'S-Presso',
          'Ignis',
        ],
        'Hyundai': <String>['Grand i10 Nios', 'i20'],
        'Tata': <String>['Tiago', 'Altroz'],
        'Renault': <String>['Kwid'],
        'Toyota': <String>['Glanza'],
      },
    ),
    BodyType(
      key: 'sedan',
      title: 'Sedan',
      subtitle: 'Dzire, City, Amaze, Verna',
      category: 'four_wheeler',
      brands: <String, List<String>>{
        'Maruti Suzuki': <String>['Dzire', 'Ciaz'],
        'Honda': <String>['Amaze', 'City'],
        'Hyundai': <String>['Aura', 'Verna'],
        'Tata': <String>['Tigor'],
        'Skoda': <String>['Slavia'],
        'Volkswagen': <String>['Virtus'],
        'Toyota': <String>['Etios'],
      },
    ),
    BodyType(
      key: 'suv',
      title: 'SUV / MUV',
      subtitle: 'Nexon, Creta, Scorpio, Ertiga',
      category: 'four_wheeler',
      brands: <String, List<String>>{
        'Maruti Suzuki': <String>[
          'Brezza',
          'Ertiga',
          'XL6',
          'Fronx',
          'Grand Vitara',
        ],
        'Hyundai': <String>['Creta', 'Venue', 'Exter'],
        'Tata': <String>['Punch', 'Nexon', 'Harrier', 'Safari'],
        'Mahindra': <String>[
          'Scorpio-N',
          'Scorpio Classic',
          'Bolero',
          'Bolero Neo',
          'XUV 3XO',
          'XUV700',
          'Thar',
        ],
        'Kia': <String>['Sonet', 'Seltos', 'Carens'],
        'Toyota': <String>[
          'Innova Crysta',
          'Innova Hycross',
          'Fortuner',
          'Urban Cruiser Hyryder',
        ],
        'Renault': <String>['Kiger', 'Triber'],
        'Nissan': <String>['Magnite'],
        'MG': <String>['Hector', 'Astor'],
      },
    ),
    BodyType(
      key: 'e_rickshaw',
      title: 'Toto / E-Rickshaw',
      subtitle: 'Battery rickshaw, e-loader',
      category: 'cycle_toto',
      hasFuel: false,
      brands: <String, List<String>>{
        'Mahindra': <String>['Treo', 'e-Alfa Mini'],
        'YC Electric': <String>['Yatri', 'Yatri Super'],
        'Saera': <String>['Mayuri'],
        'Lohia': <String>['Humsafar', 'Narain'],
        'Kinetic Green': <String>['Safar Smart'],
        'Local / Unbranded': <String>['Passenger Toto', 'Loader Toto'],
      },
    ),
    BodyType(
      key: 'auto_rickshaw',
      title: 'Auto Rickshaw',
      subtitle: 'CNG / Diesel 3-wheeler',
      category: 'four_wheeler',
      brands: <String, List<String>>{
        'Bajaj': <String>['RE Compact', 'Maxima'],
        'Piaggio': <String>['Ape City', 'Ape Xtra'],
        'TVS': <String>['King'],
        'Mahindra': <String>['Alfa'],
        'Atul': <String>['Gem'],
      },
    ),
    BodyType(
      key: 'cycle',
      title: 'Cycle',
      subtitle: 'Normal, geared, e-cycle',
      category: 'cycle_toto',
      hasFuel: false,
      brands: <String, List<String>>{
        'Hero Cycles': <String>['Standard', 'Geared', 'Kids', 'E-Cycle'],
        'Avon': <String>['Standard', 'Geared', 'Kids'],
        'Atlas': <String>['Standard', 'Geared'],
        'Hercules': <String>['Standard', 'Geared'],
        'BSA': <String>['Standard', 'Geared'],
        'Btwin': <String>['Rockrider', 'Riverside'],
        'Firefox': <String>['Geared', 'Road'],
      },
    ),
    BodyType(
      key: 'pickup',
      title: 'Pickup / Tempo',
      subtitle: 'Tata Ace, Bolero Pickup, Dost',
      category: 'heavy_vehicle',
      brands: <String, List<String>>{
        'Tata': <String>['Ace', 'Intra', 'Yodha'],
        'Mahindra': <String>['Bolero Pickup', 'Jeeto', 'Supro'],
        'Ashok Leyland': <String>['Dost', 'Bada Dost'],
        'Maruti Suzuki': <String>['Super Carry', 'Eeco'],
        'Force': <String>['Traveller'],
      },
    ),
    BodyType(
      key: 'truck',
      title: 'Truck / Bus',
      subtitle: '407, LPT, Eicher, bus',
      category: 'heavy_vehicle',
      brands: <String, List<String>>{
        'Tata': <String>['407', 'LPT', 'Signa', 'Starbus'],
        'Ashok Leyland': <String>['Ecomet', 'Boss', 'Partner'],
        'Eicher': <String>['Pro 2000', 'Pro 3000', 'Skyline'],
        'BharatBenz': <String>['1215R', '1617R'],
        'Mahindra': <String>['Furio', 'Blazo'],
      },
    ),
  ];

  static BodyType? bodyFor(String? key) {
    if (key == null) return null;
    for (final b in bodyTypes) {
      if (b.key == key) return b;
    }
    return null;
  }

  /// Image for a booking / saved vehicle. Falls back to the pricing category
  /// for old bookings made before body types existed.
  static String assetFor({String? bodyType, String? category}) {
    final body = bodyFor(bodyType);
    if (body != null) return body.asset;
    switch (category) {
      case 'cycle_toto':
        return 'assets/vehicles/e_rickshaw.png';
      case 'four_wheeler':
        return 'assets/vehicles/hatchback.png';
      case 'heavy_vehicle':
        return 'assets/vehicles/pickup.png';
      default:
        return 'assets/vehicles/scooter.png';
    }
  }

  /// "WB38AB1234" -> "WB 38 AB 1234" (best effort, display only).
  static String formatReg(String? reg) {
    if (reg == null || reg.isEmpty) return '';
    final m = RegExp(r'^([A-Z]{2})(\d{1,2})([A-Z]{0,3})(\d{1,4})$')
        .firstMatch(reg);
    if (m == null) return reg;
    return <String?>[
      m.group(1),
      m.group(2),
      m.group(3),
      m.group(4),
    ].where((p) => p != null && p.isNotEmpty).join(' ');
  }
}
