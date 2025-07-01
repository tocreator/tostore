import '../model/table_schema.dart';

/// A function that compares two keys.
typedef ComparatorFunction = int Function(dynamic a, dynamic b);

/// Utility class for comparing values of different types.
class ValueComparator {
  /// Compares two values of potentially different types.
  /// Returns:
  /// - Negative number if a < b
  /// - Zero if a == b
  /// - Positive number if a > b
  static int compare(dynamic a, dynamic b) {
    if (a == b) {
      return 0;
    }

    // 1. Handle null cases
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;

    // 2. Fast path for common identical types
    if (a.runtimeType == b.runtimeType) {
      if (a is String) return compareStrings(a, b);
      if (a is int) return compareInts(a, b);
      if (a is double) return compareDoubles(a, b);
      if (a is BigInt) return a.compareTo(b as BigInt);
      if (a is DateTime && b is DateTime) {
        return a.compareTo(b);
      }
    }

    // 3. Mixed-type comparison
    if (a is num && b is num) {
      return (a).compareTo(b);
    }

    if (a is BigInt && b is BigInt) {
      return a.compareTo(b);
    }

    if ((a is BigInt && b is num) || (a is num && b is BigInt)) {
      BigInt aBig = a is BigInt ? a : BigInt.from(a as num);
      BigInt bBig = b is BigInt ? b : BigInt.from(b as num);
      return aBig.compareTo(bBig);
    }

    // For other mixed types, or if one is a String, convert to string and compare
    return compareStrings(a.toString(), b.toString());
  }

  /// Compares two integers.
  static int compareInts(int a, int b) {
    return a.compareTo(b);
  }

  /// Compares two doubles.
  static int compareDoubles(double a, double b) {
    return a.compareTo(b);
  }

  /// Compares two strings that are base62-encoded shortcodes.
  ///
  /// In base62 encoding (or similar length-significant encodings),
  /// a longer string represents a larger value. When lengths are equal,
  /// a standard lexicographical string comparison is used. This is
  /// suitable for comparing time-based, Base62-encoded primary keys.
  static int compareShortCodes(String a, String b) {
    // First, compare by length. A longer shortcode is always greater.
    final lengthCompare = a.length.compareTo(b.length);
    if (lengthCompare != 0) {
      return lengthCompare;
    }
    // If lengths are equal, perform a standard string comparison.
    return a.compareTo(b);
  }

  /// Compares two strings with advanced logic.
  /// It handles numeric strings, shortcodes, and natural sorting.
  static int compareStrings(String a, String b) {
    if (a == b) return 0;

    // Normalize strings - remove extra quotes
    String aStr = _normalizeString(a);
    String bStr = _normalizeString(b);

    if (aStr == bStr) return 0;

    // Check if both are numeric strings (highest priority)
    if (isNumericString(aStr) && isNumericString(bStr)) {
      return compareNumericStrings(aStr, bStr);
    }

    // Check if both are shortcode format (second priority)
    if (isShortCodeFormat(aStr) && isShortCodeFormat(bStr)) {
      // 1. First compare length: in Base62 encoding, a longer code always represents a larger value
      return compareShortCodes(aStr, bStr);
    }

    // Natural sorting for strings with embedded numbers (third priority)
    final naturalResult = _compareStringsNaturally(aStr, bStr);
    if (naturalResult != 0) {
      return naturalResult;
    }

    // Default: standard string comparison
    return aStr.compareTo(bStr);
  }

  /// Natural sorting comparison of two strings (handle numbers in strings)
  static int _compareStringsNaturally(String a, String b) {
    // Check if digital-aware comparison is needed
    bool aHasDigit = RegExp(r'\d').hasMatch(a);
    bool bHasDigit = RegExp(r'\d').hasMatch(b);

    if (!aHasDigit || !bHasDigit) {
      return 0; // At least one string does not have a number, use standard comparison
    }

    // Split string into list of letter and number parts
    List<_StringPart> aParts = _splitStringIntoParts(a);
    List<_StringPart> bParts = _splitStringIntoParts(b);

    // Compare each part
    int minLength =
        aParts.length < bParts.length ? aParts.length : bParts.length;

    for (int i = 0; i < minLength; i++) {
      _StringPart aPart = aParts[i];
      _StringPart bPart = bParts[i];

      // If two parts are of the same type
      if (aPart.isNumeric == bPart.isNumeric) {
        if (aPart.isNumeric) {
          // If it is a numeric part, compare by value
          int aNum = int.tryParse(aPart.value) ?? 0;
          int bNum = int.tryParse(bPart.value) ?? 0;
          int result = aNum.compareTo(bNum);
          if (result != 0) return result;
        } else {
          // If it is a text part, compare by dictionary order
          int result = aPart.value.compareTo(bPart.value);
          if (result != 0) return result;
        }
      } else {
        // If the types are different, the numeric part is less than the text part
        return aPart.isNumeric ? -1 : 1;
      }
    }

    // If the previous parts are equal, the shorter string is smaller
    return aParts.length.compareTo(bParts.length);
  }

  /// Split string into letter and number parts
  static List<_StringPart> _splitStringIntoParts(String input) {
    List<_StringPart> parts = [];
    StringBuffer currentPart = StringBuffer();
    bool isNumeric = false;
    bool hasStarted = false;

    for (int i = 0; i < input.length; i++) {
      String char = input[i];
      bool charIsDigit = RegExp(r'\d').hasMatch(char);

      if (!hasStarted) {
        // The first character
        currentPart.write(char);
        isNumeric = charIsDigit;
        hasStarted = true;
      } else if (charIsDigit == isNumeric) {
        // The same type, continue adding to the current part
        currentPart.write(char);
      } else {
        // The type changed, save the current part and start a new part
        parts.add(_StringPart(currentPart.toString(), isNumeric));
        currentPart = StringBuffer(char);
        isNumeric = charIsDigit;
      }
    }

    // Add the last part
    if (currentPart.isNotEmpty) {
      parts.add(_StringPart(currentPart.toString(), isNumeric));
    }

    return parts;
  }

  /// Checks if a string represents a numeric value.
  static bool isNumericString(String value) {
    if (value.isEmpty) return false;

    // Try to parse as BigInt or double
    try {
      // Check if it starts with a number (could have non-digit characters later)
      if (!RegExp(r'^\d').hasMatch(value)) {
        return false;
      }

      // Try parsing as BigInt first
      if (RegExp(r'^\d+$').hasMatch(value)) {
        return true; // Valid integer
      }

      // Try parsing as double
      double.parse(value);
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Checks if a string is in shortcode format (base62 encoding).
  static bool isShortCodeFormat(String value) {
    // Shortcodes typically contain only alphanumeric characters
    // This is a simple check that can be refined based on specific requirements
    return RegExp(r'^[a-zA-Z0-9]+$').hasMatch(value) &&
        !isNumericString(value); // Not a pure numeric string
  }

  /// Compares two numeric strings.
  static int compareNumericStrings(String a, String b) {
    // Determine if we are comparing integers or floating-point numbers
    final bool isAInt = RegExp(r'^\d+$').hasMatch(a);
    final bool isBInt = RegExp(r'^\d+$').hasMatch(b);

    try {
      // If both appear to be integers, use BigInt for a precise comparison.
      if (isAInt && isBInt) {
        return compareBigIntStrings(a, b);
      }

      // If one or both might be a double, compare them as doubles.
      // This correctly handles comparisons between integers and doubles as well.
      final aDouble = double.parse(a);
      final bDouble = double.parse(b);
      return aDouble.compareTo(bDouble);
    } catch (_) {
      // Fall back to string comparison if any parsing fails
      return a.compareTo(b);
    }
  }

  /// Compares two strings that are known to represent large integers (BigInt).
  ///
  /// This provides a direct and efficient way to compare string-encoded BigInts,
  /// which is ideal for `timestampBased` and `datePrefixed` primary keys.
  /// It attempts to parse both strings as BigInt for a numerical comparison.
  /// If parsing fails for either string, it falls back to a standard
  /// lexicographical comparison as a safeguard.
  static int compareBigIntStrings(String a, String b) {
    final aBig = tryParseBigInt(a);
    final bBig = tryParseBigInt(b);

    if (aBig != null && bBig != null) {
      return aBig.compareTo(bBig);
    }

    // Fallback for safety, handles cases where strings are not valid BigInts.
    return a.compareTo(b);
  }

  /// Safely tries to parse a string as BigInt.
  static BigInt? tryParseBigInt(String value) {
    try {
      return BigInt.parse(value);
    } catch (_) {
      return null;
    }
  }

  /// Sorts a list of maps based on specified sort fields.
  ///
  /// @param list The list of maps to sort
  /// @param sortFields A list of fields to sort by
  /// @param sortDirections A list of sort directions (true for ascending, false for descending)
  /// @returns The sorted list
  static List<Map<String, dynamic>> sortMapList(List<Map<String, dynamic>> list,
      List<String> sortFields, List<bool> sortDirections) {
    if (sortFields.isEmpty || list.length <= 1) {
      return list;
    }

    list.sort((a, b) {
      for (int i = 0; i < sortFields.length; i++) {
        final field = sortFields[i];
        final isAscending =
            i < sortDirections.length ? sortDirections[i] : true;

        final valueA = a[field];
        final valueB = b[field];

        final comparison = compare(valueA, valueB);

        if (comparison != 0) {
          return isAscending ? comparison : -comparison;
        }
      }
      return 0; // All fields are equal
    });

    return list;
  }

  /// Returns the maximum of two values using the compare method.
  static dynamic max(dynamic a, dynamic b) {
    return compare(a, b) >= 0 ? a : b;
  }

  /// Returns the minimum of two values using the compare method.
  static dynamic min(dynamic a, dynamic b) {
    return compare(a, b) <= 0 ? a : b;
  }

  /// Checks if a value matches a pattern using SQL LIKE syntax.
  /// Supports % as wildcard for multiple characters and _ for single character.
  static bool matchesPattern(dynamic value, String pattern) {
    if (value == null) return false;

    String valueStr = value.toString();

    // Convert SQL LIKE pattern to regex
    String regex = pattern
        .replaceAll(r'\', r'\\') // Escape existing backslashes
        .replaceAll(r'.', r'\.') // Escape dots
        .replaceAll(r'$', r'\$') // Escape dollar signs
        .replaceAll(r'^', r'\^') // Escape carets
        .replaceAll(r'(', r'\(') // Escape opening parentheses
        .replaceAll(r')', r'\)') // Escape closing parentheses
        .replaceAll(r'[', r'\[') // Escape opening square brackets
        .replaceAll(r']', r'\]') // Escape closing square brackets
        .replaceAll(r'*', r'\*') // Escape asterisks
        .replaceAll(r'+', r'\+') // Escape plus signs
        .replaceAll(r'?', r'\?') // Escape question marks
        .replaceAll(r'{', r'\{') // Escape opening curly braces
        .replaceAll(r'}', r'\}') // Escape closing curly braces
        .replaceAll(r'|', r'\|') // Escape pipes
        .replaceAll(r'%', r'.*') // % means any number of characters
        .replaceAll(r'_', r'.'); // _ means exactly one character

    // Ensure the pattern matches the entire string
    regex = r'^' + regex + r'$';

    return RegExp(regex, caseSensitive: false).hasMatch(valueStr);
  }

  /// Sort a list, supporting ascending and descending order
  static void sortList<T>(List<T> list, {bool descending = false}) {
    list.sort((a, b) {
      final result = compare(a, b);
      return descending ? -result : result;
    });
  }

  /// Check if a value is within a range
  static bool isInRange(dynamic value, dynamic start, dynamic end,
      {bool includeStart = true, bool includeEnd = true}) {
    if (value == null) return false;

    final compareWithStart = start != null ? compare(value, start) : 1;
    final compareWithEnd = end != null ? compare(value, end) : -1;

    final startOk = start == null ||
        (includeStart ? compareWithStart >= 0 : compareWithStart > 0);
    final endOk =
        end == null || (includeEnd ? compareWithEnd <= 0 : compareWithEnd < 0);

    return startOk && endOk;
  }

  /// Normalize the string - remove the extra quotes
  static String _normalizeString(String value) {
    String result = value;

    // Remove the quotes at the beginning and end of the string
    if ((result.startsWith('"') && result.endsWith('"')) ||
        (result.startsWith("'") && result.endsWith("'"))) {
      result = result.substring(1, result.length - 1);
    }

    // Handle the case of escaped quotes: \"value\"
    if (result.startsWith('\\"') && result.endsWith('\\"')) {
      result = result.substring(2, result.length - 2);
    }

    return result;
  }

  /// Returns a specialized, high-performance comparator for a given data type.
  ///
  /// This avoids repeated type checking during bulk operations like sorting or searching.
  static ComparatorFunction getFieldComparator(DataType? type) {
    switch (type) {
      case DataType.integer:
        return (a, b) => (a as int).compareTo(b as int);
      case DataType.bigInt:
        return (a, b) => (a as BigInt).compareTo(b as BigInt);
      case DataType.double:
        return (a, b) => (a as double).compareTo(b as double);
      case DataType.text:
        return (a, b) => compareStrings(a as String, b as String);
      case DataType.boolean:
        return (a, b) {
          // Explicitly compare bools to avoid casting errors if data is stored as 0/1
          final bool aBool = a is bool ? a : (a == 1);
          final bool bBool = b is bool ? b : (b == 1);
          return aBool == bBool ? 0 : (aBool ? 1 : -1);
        };
      case DataType.datetime:
        return (a, b) => (a as DateTime).compareTo(b as DateTime);
      case DataType.blob:
        // For blobs, fall back to a generic comparison as direct comparison is not meaningful
        return compare;
      case DataType.array:
        // For array type, compare as strings for now
        return (a, b) => compare(a.toString(), b.toString());
      case DataType.vector:
        // For vector data, use generic comparison
        return compare;
      default:
        // If type is not specified or for any future types, 
        // use the general-purpose but slower comparison method.
        return compare;
    }
  }

  /// Returns a specialized, high-performance comparator for a given primary key type.
  /// This is more efficient than the generic `getComparator` because it leverages
  /// the known format of primary keys (e.g., numeric strings, shortcodes).
  static ComparatorFunction getPrimaryKeyComparator(PrimaryKeyType pkType) {
    switch (pkType) {
      case PrimaryKeyType.sequential:
      case PrimaryKeyType.timestampBased:
      case PrimaryKeyType.datePrefixed:
        // These are numeric strings, best compared as BigInts for accuracy.
        return (a, b) => compareBigIntStrings(a.toString(), b.toString());
      case PrimaryKeyType.shortCode:
        // These are base62-like strings where length is the primary sort key.
        return (a, b) => compareShortCodes(a.toString(), b.toString());
      case PrimaryKeyType.none:
      default:
        // User-defined string primary keys. Use the full natural sort comparison
        // as we don't know the format. It's the safest and most flexible.
        return (a, b) => compareStrings(a.toString(), b.toString());
    }
  }
}

/// String part class, used for natural sorting
class _StringPart {
  final String value;
  final bool isNumeric;

  _StringPart(this.value, this.isNumeric);

  @override
  String toString() {
    return '$value (${isNumeric ? 'num' : 'text'})';
  }
}
