/// switch base path event
class BasePathChangedEvent {
  final String? oldBaseName;
  final String? newBaseName;

  BasePathChangedEvent(this.oldBaseName, this.newBaseName);
}
