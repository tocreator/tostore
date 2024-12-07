/// 基础空间变更事件
class BasePathChangedEvent {
  final String? oldBaseName;
  final String? newBaseName;

  BasePathChangedEvent(this.oldBaseName, this.newBaseName);
}
