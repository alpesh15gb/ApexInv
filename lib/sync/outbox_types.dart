/// Shared enum-like constants for outbox operations. Kept in its own file so
/// `sync_transport.dart` and `sync_engine.dart` can both import it without a
/// cycle.
class SyncOpTypes {
  static const insert = 'insert';
  static const update = 'update';
  static const delete = 'delete';

  SyncOpTypes._();
}
