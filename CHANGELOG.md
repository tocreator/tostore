# Changelog

All notable changes to this project will be documented in this file.

## 1.8.7

### Breaking Changes
- Renamed `renameTo` to `renameTable`
- Changed field operation naming to be more consistent:
  - `dropField` -> `removeField`
  - `dropIndex` -> `removeIndex`

### Enhancements
- Improved schema migration logic
- Optimized file operations using FileManager

### Bug Fixes
- Fixed transaction handling in schema operations

## 1.8.6

* Update topics in pubspec.yaml
* Fix data type conversion in DataStoreImpl

## 1.8.5

### Added
- Added automatic schema upgrade support through `schemas` parameter
- Added chainable schema update operations for table structure modifications
- Added comprehensive example for schema upgrades and migrations

### Changed
- Improved table structure upgrade mechanism
- Enhanced documentation with schema upgrade examples
- Optimized constraint checking


## 1.8.4

### Added
  - Added `upsert()` for auto upsert data
  - Supports both where conditions and primary key matching
  - Chain-style API consistent with other operations
  - Added array data type for storing List values
  - Added array comparison and sorting support
  - Optimized array type validation


## 1.8.3

* Added multi-language documentation support (日本語, 한국어, Español, Português, Русский, Deutsch, Français, Italiano, Türkçe)
* Reorganized documentation structure under docs/translations directory

## 1.8.2

### Changed
- Optimized multi-space switching
- Refined documentation examples

## 1.8.1

### Added
- Performance optimization for file operations
- Enhanced backup efficiency
- Improved index performance
- Basic cache strategy improvements

### Changed
- Optimized query execution
- Enhanced memory usage
- Improved logging details
- Updated documentation

## 1.8.0

### Added
- Performance improvements for multi-space operations
- Enhanced query optimization
- Basic monitoring capabilities
- Extended documentation

### Changed
- Optimized storage engine performance
- Enhanced query execution
- Improved resource utilization

## 1.7.2

### Changed
- Enhanced query performance
- Optimized index usage
- Improved cache efficiency
- Better resource management

## 1.7.1

### Changed
- Optimized query execution
- Enhanced memory usage
- Improved space management
- Updated documentation

## 1.7.0

### Added
- Enhanced query optimization
- Improved backup functionality
- Basic monitoring support
- Extended documentation

### Changed
- Optimized resource usage
- Improved performance
- Enhanced documentation

## 1.6.1

### Changed
- Enhanced operation efficiency
- Optimized resource usage
- Improved documentation
- Better developer experience

## 1.6.0

### Added
- Basic backup and restore
- File-based security features
- Improved backup strategies
- Enhanced error handling

### Changed
- Enhanced query performance
- Improved space management
- Better error handling

## 1.5.0

### Added
- Basic indexing system
- Query result caching
- Basic monitoring

### Changed
- Improved query optimizer
- Enhanced backup system
- Better error reporting

## 1.4.0

### Added
- Basic transaction support
- concurrency control
- Enhanced error handling
- Basic migration support

### Changed
- Performance optimization
- Enhanced error handling
- Improved documentation

## 1.3.0

### Added
- Basic backup system
- Simple recovery tools
- Index improvements
- Query optimization

### Changed
- Better space management
- Improved error handling
- Enhanced documentation

## 1.2.0

### Added
- Basic query builder
- Enhanced type handling
- Simple validation
- Basic logging

### Changed
- Improved performance
- Basic security
- Enhanced documentation

## 1.1.0

### Added
- Enhanced query capabilities
- Basic transaction support
- Error handling
- Simple caching

### Changed
- Performance optimization
- Type safety improvements
- Documentation updates

## 1.0.0

### Added
- First stable release
- Basic CRUD operations
- Simple query system
- File-based storage
- Documentation

## 0.5.0

### Added
- Beta release
- Basic storage engine
- Multi-space optimization
- Global tables support
- Simple indexing
- Query improvements

### Changed
- Enhanced space switching
- Improved isolation
- Better data handling

## 0.4.0

### Added
- Enhanced multi-space features
- Global data sharing
- Space switching
- Basic type support
- Documentation

### Changed
- Space isolation
- Data sharing mechanism
- Space management

## 0.3.0

### Added
- Multi-space architecture foundation
- Global tables initial support
- Space switching mechanism
- Core functionality
- Basic CRUD operations
- Simple queries

### Changed
- Storage structure for multi-space
- Data isolation mechanism
- Space management

## 0.2.0

### Added
- Core system implementation
- File handling
- Error handling
- Type support

## 0.1.0

### Added
- Initial development release
- Basic file structure
- Core interfaces
- Simple storage implementation

## 0.0.1

### Added
- Project initialization
- Basic project structure
- Development environment setup