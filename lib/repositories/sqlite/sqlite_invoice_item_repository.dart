import 'package:apexbooks/database/invoice_item_service.dart';
import 'package:apexbooks/models/invoice_item.dart';
import 'package:apexbooks/repositories/invoice_item_repository.dart';

class SqliteInvoiceItemRepository implements InvoiceItemRepository {
  @override
  Future<List<InvoiceItem>> getInvoiceItemsByInvoiceId(String invoiceId) {
    return InvoiceItemService.getInvoiceItemsByInvoiceId(invoiceId);
  }

  @override
  Future<void> insertInvoiceItems(String invId, InvoiceItem item) {
    return InvoiceItemService.insertInvoiceItems(invId, item);
  }

  @override
  Future<void> markProductSaved(String invoiceId, String productId) {
    return InvoiceItemService.markProductSaved(invoiceId, productId);
  }
}
