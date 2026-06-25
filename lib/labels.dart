/// Labels Cloud Vision returns that make poor photo *categories* — facial
/// anatomy, plus generic/typographic/abstract noise it slaps on screenshots
/// and documents ("Font", "Number", "Rectangle"…). We drop these both when
/// annotating AND at display time, so existing libraries clean up without
/// re-calling Vision. Meaningful subjects (Food, Beach, Dog, Car, Screenshot,
/// Technology, Document…) are kept.
const Set<String> kJunkLabels = {
  // face / anatomy
  'face', 'forehead', 'cheek', 'chin', 'jaw', 'eyebrow', 'eyelash', 'eye',
  'iris', 'nose', 'lip', 'mouth', 'tooth', 'skin', 'beard', 'moustache',
  'facial hair', 'hair', 'hairstyle', 'head', 'neck', 'ear', 'wrinkle',
  'selfie', 'chest', 'shoulder', 'arm', 'hand', 'finger', 'nail', 'human',
  'person', 'smile', 'glasses', 'eyewear', 'temple', 'organ', 'tongue',
  'flesh', 'jheri curl',
  // generic photo terms
  'photograph', 'photography', 'snapshot', 'image', 'close-up', 'portrait',
  'photo caption', 'stock photography',
  // typographic / UI / screenshot noise
  'font', 'number', 'text', 'line', 'web page', 'website', 'document',
  'paper', 'paper product', 'handwriting', 'writing', 'paragraph',
  'screenshot software', 'web design', 'graphics', 'graphic design',
  'icon', 'symbol', 'sign', 'logo', 'brand', 'banner', 'menu', 'page',
  // abstract shapes / color / material
  'rectangle', 'square', 'circle', 'triangle', 'oval', 'pattern',
  'parallel', 'symmetry', 'colorfulness', 'material property', 'tints and shades',
  'azure', 'aqua', 'electric blue', 'magenta', 'white', 'black', 'grey', 'gray',
  'beige', 'amber', 'art', 'design', 'illustration', 'clip art', 'space',
};

/// Drops junk and de-duplicates while preserving order.
List<String> cleanLabels(Iterable<String> labels) {
  final seen = <String>{};
  final out = <String>[];
  for (final l in labels) {
    final key = l.toLowerCase().trim();
    if (key.isEmpty || kJunkLabels.contains(key)) continue;
    if (seen.add(key)) out.add(l);
  }
  return out;
}

/// Google-Photos-style curated taxonomy: many fine-grained Vision labels are
/// mapped into a small set of human-meaningful buckets ("Things"), instead of
/// surfacing every raw label as its own category. Each label maps to at most
/// one bucket; a photo is filed under its highest-confidence mappable label.
const Map<String, String> _categoryOf = {
  // Animals
  'animal': 'Animals', 'cat': 'Animals', 'dog': 'Animals', 'kitten': 'Animals',
  'puppy': 'Animals', 'pet': 'Animals', 'fur': 'Animals', 'whiskers': 'Animals',
  'felinae': 'Animals', 'snout': 'Animals', 'paw': 'Animals', 'tail': 'Animals',
  'bird': 'Animals', 'mammal': 'Animals', 'wildlife': 'Animals', 'fish': 'Animals',
  'horse': 'Animals', 'carnivore': 'Animals', 'terrestrial animal': 'Animals',
  'cat breed': 'Animals', 'dog breed': 'Animals', 'beak': 'Animals',
  'reptile': 'Animals', 'insect': 'Animals', 'butterfly': 'Animals', 'organism': 'Animals',
  // Nature
  'nature': 'Nature', 'landscape': 'Nature', 'natural landscape': 'Nature',
  'sky': 'Nature', 'cloud': 'Nature', 'mountain': 'Nature', 'tree': 'Nature',
  'plant': 'Nature', 'flower': 'Nature', 'flowering plant': 'Nature', 'sea': 'Nature',
  'ocean': 'Nature', 'beach': 'Nature', 'coast': 'Nature', 'water': 'Nature',
  'sunset': 'Nature', 'sunrise': 'Nature', 'horizon': 'Nature', 'forest': 'Nature',
  'grass': 'Nature', 'leaf': 'Nature', 'garden': 'Nature', 'lake': 'Nature',
  'river': 'Nature', 'snow': 'Nature', 'desert': 'Nature', 'hill': 'Nature',
  'wave': 'Nature', 'vegetation': 'Nature', 'sunlight': 'Nature', 'dusk': 'Nature',
  'mountainous landforms': 'Nature', 'wood': 'Nature',
  // Food
  'food': 'Food', 'dish': 'Food', 'cuisine': 'Food', 'meal': 'Food',
  'recipe': 'Food', 'ingredient': 'Food', 'dessert': 'Food', 'baked goods': 'Food',
  'drink': 'Food', 'beverage': 'Food', 'fruit': 'Food', 'vegetable': 'Food',
  'produce': 'Food', 'fast food': 'Food', 'junk food': 'Food', 'finger food': 'Food',
  'tableware': 'Food', 'coffee': 'Food', 'cake': 'Food', 'bread': 'Food',
  'pizza': 'Food', 'snack': 'Food', 'comfort food': 'Food', 'staple food': 'Food',
  // Vehicles
  'vehicle': 'Vehicles', 'car': 'Vehicles', 'motor vehicle': 'Vehicles',
  'automotive design': 'Vehicles', 'automotive exterior': 'Vehicles', 'van': 'Vehicles',
  'truck': 'Vehicles', 'motorcycle': 'Vehicles', 'bicycle': 'Vehicles', 'bus': 'Vehicles',
  'train': 'Vehicles', 'transport': 'Vehicles', 'wheel': 'Vehicles', 'tire': 'Vehicles',
  'automobile': 'Vehicles', 'traffic': 'Vehicles', 'mode of transport': 'Vehicles',
  'boat': 'Vehicles', 'watercraft': 'Vehicles', 'aircraft': 'Vehicles', 'airplane': 'Vehicles',
  // People
  'selfie': 'People', 'people': 'People', 'child': 'People', 'baby': 'People',
  'crowd': 'People', 'social group': 'People', 'friendship': 'People', 'fun': 'People',
  'family': 'People', 'toddler': 'People', 'man': 'People', 'woman': 'People',
  // Screenshots
  'screenshot': 'Screenshots',
  // Documents
  'document': 'Documents', 'receipt': 'Documents', 'invoice': 'Documents',
  'menu': 'Documents', 'book': 'Documents', 'magazine': 'Documents',
  'newspaper': 'Documents', 'letter': 'Documents', 'note': 'Documents',
  'ticket': 'Documents', 'paperwork': 'Documents', 'envelope': 'Documents',
  // Places
  'building': 'Places', 'architecture': 'Places', 'house': 'Places', 'home': 'Places',
  'city': 'Places', 'urban area': 'Places', 'skyscraper': 'Places', 'tower': 'Places',
  'monument': 'Places', 'landmark': 'Places', 'street': 'Places', 'road': 'Places',
  'facade': 'Places', 'real estate': 'Places', 'interior design': 'Places',
  'room': 'Places', 'church': 'Places', 'temple': 'Places', 'place of worship': 'Places',
  'neighbourhood': 'Places', 'metropolis': 'Places',
  // Events
  'birthday': 'Events', 'wedding': 'Events', 'party': 'Events', 'concert': 'Events',
  'graduation': 'Events', 'ceremony': 'Events', 'festival': 'Events',
  'celebration': 'Events', 'performance': 'Events', 'stage': 'Events', 'event': 'Events',
  // Tech
  'technology': 'Tech', 'electronics': 'Tech', 'gadget': 'Tech', 'mobile phone': 'Tech',
  'smartphone': 'Tech', 'computer': 'Tech', 'laptop': 'Tech', 'display device': 'Tech',
  'output device': 'Tech', 'communication device': 'Tech', 'electronic device': 'Tech',
  'computer hardware': 'Tech', 'gadgets': 'Tech', 'peripheral': 'Tech',
  // Fashion
  'clothing': 'Fashion', 'fashion': 'Fashion', 'dress': 'Fashion', 'outerwear': 'Fashion',
  'footwear': 'Fashion', 'shoe': 'Fashion', 'jewellery': 'Fashion', 'watch': 'Fashion',
  'sunglasses': 'Fashion', 'fashion accessory': 'Fashion', 'textile': 'Fashion',
  // Sports
  'sport': 'Sports', 'sports equipment': 'Sports', 'ball': 'Sports', 'football': 'Sports',
  'cricket': 'Sports', 'gym': 'Sports', 'fitness': 'Sports', 'exercise': 'Sports',
  'athlete': 'Sports', 'team sport': 'Sports', 'stadium': 'Sports',
  // Art
  'art': 'Art', 'painting': 'Art', 'drawing': 'Art', 'sculpture': 'Art',
  'mural': 'Art', 'street art': 'Art', 'visual arts': 'Art', 'illustration': 'Art',
};

/// The single best curated category for a photo, or null if none of its labels
/// map. Labels are confidence-ordered, so the first mappable one wins.
String? categoryFor(Iterable<String> labels) {
  for (final l in labels) {
    final c = _categoryOf[l.toLowerCase().trim()];
    if (c != null) return c;
  }
  return null;
}
