class ValueComparator {
  /// Compares two values of potentially different types.
  /// Returns:
  /// - Negative number if a < b
  /// - Zero if a == b
  /// - Positive number if a > b
  static int compare(dynamic a, dynamic b) {
    // Handle null cases
    if (a == null && b == null) return 0;
    if (a == null) return -1;
    if (b == null) return 1;

    // If both are numbers (int, double, num), compare them directly
    if (a is num && b is num) {
      return a.compareTo(b);
    }

    // If both are BigInt, compare them directly
    if (a is BigInt && b is BigInt) {
      return a.compareTo(b);
    }

    // If one is BigInt and one is num, convert both to BigInt
    if ((a is BigInt && b is num) || (a is num && b is BigInt)) {
      BigInt aBig = a is BigInt ? a : BigInt.from(a as num);
      BigInt bBig = b is BigInt ? b : BigInt.from(b as num);
      return aBig.compareTo(bBig);
    }

    // Convert to strings for string comparison
    String aStr = a.toString();
    String bStr = b.toString();

    // Check if both are numeric strings
    if (isNumericString(aStr) && isNumericString(bStr)) {
      return compareNumericStrings(aStr, bStr);
    }

    // Check if both are shortcode format
    if (isShortCodeFormat(aStr) && isShortCodeFormat(bStr)) {
      // 1. First compare length: in Base62 encoding, a longer code always represents a larger value
      if (aStr.length != bStr.length) {
        return aStr.length.compareTo(bStr.length);
      }

      // 2. When length is the same, directly use string comparison:
      // Because the dictionary order of the Base62 character set (0-9,A-Z,a-z) is consistent with the numerical order,
      // and the position weight is correct (the higher the position, the greater the weight), so for the same length encoding,
      // dictionary order comparison is 100% consistent with numerical size comparison.
      return aStr.compareTo(bStr);

      // Note: We removed the decode-then-compare logic because direct string comparison is 100% accurate and has better performance
      // Decode comparison for same-length Base62 encoding is about 20 times slower.
    }

    // For different types or non-numeric strings, compare as strings
    return aStr.compareTo(bStr);
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
    try {
      // If they're both integers, use BigInt for comparison
      if (RegExp(r'^\d+$').hasMatch(a) && RegExp(r'^\d+$').hasMatch(b)) {
        BigInt aBig = tryParseBigInt(a) ?? BigInt.zero;
        BigInt bBig = tryParseBigInt(b) ?? BigInt.zero;
        return aBig.compareTo(bBig);
      }

      // Otherwise use double (handles decimals)
      double aDouble = double.parse(a);
      double bDouble = double.parse(b);
      return aDouble.compareTo(bDouble);
    } catch (_) {
      // Fall back to string comparison if parsing fails
      return a.compareTo(b);
    }
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
  static bool matchesLikePattern(dynamic value, String pattern) {
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

    return RegExp(regex, caseSensitive: true).hasMatch(valueStr);
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

  /// Check if a string matches a pattern (for LIKE operator)
  static bool matchesPattern(String? value, String pattern) {
    if (value == null) return false;

    // Convert SQL LIKE pattern to regular expression
    final regex = pattern
        .replaceAll('%', '.*') // % matches zero or more characters
        .replaceAll('_', '.') // _ matches one character
        .replaceAll('\\', '\\\\'); // Escape backslashes

    return RegExp('^$regex\$', caseSensitive: false).hasMatch(value);
  }
}
