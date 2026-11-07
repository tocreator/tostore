# ToStore example

Interactive Flutter app for the `tostore` package. It exercises key-value storage, structured tables, queries, vector and text retrieval, backup and restore, and the built-in benchmark suite.

Copy-paste starters live next to the app:

- `lib/mobile_quickstart.dart` — mobile and desktop, schema passed to `ToStore.open`
- `lib/server_quickstart.dart` — long-running process, tables created after open

The package guide is the repository [README](../README.md). Benchmark tables and the machine they were measured on are in [doc/BENCHMARKS.md](../doc/BENCHMARKS.md).

## Run the app

```bash
cd example
flutter pub get
flutter run
```

Use a release build before judging speed. Debug mode is not representative.

```bash
flutter run --release
```

In the app, **Benchmark Test** runs the suite behind `doc/BENCHMARKS.md`. The dialog chooses scale and durability. Export or read the on-screen summary after the run finishes.

## Tests

From the repository root, the short smoke test opens an in-memory database, inserts a row, queries it, and round-trips one key. GitHub Actions runs this on every push and pull request:

```bash
dart test
```

The example app also contains a long functional suite and throughput benchmarks. They need Flutter and write database files under `example/`:

```bash
cd example
flutter test test/database_full_test.dart
```

`database_full_test.dart` takes several minutes. The `*_benchmark.dart` files are measurements, not pass/fail gates.
