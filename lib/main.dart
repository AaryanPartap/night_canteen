import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_map/flutter_map.dart'; // OpenStreetMap
import 'package:latlong2/latlong.dart'; // Coordinates
import 'package:geolocator/geolocator.dart'; // GPS
import 'package:http/http.dart' as http; // API Calls
import 'dart:convert'; // JSON Parsing
import 'dart:async'; // Timer
import 'dart:math';
import 'firebase_options.dart';

const bool isTestMode = true;

// --- GLOBAL STATE ---
List<CartItem> globalCart = [];
final ValueNotifier<ThemeMode> themeNotifier = ValueNotifier(ThemeMode.light);

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    // Firebase may already be initialized on iOS
    if (!e.toString().contains('already exists')) {
      rethrow;
    }
  }

  final prefs = await SharedPreferences.getInstance();
  final savedName = prefs.getString('studentName');
  final savedEmail = prefs.getString('studentEmail');
  final savedAddress = prefs.getString('savedAddress');

  Widget initialScreen = const RoleSelectionScreen();

  if (savedName != null && savedEmail != null) {
    if (savedAddress != null && savedAddress.isNotEmpty) {
      initialScreen = HomeScreen(studentName: savedName, studentEmail: savedEmail);
    } else {
      initialScreen = const AddressSelectionScreen(isEditing: false);
    }
  }

  runApp(NightCanteenApp(initialScreen: initialScreen));
}

// --- HELPER: IMPROVED ADDRESS PARSER ---
// This extracts specific details to match "Swiggy-like" precision
String _parseOSMAddress(Map<String, dynamic> data) {
  final addr = data['address'] ?? {};

  String houseNumber = addr['house_number'] ?? '';
  String building = addr['building'] ?? addr['amenity'] ?? '';
  String road = addr['road'] ?? addr['pedestrian'] ?? addr['street'] ?? '';
  String subLocality = addr['suburb'] ?? addr['neighbourhood'] ?? addr['residential'] ?? '';
  String sector = addr['quarter'] ?? '';
  String city = addr['city'] ?? addr['town'] ?? addr['village'] ?? '';
  String postcode = addr['postcode'] ?? '';

  List<String> parts = [];

  if (houseNumber.isNotEmpty) parts.add(houseNumber);
  if (building.isNotEmpty && building != houseNumber) parts.add(building);
  if (road.isNotEmpty) parts.add(road);
  if (sector.isNotEmpty) parts.add(sector);
  if (subLocality.isNotEmpty && subLocality != sector) parts.add(subLocality);
  if (city.isNotEmpty) parts.add(city);
  if (postcode.isNotEmpty) parts.add(postcode);

  if (parts.length < 2) {
    return data['display_name'] ?? "Unknown Location";
  }

  return parts.join(', ');
}

// --- HELPER: GET CURRENT LOCATION & ADDRESS ---
Future<String?> determinePositionAndAddress() async {
  bool serviceEnabled;
  LocationPermission permission;

  serviceEnabled = await Geolocator.isLocationServiceEnabled();
  if (!serviceEnabled) {
    return "Location services are disabled. Please enable GPS.";
  }

  permission = await Geolocator.checkPermission();
  if (permission == LocationPermission.denied) {
    permission = await Geolocator.requestPermission();
    if (permission == LocationPermission.denied) {
      return "Location permissions are denied.";
    }
  }

  if (permission == LocationPermission.deniedForever) {
    return "Location permissions are permanently denied.";
  }

  try {
    Position position = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.bestForNavigation, // High Accuracy
      timeLimit: const Duration(seconds: 8),
    );

    // Zoom 18 is standard, asking for address details
    final url = Uri.parse(
        'https://nominatim.openstreetmap.org/reverse?format=json&lat=${position.latitude}&lon=${position.longitude}&zoom=18&addressdetails=1');

    final response = await http.get(url, headers: {
      'User-Agent': 'com.example.pec_night_canteen',
    });

    if (response.statusCode == 200) {
      final data = json.decode(response.body);
      return _parseOSMAddress(data);
    } else {
      return "Unable to fetch address details.";
    }
  } catch (e) {
    return "Error: ${e.toString()}";
  }
}

/// ================= ROOT =================
class NightCanteenApp extends StatelessWidget {
  final Widget initialScreen;

  const NightCanteenApp({super.key, required this.initialScreen});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: themeNotifier,
      builder: (context, currentMode, child) {
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          title: 'Hostel Night Canteen',
          themeMode: currentMode,
          theme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.light,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepOrange,
              brightness: Brightness.light,
            ),
            scaffoldBackgroundColor: Colors.grey[50],
          ),
          darkTheme: ThemeData(
            useMaterial3: true,
            brightness: Brightness.dark,
            colorScheme: ColorScheme.fromSeed(
              seedColor: Colors.deepOrange,
              brightness: Brightness.dark,
            ),
            scaffoldBackgroundColor: const Color(0xFF121212),
            cardColor: const Color(0xFF1E1E1E),
          ),
          home: initialScreen,
        );
      },
    );
  }
}

/// ================= MODELS =================
class CartItem {
  String name;
  int price;
  int qty;

  CartItem(this.name, this.price, this.qty);
}

/// ================= WIDGETS =================

class FoodTypeIcon extends StatelessWidget {
  final String type;
  const FoodTypeIcon({super.key, required this.type});

  @override
  Widget build(BuildContext context) {
    Color color;
    if (type == 'veg') {
      color = Colors.green;
    } else if (type == 'nonveg') {
      color = Colors.red;
    } else {
      return const SizedBox.shrink();
    }

    return Container(
      width: 14,
      height: 14,
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(4),
      ),
      padding: const EdgeInsets.all(2),
      child: Container(
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

/// ================= MAP PICKER (IMPROVED) =================
class LocationPickerScreen extends StatefulWidget {
  const LocationPickerScreen({super.key});

  @override
  State<LocationPickerScreen> createState() => _LocationPickerScreenState();
}

class _LocationPickerScreenState extends State<LocationPickerScreen> {
  final MapController mapController = MapController();
  LatLng selectedLocation = const LatLng(30.7650, 76.7865);
  String address = "Fetching location details...";
  bool isLoading = true;
  Timer? _dragDebounce;

  @override
  void initState() {
    super.initState();
    _locateUser();
  }

  Future<void> _locateUser() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      if(mounted) setState(() { address = "GPS Disabled"; isLoading = false; });
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) return;
    }

    try {
      Position position = await Geolocator.getCurrentPosition(
          desiredAccuracy: LocationAccuracy.bestForNavigation, // High Accuracy
          timeLimit: const Duration(seconds: 5)
      );
      LatLng userPos = LatLng(position.latitude, position.longitude);

      if(mounted) {
        setState(() {
          selectedLocation = userPos;
        });
        mapController.move(userPos, 18.0); // Closer zoom
        _getAddressFromLatLng(userPos);
      }
    } catch (e) {
      if(mounted) setState(() { address = "Error finding you"; isLoading = false; });
    }
  }

  // Live Address Fetcher
  Future<void> _getAddressFromLatLng(LatLng point) async {
    setState(() {
      isLoading = true;
      address = "Refining location...";
    });

    try {
      final url = Uri.parse(
          'https://nominatim.openstreetmap.org/reverse?format=json&lat=${point.latitude}&lon=${point.longitude}&zoom=18&addressdetails=1');

      final response = await http.get(url, headers: {
        'User-Agent': 'com.example.pec_night_canteen',
      });

      if (response.statusCode == 200) {
        final data = json.decode(response.body);
        if(mounted) {
          setState(() {
            address = _parseOSMAddress(data);
            isLoading = false;
          });
        }
      }
    } catch (e) {
      if(mounted) {
        setState(() {
          address = "Error fetching address";
          isLoading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Pick Location"),
        actions: [
          IconButton(
            icon: const Icon(Icons.my_location),
            onPressed: _locateUser,
          ),
          IconButton(
            icon: const Icon(Icons.check),
            onPressed: () {
              Navigator.pop(context, address);
            },
          )
        ],
      ),
      body: Stack(
        children: [
          FlutterMap(
            mapController: mapController,
            options: MapOptions(
              initialCenter: selectedLocation,
              initialZoom: 18.0,
              // When map is dragged, update location center
              onPositionChanged: (pos, hasGesture) {
                if (hasGesture) {
                  if (_dragDebounce?.isActive ?? false) _dragDebounce!.cancel();
                  _dragDebounce = Timer(const Duration(milliseconds: 800), () {
                    if (pos.center != null) {
                      setState(() {
                        selectedLocation = pos.center!;
                      });
                      _getAddressFromLatLng(pos.center!);
                    }
                  });
                }
              },
              onTap: (tapPosition, point) {
                setState(() {
                  selectedLocation = point;
                });
                _getAddressFromLatLng(point);
              },
            ),
            children: [
              TileLayer(
                urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
                userAgentPackageName: 'com.example.pec_night_canteen',
              ),
            ],
          ),
          // Center Pin (Fixed)
          const Center(
            child: Padding(
              padding: EdgeInsets.only(bottom: 40),
              child: Icon(Icons.location_on, color: Colors.red, size: 50),
            ),
          ),
          Positioned(
            bottom: 20, left: 20, right: 20,
            child: Card(
              elevation: 6,
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              child: Padding(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Text(
                      "Location",
                      style: TextStyle(fontSize: 12, color: Colors.grey, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 8),
                    isLoading
                        ? const LinearProgressIndicator()
                        : Text(address, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 8),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange, foregroundColor: Colors.white),
                        onPressed: () => Navigator.pop(context, address),
                        child: const Text("Confirm Location"),
                      ),
                    )
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// ================= ADDRESS SELECTION SCREEN =================
class AddressSelectionScreen extends StatefulWidget {
  final bool isEditing;
  const AddressSelectionScreen({super.key, this.isEditing = false});

  @override
  State<AddressSelectionScreen> createState() => _AddressSelectionScreenState();
}

class _AddressSelectionScreenState extends State<AddressSelectionScreen> {
  final TextEditingController _manualController = TextEditingController();

  List<String> _suggestions = [];
  Timer? _debounce;
  bool isLoadingSuggestions = false;

  void _completeSelection(String address) async {
    if (address.isEmpty || address.contains("Error")) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text("Invalid Address")));
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('savedAddress', address);

    if (!mounted) return;

    if (widget.isEditing) {
      Navigator.pop(context, address);
    } else {
      final name = prefs.getString('studentName') ?? "Student";
      final email = prefs.getString('studentEmail') ?? "email@example.com";
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => HomeScreen(studentName: name, studentEmail: email)),
      );
    }
  }

  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();
    if (query.length < 3) {
      setState(() => _suggestions = []);
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 500), () async {
      setState(() => isLoadingSuggestions = true);
      try {
        final url = Uri.parse('https://nominatim.openstreetmap.org/search?q=$query&format=json&addressdetails=1&limit=5&countrycodes=in');
        final response = await http.get(url, headers: {'User-Agent': 'com.example.pec_night_canteen'});
        if (response.statusCode == 200) {
          final List data = json.decode(response.body);
          setState(() {
            _suggestions = data.map<String>((e) => _parseOSMAddress(e)).toList();
            isLoadingSuggestions = false;
          });
        }
      } catch (e) {
        setState(() => isLoadingSuggestions = false);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.isEditing ? "Change Location" : "Select Location")),
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Where should we deliver?",
                style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 30),

              Card(
                child: ListTile(
                  leading: const Icon(Icons.my_location, color: Colors.blue),
                  title: const Text("Use Current Location"),
                  subtitle: const Text("Using GPS"),
                  onTap: () async {
                    final localCtx = context;
                    if (!mounted) return;
                    showDialog(context: localCtx, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));
                    String? addr = await determinePositionAndAddress();
                    if (!mounted) return;
                    // ignore: use_build_context_synchronously
                    Navigator.pop(localCtx);
                    if (addr != null) _completeSelection(addr);
                  },
                ),
              ),
              const SizedBox(height: 10),

              Card(
                child: ListTile(
                  leading: const Icon(Icons.map, color: Colors.orange),
                  title: const Text("Locate on Map"),
                  onTap: () async {
                    final result = await Navigator.push(
                        context, MaterialPageRoute(builder: (_) => const LocationPickerScreen()));
                    if (result != null) _completeSelection(result);
                  },
                ),
              ),
              const SizedBox(height: 10),

              Card(
                child: ExpansionTile(
                  leading: const Icon(Icons.keyboard, color: Colors.grey),
                  title: const Text("Enter Address Manually"),
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        children: [
                          TextField(
                            controller: _manualController,
                            decoration: const InputDecoration(
                              labelText: "Type Address (e.g. PEC Hostel...)",
                              border: OutlineInputBorder(),
                            ),
                            onChanged: _onSearchChanged,
                          ),
                          if (_suggestions.isNotEmpty || isLoadingSuggestions)
                            Container(
                              height: 150,
                              margin: const EdgeInsets.only(top: 8),
                              decoration: BoxDecoration(border: Border.all(color: Colors.grey[300]!)),
                              child: isLoadingSuggestions
                                  ? const Center(child: CircularProgressIndicator())
                                  : ListView.builder(
                                itemCount: _suggestions.length,
                                itemBuilder: (context, index) => ListTile(
                                  title: Text(_suggestions[index], maxLines: 1, overflow: TextOverflow.ellipsis),
                                  onTap: () => _completeSelection(_suggestions[index]),
                                ),
                              ),
                            ),
                          const SizedBox(height: 10),
                          ElevatedButton(
                            onPressed: () => _completeSelection(_manualController.text),
                            child: const Text("Confirm Address"),
                          ),
                        ],
                      ),
                    )
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

/// ================= DELIVERY MAP SCREEN (IN-APP NAVIGATION) =================
class DeliveryMapScreen extends StatefulWidget {
  final String targetAddress;
  const DeliveryMapScreen({super.key, required this.targetAddress});

  @override
  State<DeliveryMapScreen> createState() => _DeliveryMapScreenState();
}

class _DeliveryMapScreenState extends State<DeliveryMapScreen> {
  final MapController mapController = MapController();
  List<LatLng> routePoints = [];
  LatLng? myPos;
  LatLng? targetPos;
  bool isLoading = true;
  String statusMsg = "Locating...";

  @override
  void initState() {
    super.initState();
    _calculateRoute();
  }

  Future<void> _calculateRoute() async {
    try {
      Position position = await Geolocator.getCurrentPosition();
      myPos = LatLng(position.latitude, position.longitude);

      setState(() => statusMsg = "Finding destination...");

      final geoUrl = Uri.parse(
          'https://nominatim.openstreetmap.org/search?q=${Uri.encodeComponent(widget.targetAddress)}&format=json&limit=1');
      final geoRes = await http.get(geoUrl, headers: {'User-Agent': 'com.example.pec_night_canteen'});

      if (geoRes.statusCode != 200 || json.decode(geoRes.body).isEmpty) {
        setState(() { isLoading = false; statusMsg = "Address not found on map"; });
        return;
      }

      final geoData = json.decode(geoRes.body)[0];
      targetPos = LatLng(double.parse(geoData['lat']), double.parse(geoData['lon']));

      setState(() => statusMsg = "Calculating route...");

      final routeUrl = Uri.parse(
          'http://router.project-osrm.org/route/v1/driving/${myPos!.longitude},${myPos!.latitude};${targetPos!.longitude},${targetPos!.latitude}?geometries=geojson');

      final routeRes = await http.get(routeUrl);

      if (routeRes.statusCode == 200) {
        final routeData = json.decode(routeRes.body);
        final coordinates = routeData['routes'][0]['geometry']['coordinates'] as List;
        routePoints = coordinates.map((p) => LatLng(p[1].toDouble(), p[0].toDouble())).toList();
      }

      setState(() => isLoading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) mapController.move(myPos!, 15.0);
      });

    } catch (e) {
      setState(() { isLoading = false; statusMsg = "Error: $e"; });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text("Delivery Navigation")),
      body: isLoading
          ? Center(child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [const CircularProgressIndicator(), const SizedBox(height: 10), Text(statusMsg)],
      ))
          : targetPos == null
          ? Center(child: Text(statusMsg))
          : FlutterMap(
        mapController: mapController,
        options: MapOptions(
          initialCenter: myPos!,
          initialZoom: 15.0,
        ),
        children: [
          TileLayer(
            urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
            userAgentPackageName: 'com.example.pec_night_canteen',
          ),
          PolylineLayer(
            polylines: [
              Polyline(points: routePoints, strokeWidth: 4.0, color: Colors.blue),
            ],
          ),
          MarkerLayer(
            markers: [
              Marker(
                point: myPos!,
                width: 60, height: 60,
                child: const Icon(Icons.navigation, color: Colors.blue, size: 40),
              ),
              Marker(
                point: targetPos!,
                width: 60, height: 60,
                child: const Icon(Icons.location_on, color: Colors.red, size: 40),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// ================= ROLE SELECTION =================
class RoleSelectionScreen extends StatelessWidget {
  const RoleSelectionScreen({super.key});

  Widget role(String title, IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      child: Container(
        width: 240,
        padding: const EdgeInsets.all(18),
        decoration: BoxDecoration(
          color: Colors.deepOrange.withValues(alpha: .15),
          borderRadius: BorderRadius.circular(20),
        ),
        child: Column(
          children: [
            Icon(icon, size: 36, color: Colors.deepOrange),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Hostel Night Canteen')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            role('Student', Icons.school, () {
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const StudentLoginScreen()));
            }),
            const SizedBox(height: 20),
            role('Admin', Icons.admin_panel_settings, () {
              Navigator.push(context,
                  MaterialPageRoute(builder: (_) => const AdminLoginScreen()));
            }),
            const SizedBox(height: 20),
            role('Delivery', Icons.delivery_dining, () {
              Navigator.push(
                context,
                MaterialPageRoute(builder: (_) => const DeliveryLoginScreen()),
              );
            }),
          ],
        ),
      ),
    );
  }
}

/// ================= STUDENT LOGIN =================
class StudentLoginScreen extends StatefulWidget {
  const StudentLoginScreen({super.key});

  @override
  State<StudentLoginScreen> createState() => _StudentLoginScreenState();
}

class _StudentLoginScreenState extends State<StudentLoginScreen> {
  final nameCtrl = TextEditingController();
  final emailCtrl = TextEditingController();

  void login() async {
    final name = nameCtrl.text.trim();
    final email = emailCtrl.text.trim();

    if (name.isEmpty || email.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please fill in all fields')),
      );
      return;
    }

    final emailRegex = RegExp(r'^[\w-\.]+@([\w-]+\.)+[\w-]{2,4}$');
    if (!emailRegex.hasMatch(email)) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a valid email address')),
      );
      return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('studentName', name);
    await prefs.setString('studentEmail', email);

    if (!mounted) return;

    // NAVIGATE TO ADDRESS SELECTION, NOT HOME
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(builder: (_) => const AddressSelectionScreen(isEditing: false)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Student Login')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            TextField(
              controller: nameCtrl,
              decoration: const InputDecoration(
                labelText: 'Name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.person),
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: emailCtrl,
              decoration: const InputDecoration(
                labelText: 'Email',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.email),
              ),
              keyboardType: TextInputType.emailAddress,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              height: 50,
              child: ElevatedButton(
                onPressed: login,
                child: const Text('Login'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// ================= HOME =================
class HomeScreen extends StatefulWidget {
  final String studentName;
  final String studentEmail;

  const HomeScreen({
    super.key,
    required this.studentName,
    required this.studentEmail,
  });

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  String currentAddress = "Loading address...";

  @override
  void initState() {
    super.initState();
    _loadAddress();
  }

  Future<void> _loadAddress() async {
    final prefs = await SharedPreferences.getInstance();
    final addr = prefs.getString('savedAddress') ?? "Select Location";
    setState(() {
      currentAddress = addr;
    });
  }

  Future<void> _changeAddress() async {
    final newAddress = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const AddressSelectionScreen(isEditing: true)),
    );

    if (newAddress != null) {
      setState(() {
        currentAddress = newAddress;
      });
    }
  }

  bool isOpen() {
    if (isTestMode) return true;
    final h = DateTime.now().hour;
    return h >= 21 || h < 3;
  }

  Future<void> cancelOrder(BuildContext context, String orderId) async {
    await FirebaseFirestore.instance.collection('orders').doc(orderId).delete();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Order cancelled')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final open = isOpen();

    return Scaffold(
      appBar: AppBar(
        // SWIGGY-STYLE ADDRESS HEADER
        titleSpacing: 0,
        title: Padding(
          padding: const EdgeInsets.only(left: 16.0),
          child: InkWell(
            onTap: _changeAddress,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.location_on, color: Colors.deepOrange, size: 18),
                    SizedBox(width: 4),
                    Text("DELIVERY TO", style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: Colors.grey)),
                    Icon(Icons.arrow_drop_down, color: Colors.grey),
                  ],
                ),
                Text(
                  currentAddress,
                  style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ),
        actions: [
          IconButton(
            icon: Icon(themeNotifier.value == ThemeMode.light
                ? Icons.dark_mode
                : Icons.light_mode),
            tooltip: 'Toggle Theme',
            onPressed: () {
              themeNotifier.value = themeNotifier.value == ThemeMode.light
                  ? ThemeMode.dark
                  : ThemeMode.light;
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () async {
              final prefs = await SharedPreferences.getInstance();
              await prefs.clear();
              globalCart.clear();

              if (!context.mounted) return;

              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const RoleSelectionScreen()),
                    (route) => false,
              );
            },
          ),
        ],
      ),
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Card(
                elevation: 4,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                      vertical: 30, horizontal: 20),
                  child: Column(
                    children: [
                      const CircleAvatar(
                        radius: 30,
                        backgroundColor: Colors.deepOrange,
                        child:
                        Icon(Icons.person, size: 35, color: Colors.white),
                      ),
                      const SizedBox(height: 16),
                      Text(
                        'Welcome, ${widget.studentName}!',
                        textAlign: TextAlign.center,
                        style: const TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: open
                              ? Colors.green.withValues(alpha: 0.1)
                              : Colors.red.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: open ? Colors.green : Colors.red,
                          ),
                        ),
                        child: Text(
                          open ? 'CANTEEN IS OPEN' : 'CANTEEN CLOSED',
                          style: TextStyle(
                            color: open ? Colors.green : Colors.red,
                            fontWeight: FontWeight.bold,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(height: 30),
              SizedBox(
                width: double.infinity,
                height: 55,
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.restaurant_menu),
                  onPressed: open
                      ? () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MenuScreen(
                        name: widget.studentName,
                        email: widget.studentEmail,
                      ),
                    ),
                  )
                      : null,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.deepOrange,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  label: const Text(
                    'View Menu',
                    style: TextStyle(fontSize: 18),
                  ),
                ),
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: double.infinity,
                height: 55,
                child: OutlinedButton.icon(
                  icon: const Icon(Icons.history),
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => MyOrdersScreen(email: widget.studentEmail, name: widget.studentName),
                    ),
                  ),
                  style: OutlinedButton.styleFrom(
                    side: const BorderSide(color: Colors.deepOrange),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                  ),
                  label: const Text(
                    'My Orders',
                    style: TextStyle(fontSize: 18, color: Colors.deepOrange),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      // --- LIVE ORDER TRACKER ---
      bottomNavigationBar: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where('studentEmail', isEqualTo: widget.studentEmail)
            .orderBy('orderedAt', descending: true)
            .limit(1)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData || snapshot.data!.docs.isEmpty) {
            return const SizedBox.shrink();
          }

          final doc = snapshot.data!.docs.first;
          final data = doc.data() as Map<String, dynamic>;
          final status = data['status'] ?? 'Unknown';
          final pin = data['pin'];

          final items = List<Map<String, dynamic>>.from(data['items'] ?? []);
          final itemText =
          items.map((i) => "${i['itemName']} ×${i['qty']}").join(', ');

          if (status == 'Delivered') {
            return const SizedBox.shrink();
          }

          final canCancel = status != 'Out for Delivery';

          return Container(
            color: Theme.of(context).cardColor,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                child: Row(
                  children: [
                    const Icon(Icons.delivery_dining, color: Colors.deepOrange, size: 30),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Status: ',
                                style: TextStyle(fontSize: 12),
                              ),
                              Text(
                                status,
                                style: const TextStyle(
                                  color: Colors.green,
                                  fontWeight: FontWeight.bold,
                                  fontSize: 14,
                                ),
                              ),
                            ],
                          ),
                          if (status == 'Out for Delivery' && pin != null)
                            Text(
                              'PIN: $pin',
                              style: const TextStyle(
                                color: Colors.deepOrange,
                                fontWeight: FontWeight.bold,
                                fontSize: 14,
                              ),
                            ),
                          const SizedBox(height: 2),
                          Text(
                            itemText,
                            style: const TextStyle(fontSize: 12),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                      ),
                    ),
                    if (canCancel)
                      TextButton(
                        onPressed: () => cancelOrder(context, doc.id),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.redAccent,
                        ),
                        child: const Text('Cancel'),
                      ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// ================= MENU =================
class MenuScreen extends StatefulWidget {
  final String name;
  final String email;

  const MenuScreen({super.key, required this.name, required this.email});

  @override
  State<MenuScreen> createState() => _MenuScreenState();
}

class _MenuScreenState extends State<MenuScreen> {
  // Using globalCart instead of local list
  bool isVegMode = true;
  String searchQuery = "";
  String selectedCategory = "All"; // Chip Selection

  static const String typeVeg = 'veg';
  static const String typeNonVeg = 'nonveg';
  static const String typeCommon = 'common';

  // MENU DATA
  final List<Map<String, dynamic>> menuData = [
    {
      'category': 'STARTERS',
      'items': [
        {'name': 'Paneer Tikka', 'price': 150, 'type': typeVeg},
        {'name': 'Paneer Pakora', 'price': 130, 'type': typeVeg},
        {'name': 'Veg Manchurian (Dry)', 'price': 110, 'type': typeVeg},
        {'name': 'Chilli Paneer', 'price': 140, 'type': typeVeg},
        {'name': 'Honey Chilli Potato', 'price': 110, 'type': typeVeg},
        {'name': 'Crispy Corn', 'price': 100, 'type': typeVeg},
        {'name': 'French Fries', 'price': 80, 'type': typeVeg},
        {'name': 'Chicken Tikka', 'price': 180, 'type': typeNonVeg},
        {'name': 'Chicken Pakora', 'price': 160, 'type': typeNonVeg},
        {'name': 'Chicken Manchurian (Dry)', 'price': 150, 'type': typeNonVeg},
        {'name': 'Chilli Chicken', 'price': 170, 'type': typeNonVeg},
        {'name': 'Chicken 65', 'price': 180, 'type': typeNonVeg},
        {'name': 'Chicken Lollipop', 'price': 190, 'type': typeNonVeg},
      ]
    },
    {
      'category': 'FAST FOOD & SNACKS',
      'items': [
        {'name': 'Veg Burger', 'price': 60, 'type': typeVeg},
        {'name': 'Paneer Burger', 'price': 80, 'type': typeVeg},
        {'name': 'Veg Grilled Sandwich', 'price': 70, 'type': typeVeg},
        {'name': 'Cheese Sandwich', 'price': 80, 'type': typeVeg},
        {'name': 'Veg Momos', 'price': 60, 'type': typeVeg},
        {'name': 'Chicken Burger', 'price': 90, 'type': typeNonVeg},
        {'name': 'Chicken Grilled Sandwich', 'price': 100, 'type': typeNonVeg},
        {'name': 'Chicken Momos', 'price': 80, 'type': typeNonVeg},
        {'name': 'Chicken Shawarma Roll', 'price': 110, 'type': typeNonVeg},
      ]
    },
    {
      'category': 'INDO-CHINESE',
      'items': [
        {'name': 'Veg Fried Rice', 'price': 90, 'type': typeVeg},
        {'name': 'Paneer Fried Rice', 'price': 110, 'type': typeVeg},
        {'name': 'Veg Hakka Noodles', 'price': 90, 'type': typeVeg},
        {'name': 'Veg Manchurian (Gravy)', 'price': 120, 'type': typeVeg},
        {'name': 'Chilli Paneer (Gravy)', 'price': 150, 'type': typeVeg},
        {'name': 'Egg Fried Rice', 'price': 100, 'type': typeNonVeg},
        {'name': 'Chicken Fried Rice', 'price': 130, 'type': typeNonVeg},
        {'name': 'Chicken Hakka Noodles', 'price': 130, 'type': typeNonVeg},
        {'name': 'Chicken Manchurian (Gravy)', 'price': 160, 'type': typeNonVeg},
        {'name': 'Chilli Chicken (Gravy)', 'price': 180, 'type': typeNonVeg},
      ]
    },
    {
      'category': 'INDIAN MAINS',
      'items': [
        {'name': 'Dal Tadka', 'price': 100, 'type': typeVeg},
        {'name': 'Shahi Paneer', 'price': 150, 'type': typeVeg},
        {'name': 'Kadhai Paneer', 'price': 150, 'type': typeVeg},
        {'name': 'Rajma', 'price': 90, 'type': typeVeg},
        {'name': 'Mix Veg', 'price': 110, 'type': typeVeg},
        {'name': 'Butter Chicken', 'price': 190, 'type': typeNonVeg},
        {'name': 'Chicken Curry', 'price': 180, 'type': typeNonVeg},
        {'name': 'Kadhai Chicken', 'price': 180, 'type': typeNonVeg},
        {'name': 'Egg Curry', 'price': 120, 'type': typeNonVeg},
      ]
    },
    {
      'category': 'BREADS',
      'items': [
        {'name': 'Tandoori Roti', 'price': 15, 'type': typeCommon},
        {'name': 'Butter Roti', 'price': 20, 'type': typeCommon},
        {'name': 'Plain Naan', 'price': 30, 'type': typeCommon},
        {'name': 'Butter Naan', 'price': 40, 'type': typeCommon},
      ]
    },
    {
      'category': 'EGG CORNER',
      'items': [
        {'name': 'Boiled Eggs (2)', 'price': 30, 'type': typeNonVeg},
        {'name': 'Plain Omelette', 'price': 50, 'type': typeNonVeg},
        {'name': 'Masala Omelette', 'price': 60, 'type': typeNonVeg},
        {'name': 'Egg Bhurji', 'price': 70, 'type': typeNonVeg},
        {'name': 'Anda Bread', 'price': 60, 'type': typeNonVeg},
      ]
    },
    {
      'category': 'ROLLS & WRAPS',
      'items': [
        {'name': 'Paneer Roll', 'price': 80, 'type': typeVeg},
        {'name': 'Veg Frankie', 'price': 60, 'type': typeVeg},
        {'name': 'Egg Roll', 'price': 70, 'type': typeNonVeg},
        {'name': 'Chicken Roll', 'price': 100, 'type': typeNonVeg},
        {'name': 'Chicken Frankie', 'price': 90, 'type': typeNonVeg},
      ]
    },
    {
      'category': 'RICE',
      'items': [
        {'name': 'Plain Rice', 'price': 60, 'type': typeVeg},
        {'name': 'Jeera Rice', 'price': 80, 'type': typeVeg},
        {'name': 'Veg Pulao', 'price': 100, 'type': typeVeg},
        {'name': 'Egg Pulao', 'price': 120, 'type': typeNonVeg},
        {'name': 'Chicken Pulao', 'price': 150, 'type': typeNonVeg},
      ]
    },
    {
      'category': 'QUICK BITES',
      'items': [
        {'name': 'Aloo Tikki', 'price': 50, 'type': typeVeg},
        {'name': 'Cheese Balls', 'price': 80, 'type': typeVeg},
        {'name': 'Onion Rings', 'price': 70, 'type': typeVeg},
        {'name': 'Veg Cutlet', 'price': 60, 'type': typeVeg},
        {'name': 'Chicken Nuggets', 'price': 100, 'type': typeNonVeg},
        {'name': 'Chicken Fingers', 'price': 110, 'type': typeNonVeg},
      ]
    },
    {
      'category': 'BEVERAGES',
      'items': [
        {'name': 'Tea', 'price': 20, 'type': typeCommon},
        {'name': 'Coffee', 'price': 30, 'type': typeCommon},
        {'name': 'Cold Coffee', 'price': 60, 'type': typeCommon},
        {'name': 'Lemon Soda', 'price': 40, 'type': typeCommon},
        {'name': 'Soft Drinks', 'price': 40, 'type': typeCommon},
        {'name': 'Packaged Water', 'price': 20, 'type': typeCommon},
      ]
    },
    {
      'category': 'DESSERTS',
      'items': [
        {'name': 'Ice Cream', 'price': 40, 'type': typeCommon},
        {'name': 'Gulab Jamun', 'price': 40, 'type': typeCommon},
      ]
    },
  ];

  void updateQty(String name, int price, int change) {
    final index = globalCart.indexWhere((e) => e.name == name);

    if (index != -1) {
      if (globalCart[index].qty == 1 && change == -1) {
        globalCart.removeAt(index);
      } else {
        globalCart[index].qty += change;
      }
    } else {
      if (change == 1) {
        globalCart.add(CartItem(name, price, 1));
      }
    }
    setState(() {});

    int total = globalCart.fold(0, (acc, item) => acc + (item.price * item.qty));

    ScaffoldMessenger.of(context).hideCurrentSnackBar();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('Cart updated | Total: ₹$total'),
        duration: const Duration(seconds: 1),
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.black87,
      ),
    );
  }

  int getQty(String name) {
    final index = globalCart.indexWhere((e) => e.name == name);
    return index != -1 ? globalCart[index].qty : 0;
  }

  @override
  Widget build(BuildContext context) {
    // CATEGORY LIST FOR CHIPS
    final categories = ['All', ...menuData.map((e) => e['category'] as String)];

    return Scaffold(
      appBar: AppBar(
        title: const Text('Menu'),
        actions: [
          IconButton(
            icon: const Icon(Icons.shopping_cart),
            onPressed: () {
              if (globalCart.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Your Cart is empty'),
                    duration: Duration(seconds: 1),
                  ),
                );
              } else {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (_) => CartScreen(
                      name: widget.name,
                      email: widget.email,
                    ),
                  ),
                ).then((_) {
                  setState(() {});
                });
              }
            },
          ),
        ],
      ),
      body: Column(
        children: [
          // 1. SEARCH BAR
          Padding(
            padding: const EdgeInsets.all(12),
            child: TextField(
              decoration: InputDecoration(
                hintText: 'Search for "Butter Naan"...',
                prefixIcon: const Icon(Icons.search),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                ),
                contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              ),
              onChanged: (value) {
                setState(() {
                  searchQuery = value.toLowerCase();
                });
              },
            ),
          ),

          // 2. CATEGORY CHIPS (Horizontal Scroll)
          SizedBox(
            height: 50,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              itemCount: categories.length,
              itemBuilder: (context, index) {
                final cat = categories[index];
                final isSelected = selectedCategory == cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(cat),
                    selected: isSelected,
                    selectedColor: Colors.deepOrange.withValues(alpha: 0.2),
                    labelStyle: TextStyle(
                      color: isSelected ? Colors.deepOrange : null,
                      fontWeight: isSelected ? FontWeight.bold : null,
                    ),
                    onSelected: (bool selected) {
                      setState(() {
                        selectedCategory = selected ? cat : 'All';
                      });
                    },
                  ),
                );
              },
            ),
          ),

          // 3. VEG/NON-VEG TOGGLE
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const Text('Veg Only', style: TextStyle(fontWeight: FontWeight.bold)),
                Switch(
                  value: isVegMode,
                  activeThumbColor: Colors.green,
                  onChanged: (val) {
                    setState(() {
                      isVegMode = val;
                    });
                  },
                ),
              ],
            ),
          ),

          // 4. MENU LIST
          Expanded(
            child: ListView.builder(
              itemCount: menuData.length,
              padding: const EdgeInsets.only(bottom: 80), // Space for fab/snackbar
              itemBuilder: (context, index) {
                final category = menuData[index];
                final catName = category['category'];

                // Filter by Category Chip
                if (selectedCategory != 'All' && selectedCategory != catName) {
                  return const SizedBox.shrink();
                }

                final List items = category['items'];

                // Filter by Search & Veg/NonVeg
                final filteredItems = items.where((item) {
                  final type = item['type'];
                  final name = (item['name'] as String).toLowerCase();

                  // Search Filter
                  if (searchQuery.isNotEmpty && !name.contains(searchQuery)) {
                    return false;
                  }

                  // Type Filter
                  if (type == typeCommon) return true;
                  return isVegMode ? (type == typeVeg) : true;
                }).toList();

                if (filteredItems.isEmpty) return const SizedBox.shrink();

                return ExpansionTile(
                  initiallyExpanded: true, // Always expanded for better scrolling UX with search
                  title: Text(
                    catName,
                    style: const TextStyle(
                        fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  children: filteredItems.map<Widget>((item) {
                    final itemName = item['name'];
                    final price = item['price'];
                    final type = item['type'];
                    final qty = getQty(itemName);
                    final imageUrl =
                        'https://tse2.mm.bing.net/th?q=${Uri.encodeComponent(itemName + " food dish")}&w=120&h=120&c=7&rs=1&p=0';

                    return Card(
                      margin: const EdgeInsets.symmetric(
                          horizontal: 16, vertical: 6),
                      child: ListTile(
                        contentPadding: const EdgeInsets.all(8),
                        leading: Stack(
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.network(
                                imageUrl,
                                width: 60,
                                height: 60,
                                fit: BoxFit.cover,
                                errorBuilder: (context, error, stackTrace) =>
                                    Container(
                                      width: 60,
                                      height: 60,
                                      color: Colors.grey[300],
                                      child: const Icon(Icons.fastfood,
                                          color: Colors.grey),
                                    ),
                              ),
                            ),
                            // Food Type Icon Overlay
                            Positioned(
                              top: 2,
                              right: 2,
                              child: Container(
                                padding: const EdgeInsets.all(2),
                                decoration: BoxDecoration(
                                    color: Colors.white,
                                    borderRadius: BorderRadius.circular(4)
                                ),
                                child: FoodTypeIcon(type: type),
                              ),
                            ),
                          ],
                        ),
                        title: Text(
                          itemName,
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        subtitle: Row(
                          children: [
                            Text(
                              '₹$price',
                              style: const TextStyle(
                                color: Colors.deepOrange,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                        trailing: qty == 0
                            ? ElevatedButton(
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12),
                            minimumSize: const Size(60, 36),
                            backgroundColor: Theme.of(context).cardColor,
                            foregroundColor: Colors.green,
                            side: const BorderSide(color: Colors.green),
                          ),
                          onPressed: () => updateQty(itemName, price, 1),
                          child: const Text('Add'),
                        )
                            : Container(
                          height: 36,
                          decoration: BoxDecoration(
                            color: Theme.of(context).cardColor,
                            border: Border.all(color: Colors.green),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              InkWell(
                                onTap: () =>
                                    updateQty(itemName, price, -1),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 8),
                                  child: Icon(Icons.remove,
                                      size: 16, color: Colors.green),
                                ),
                              ),
                              Text(
                                '$qty',
                                style: const TextStyle(
                                    color: Colors.green,
                                    fontWeight: FontWeight.bold),
                              ),
                              InkWell(
                                onTap: () =>
                                    updateQty(itemName, price, 1),
                                child: const Padding(
                                  padding: EdgeInsets.symmetric(
                                      horizontal: 8),
                                  child: Icon(Icons.add,
                                      size: 16, color: Colors.green),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }).toList(),
                );
              },
            ),
          ),
        ],
      ),
    );
  }
}

/// ================= CART SCREEN =================
class CartScreen extends StatefulWidget {
  final String name;
  final String email;

  const CartScreen({
    super.key,
    required this.name,
    required this.email,
  });

  @override
  State<CartScreen> createState() => _CartScreenState();
}

class _CartScreenState extends State<CartScreen> {
  final addressCtrl = TextEditingController();
  final FocusNode addressFocusNode = FocusNode();

  String? mapAddress;
  bool isManualEntry = false;

  // SUGGESTIONS STATE
  List<String> _suggestions = [];
  Timer? _debounce;
  bool isLoadingSuggestions = false;

  @override
  void initState() {
    super.initState();
    // Load default address
    _loadDefaultAddress();
  }

  void _loadDefaultAddress() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getString('savedAddress');
    if (saved != null) {
      setState(() {
        addressCtrl.text = saved;
        mapAddress = saved; // Treat saved address as a "validated" map address
      });
    }
  }

  @override
  void dispose() {
    addressCtrl.dispose();
    addressFocusNode.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  int getItemTotal() {
    return globalCart.fold(0, (acc, item) => acc + (item.price * item.qty));
  }

  void updateQty(CartItem item, int change) {
    if (item.qty == 1 && change == -1) {
      globalCart.remove(item);
    } else {
      item.qty += change;
    }
    setState(() {});
  }

  // --- ADDRESS AUTOCOMPLETE LOGIC ---
  void _onSearchChanged(String query) {
    if (_debounce?.isActive ?? false) _debounce!.cancel();

    // IMPORTANT: Wait for at least 3 chars to avoid broad searches
    if (query.length < 3) {
      setState(() => _suggestions = []);
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 500), () async {
      setState(() => isLoadingSuggestions = true);

      try {
        final url = Uri.parse('https://nominatim.openstreetmap.org/search?q=$query&format=json&addressdetails=1&limit=5&countrycodes=in');
        final response = await http.get(url, headers: {'User-Agent': 'com.example.pec_night_canteen'});

        if (response.statusCode == 200) {
          final List data = json.decode(response.body);
          setState(() {
            _suggestions = data.map<String>((e) => _parseOSMAddress(e)).toList();
            isLoadingSuggestions = false;
          });
        }
      } catch (e) {
        setState(() => isLoadingSuggestions = false);
      }
    });
  }

  // --- POPUP LOGIC FOR ADDRESS ---
  void _showLocationOptions() {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                "Select Address Mode",
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 20),
              ListTile(
                leading: const Icon(Icons.my_location, color: Colors.blue),
                title: const Text("Use Current Location"),
                subtitle: const Text("Auto-detect using GPS"),
                onTap: () async {
                  final localCtx = context;
                  Navigator.pop(ctx);
                  setState(() {
                    isManualEntry = false;
                    _suggestions = [];
                  });

                  if (!mounted) return;
                  showDialog(context: localCtx, barrierDismissible: false, builder: (_) => const Center(child: CircularProgressIndicator()));

                  String? addr = await determinePositionAndAddress();

                  if (!mounted) return;
// ignore: use_build_context_synchronously
                      Navigator.pop(localCtx);

                  if (addr != null) {
                    if (!mounted) return;
                    setState(() {
                      addressCtrl.text = addr;
                      mapAddress = addr;
                    });
                  } else {
                    if (!mounted) return;
                    // ignore: use_build_context_synchronously
                      // ignore: use_build_context_synchronously
                      ScaffoldMessenger.of(localCtx).showSnackBar(const SnackBar(content: Text("Failed to detect location.")));
                  }
                },

              ),
              ListTile(
                leading: const Icon(Icons.map, color: Colors.orange),
                title: const Text("Pick on Map"),
                subtitle: const Text("Select precise location"),
                onTap: () async {
                  Navigator.pop(ctx);
                  setState(() {
                    isManualEntry = false;
                    _suggestions = [];
                  });

                  final result = await Navigator.push(
                      context,
                      MaterialPageRoute(builder: (_) => const LocationPickerScreen())
                  );
                  if (result != null) {
                    setState(() {
                      mapAddress = result;
                      addressCtrl.text = result;
                    });
                  }
                },
              ),
              ListTile(
                leading: const Icon(Icons.keyboard, color: Colors.grey),
                title: const Text("Enter Manually"),
                subtitle: const Text("Type address yourself"),
                onTap: () {
                  Navigator.pop(ctx);
                  setState(() {
                    isManualEntry = true;
                    mapAddress = null;
                    addressCtrl.clear();
                    _suggestions = [];
                  });
                  Future.delayed(const Duration(milliseconds: 100), () {
                    // ignore: use_build_context_synchronously
                      // ignore: use_build_context_synchronously
                      FocusScope.of(context).requestFocus(addressFocusNode);
                  });
                },
              ),
            ],
          ),
        );
      },
    );
  }

  Future<void> placeOrder() async {
    String finalAddress = addressCtrl.text;

    if (!isManualEntry && mapAddress != null) {
      finalAddress = mapAddress!;
    }

    if (finalAddress.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Please enter or select a delivery address'))
      );
      return;
    }

    final items = globalCart.map((item) => {
      'itemName': item.name,
      'price': item.price,
      'qty': item.qty,
    }).toList();

    int itemTotal = getItemTotal();
    double taxes = itemTotal * 0.05;
    int grandTotal = itemTotal + taxes.ceil() + 5;

    await FirebaseFirestore.instance.collection('orders').add({
      'items': items,
      'totalPrice': grandTotal,
      'studentName': widget.name,
      'studentEmail': widget.email,
      'address': finalAddress,
      'status': 'Pending',
      'orderedAt': FieldValue.serverTimestamp(),
      'pin': null,
    });

    globalCart.clear();

    if (!mounted) return;

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text('Order placed successfully'),
        duration: Duration(seconds: 2),
      ),
    );

    Navigator.of(context).pop();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final itemTotal = getItemTotal();
    final taxes = (itemTotal * 0.05).ceil();
    final platformFee = 5;
    final grandTotal = itemTotal + taxes + platformFee;

    return Scaffold(
      appBar: AppBar(title: const Text('Your Cart')),
      // SCROLLABLE BODY TO PREVENT OVERFLOW
      body: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            children: [
              // CART ITEMS LIST (Limited Height to fit scrollview)
              SizedBox(
                height: 250,
                child: globalCart.isEmpty
                    ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.remove_shopping_cart, size: 80, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      const Text("Hungry? Your cart is empty!", style: TextStyle(fontSize: 18, color: Colors.grey)),
                    ],
                  ),
                )
                    : ListView(
                  children: globalCart.map((e) {
                    return ListTile(
                      title: Text(e.name),
                      subtitle: Text('₹${e.price * e.qty}'),
                      trailing: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          IconButton(
                            icon: const Icon(Icons.remove_circle_outline),
                            color: Colors.deepOrange,
                            onPressed: () => updateQty(e, -1),
                          ),
                          Text(
                            '${e.qty}',
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          IconButton(
                            icon: const Icon(Icons.add_circle_outline),
                            color: Colors.green,
                            onPressed: () => updateQty(e, 1),
                          ),
                        ],
                      ),
                    );
                  }).toList(),
                ),
              ),

              if (globalCart.isNotEmpty) ...[
                const Divider(thickness: 2),

                // BILL DETAILS
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                      color: Theme.of(context).cardColor,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.withValues(alpha: 0.2))
                  ),
                  child: Column(
                    children: [
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text("Item Total"),
                        Text("₹$itemTotal"),
                      ]),
                      const SizedBox(height: 4),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text("Taxes (5%)"),
                        Text("₹$taxes"),
                      ]),
                      const SizedBox(height: 4),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text("Platform Fee"),
                        Text("₹$platformFee"),
                      ]),
                      const Divider(),
                      Row(mainAxisAlignment: MainAxisAlignment.spaceBetween, children: [
                        const Text("Grand Total", style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
                        Text("₹$grandTotal", style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 18, color: Colors.deepOrange)),
                      ]),
                    ],
                  ),
                ),

                const SizedBox(height: 12),

                // === ADDRESS INPUT WITH SUGGESTIONS ===
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    TextField(
                      controller: addressCtrl,
                      focusNode: addressFocusNode,
                      readOnly: !isManualEntry,
                      onTap: isManualEntry ? null : _showLocationOptions,
                      onChanged: isManualEntry ? _onSearchChanged : null,
                      decoration: InputDecoration(
                          labelText: 'Delivery Address',
                          border: const OutlineInputBorder(),
                          suffixIcon: isManualEntry
                              ? IconButton(
                              icon: const Icon(Icons.close),
                              onPressed: () {
                                setState(() {
                                  isManualEntry = false;
                                  addressCtrl.clear();
                                  _suggestions = [];
                                  FocusScope.of(context).unfocus();
                                });
                              }
                          )
                              : const Icon(Icons.arrow_drop_down),
                          hintText: "Tap to select address"
                      ),
                    ),
                    // SUGGESTIONS LIST (Conditional)
                    if (isManualEntry && (_suggestions.isNotEmpty || isLoadingSuggestions))
                      Container(
                        height: 150,
                        decoration: BoxDecoration(
                            border: Border.all(color: Colors.grey),
                            borderRadius: BorderRadius.circular(4)
                        ),
                        child: isLoadingSuggestions
                            ? const Center(child: CircularProgressIndicator())
                            : ListView.builder(
                          itemCount: _suggestions.length,
                          itemBuilder: (context, index) {
                            return ListTile(
                              title: Text(_suggestions[index], maxLines: 1, overflow: TextOverflow.ellipsis),
                              onTap: () {
                                setState(() {
                                  addressCtrl.text = _suggestions[index];
                                  _suggestions = [];
                                  FocusScope.of(context).unfocus();
                                });
                              },
                            );
                          },
                        ),
                      ),
                  ],
                ),

                const SizedBox(height: 12),

                // BUTTON WITH SAFE AREA
                SafeArea(
                  child: SizedBox(
                    width: double.infinity,
                    height: 50,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange, foregroundColor: Colors.white),
                      onPressed: placeOrder,
                      child: const Text('Place Order', style: TextStyle(fontSize: 18)),
                    ),
                  ),
                ),
                // Extra padding for scroll
                const SizedBox(height: 20),
              ]
            ],
          ),
        ),
      ),
    );
  }
}

/// ================= MY ORDERS =================
class MyOrdersScreen extends StatelessWidget {
  final String email;
  final String name; // Needed for reorder
  const MyOrdersScreen({super.key, required this.email, required this.name});

  Future<void> deleteOrder(BuildContext context, String orderId) async {
    await FirebaseFirestore.instance.collection('orders').doc(orderId).delete();
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('Order deleted')),
    );
  }

  void repeatOrder(BuildContext context, Map<String, dynamic> data) {
    globalCart.clear();
    final items = List<Map<String, dynamic>>.from(data['items'] ?? []);
    for (var i in items) {
      globalCart.add(CartItem(i['itemName'], i['price'], i['qty']));
    }
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => CartScreen(name: name, email: email)),
    );
  }

  String formatDate(Timestamp? timestamp) {
    if (timestamp == null) return 'Unknown Date';
    final date = timestamp.toDate();
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));
    final check = DateTime(date.year, date.month, date.day);

    if (check == today) return 'Today';
    if (check == yesterday) return 'Yesterday';
    return '${date.day}/${date.month}/${date.year}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('My Orders')),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where('studentEmail', isEqualTo: email)
            .orderBy('orderedAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.data!.docs.isEmpty) {
            return Center(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(Icons.history, size: 80, color: Colors.grey[400]),
                  const SizedBox(height: 16),
                  const Text("No past orders", style: TextStyle(fontSize: 18, color: Colors.grey)),
                ],
              ),
            );
          }

          final docs = snapshot.data!.docs;
          final Map<String, List<DocumentSnapshot>> grouped = {};

          for (var doc in docs) {
            final data = doc.data() as Map<String, dynamic>;
            final ts = data['orderedAt'] as Timestamp?;
            final dateKey = formatDate(ts);

            if (!grouped.containsKey(dateKey)) {
              grouped[dateKey] = [];
            }
            grouped[dateKey]!.add(doc);
          }

          final keys = grouped.keys.toList();

          return ListView.builder(
            padding: const EdgeInsets.all(16),
            itemCount: keys.length,
            itemBuilder: (context, index) {
              final dateKey = keys[index];
              final orders = grouped[dateKey]!;

              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding:
                    const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
                    child: Text(
                      dateKey,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                        color: Colors.grey,
                      ),
                    ),
                  ),
                  ...orders.map((doc) {
                    final d = doc.data() as Map<String, dynamic>;
                    final pin = d['pin'];
                    final status = d['status'];
                    final items = List<Map<String, dynamic>>.from(d['items']);
                    final address = d['address'];
                    final canCancel = status == 'Pending';
                    final isDelivered = status == 'Delivered';

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      child: Padding(
                        padding: const EdgeInsets.all(12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Text('Total: ₹${d['totalPrice']}',
                                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                                if (isDelivered)
                                  OutlinedButton.icon(
                                    icon: const Icon(Icons.refresh, size: 16),
                                    label: const Text("Repeat"),
                                    style: OutlinedButton.styleFrom(
                                        visualDensity: VisualDensity.compact),
                                    onPressed: () => repeatOrder(context, d),
                                  ),
                              ],
                            ),
                            const Divider(),
                            ...items.map((item) => Text(
                              '${item['itemName']} ×${item['qty']}',
                              style: const TextStyle(fontSize: 14),
                            )),
                            const SizedBox(height: 8),
                            Text(
                              'Address: $address',
                              style: const TextStyle(fontWeight: FontWeight.w500, color: Colors.blue),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Status: $status',
                              style: TextStyle(
                                color: isDelivered ? Colors.green : Colors.orange,
                                fontWeight: FontWeight.w500,
                              ),
                            ),
                            if (pin != null && !isDelivered)
                              Text('PIN: $pin',
                                  style: const TextStyle(
                                      fontWeight: FontWeight.bold,
                                      color: Colors.deepOrange,
                                      fontSize: 16)),

                            // ACTION BUTTONS
                            Row(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: [
                                if (canCancel)
                                  TextButton(
                                    onPressed: () => deleteOrder(context, doc.id),
                                    style: TextButton.styleFrom(foregroundColor: Colors.red),
                                    child: const Text('Cancel Order'),
                                  ),
                                if (isDelivered)
                                  IconButton(
                                    icon: const Icon(Icons.delete_outline, color: Colors.grey),
                                    onPressed: () => deleteOrder(context, doc.id),
                                    tooltip: 'Delete from history',
                                  ),
                              ],
                            )
                          ],
                        ),
                      ),
                    );
                  }),
                ],
              );
            },
          );
        },
      ),
    );
  }
}

/// ================= ADMIN LOGIN =================
class AdminLoginScreen extends StatefulWidget {
  const AdminLoginScreen({super.key});

  @override
  State<AdminLoginScreen> createState() => _AdminLoginScreenState();
}

class _AdminLoginScreenState extends State<AdminLoginScreen> {
  final ctrl = TextEditingController();

  Future<void> login() async {
    final doc = await FirebaseFirestore.instance
        .collection('settings')
        .doc('admin')
        .get();

    if (ctrl.text == doc['password']) {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const AdminPanel()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Admin Login')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            TextField(
              controller: ctrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Admin Password'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: login, child: const Text('Login')),
          ],
        ),
      ),
    );
  }
}

/// ================= ADMIN PANEL =================
class AdminPanel extends StatelessWidget {
  const AdminPanel({super.key});

  String generatePin() {
    final random = Random();
    return (1000 + random.nextInt(9000)).toString();
  }

  Future<void> update(String id, String status) async {
    final updateData = <String, dynamic>{'status': status};

    if (status == 'Out for Delivery') {
      updateData['pin'] = generatePin();
    }

    await FirebaseFirestore.instance
        .collection('orders')
        .doc(id)
        .update(updateData);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Admin Panel'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const RoleSelectionScreen()),
                    (route) => false,
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .orderBy('orderedAt', descending: true)
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.data!.docs.isEmpty) {
            return const Center(child: Text('No orders yet'));
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: snapshot.data!.docs.map((doc) {
              final d = doc.data() as Map<String, dynamic>;
              final status = d['status'];
              final items = List<Map<String, dynamic>>.from(d['items']);

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        d['studentName'],
                        style: const TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 4),
                      ...items.map((item) => Text(
                        '${item['itemName']} ×${item['qty']}',
                        style: const TextStyle(fontSize: 14),
                      )),
                      const SizedBox(height: 4),
                      Text(
                        'Total: ₹${d['totalPrice']}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text('Status: $status'),
                      const SizedBox(height: 10),
                      if (status == 'Pending')
                        ElevatedButton(
                          onPressed: () => update(doc.id, 'Preparing'),
                          child: const Text('Preparing'),
                        ),
                      if (status == 'Preparing')
                        ElevatedButton(
                          onPressed: () => update(doc.id, 'Ready'),
                          child: const Text('Ready'),
                        ),
                      if (status == 'Ready')
                        ElevatedButton(
                          onPressed: () => update(doc.id, 'Out for Delivery'),
                          child: const Text('Out for Delivery'),
                        ),
                    ],
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}

/// ================= DELIVERY LOGIN =================
class DeliveryLoginScreen extends StatefulWidget {
  const DeliveryLoginScreen({super.key});

  @override
  State<DeliveryLoginScreen> createState() => _DeliveryLoginScreenState();
}

class _DeliveryLoginScreenState extends State<DeliveryLoginScreen> {
  final ctrl = TextEditingController();

  Future<void> login() async {
    final doc = await FirebaseFirestore.instance
        .collection('settings')
        .doc('delivery')
        .get();

    if (ctrl.text == doc['password']) {
      if (!mounted) return;
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(builder: (_) => const DeliveryPanel()),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Delivery Login')),
      body: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          children: [
            TextField(
              controller: ctrl,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'Delivery Password'),
            ),
            const SizedBox(height: 16),
            ElevatedButton(onPressed: login, child: const Text('Login')),
          ],
        ),
      ),
    );
  }
}

/// ================= DELIVERY PANEL =================
class DeliveryPanel extends StatelessWidget {
  const DeliveryPanel({super.key});

  Future<void> delivered(BuildContext context, String id, String pin) async {
    final pinCtrl = TextEditingController();

    final result = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Verify PIN'),
        content: TextField(
          controller: pinCtrl,
          decoration: const InputDecoration(
            labelText: 'Enter PIN',
            hintText: '4-digit PIN',
          ),
          keyboardType: TextInputType.number,
          maxLength: 4,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              if (pinCtrl.text == pin) {
                Navigator.pop(context, true);
              } else {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Incorrect PIN'),
                    duration: Duration(seconds: 2),
                  ),
                );
              }
            },
            child: const Text('Verify'),
          ),
        ],
      ),
    );

    if (result == true) {
      await FirebaseFirestore.instance
          .collection('orders')
          .doc(id)
          .update({'status': 'Delivered'});

      if (!context.mounted) return;

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Order marked as delivered'),
          duration: Duration(seconds: 2),
        ),
      );
    }
  }

  

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Delivery Panel'),
        actions: [
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: () {
              Navigator.pushAndRemoveUntil(
                context,
                MaterialPageRoute(builder: (_) => const RoleSelectionScreen()),
                    (route) => false,
              );
            },
          ),
        ],
      ),
      body: StreamBuilder<QuerySnapshot>(
        stream: FirebaseFirestore.instance
            .collection('orders')
            .where('status', isEqualTo: 'Out for Delivery')
            .snapshots(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            return const Center(child: CircularProgressIndicator());
          }

          if (snapshot.data!.docs.isEmpty) {
            return const Center(child: Text('No deliveries'));
          }

          return ListView(
            padding: const EdgeInsets.all(16),
            children: snapshot.data!.docs.map((doc) {
              final d = doc.data() as Map<String, dynamic>;
              final pin = d['pin'];
              final address = d['address']; // Visible to delivery
              final items = List<Map<String, dynamic>>.from(d['items']);

              return Card(
                margin: const EdgeInsets.only(bottom: 12),
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Student: ${d['studentName']}',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          // NAVIGATION BUTTON (Internal Map Screen)
                          IconButton(
                            icon: const Icon(Icons.map, color: Colors.blue),
                            onPressed: () {
                              if (address != null) {
                                Navigator.push(
                                  context,
                                  MaterialPageRoute(
                                    builder: (_) => DeliveryMapScreen(targetAddress: address),
                                  ),
                                );
                              }
                            },
                            tooltip: "Navigate (In-App)",
                          )
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Items:',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
                      ...items.map((item) => Text(
                        '  • ${item['itemName']} ×${item['qty']}',
                        style: const TextStyle(fontSize: 14),
                      )),
                      const SizedBox(height: 8),
                      Text(
                        'Total: ₹${d['totalPrice']}',
                        style: const TextStyle(fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Address: $address',
                        style: const TextStyle(
                          fontWeight: FontWeight.w500,
                          color: Colors.blue,
                        ),
                      ),
                      const SizedBox(height: 4),
                      if (pin != null)
                        Text(
                          'PIN: $pin',
                          style: const TextStyle(
                            fontWeight: FontWeight.bold,
                            color: Colors.deepOrange,
                            fontSize: 16,
                          ),
                        ),
                      const SizedBox(height: 10),
                      ElevatedButton(
                        onPressed: () => delivered(context, doc.id, pin),
                        child: const Text('Mark as Delivered'),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          );
        },
      ),
    );
  }
}