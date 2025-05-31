/// switch space path event
class SpacePathChangedEvent {
  final String? oldSpaceName;
  final String? newSpaceName;

  SpacePathChangedEvent(this.oldSpaceName, this.newSpaceName);
}
